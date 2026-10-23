#if os(macOS)
import AppKit
typealias PlatformHighlightColor = NSColor
#else
import UIKit
typealias PlatformHighlightColor = UIColor
#endif
import Foundation
import PDFKit

typealias EditorialPalette = ReaderTheme

extension NativeMarkdownRenderer {
    static let sourceUTF16Attribute = NSAttributedString.Key.oneReaderSourceUTF16Start
    static let sourceUTF16EndAttribute = NSAttributedString.Key.oneReaderSourceUTF16End
}

struct WebHighlightDescriptor: Codable, Equatable, Sendable {
    let id: String
    let quote: String
    let domPath: String?
}

enum InlineHighlightSupport {
    static let pdfAnnotationUserName = "OneReaderInlineHighlight"

    static var nativeHighlightColor: PlatformHighlightColor {
        PlatformHighlightColor.systemYellow.withAlphaComponent(0.28)
    }

    static var pdfHighlightColor: PlatformHighlightColor {
        PlatformHighlightColor.systemYellow.withAlphaComponent(0.35)
    }

    static func highlightsSignature(
        for annotations: [Annotation],
        documentLocator: Locator
    ) -> String {
        let filtered = eligibleAnnotations(from: annotations, documentLocator: documentLocator)
        guard !filtered.isEmpty else { return "empty" }
        return filtered.map { annotation in
            [
                annotation.id,
                annotation.anchorState.rawValue,
                annotation.locator.stableID,
                annotation.locator.textQuote?.exact ?? "",
                annotation.selectedText ?? "",
                annotation.color ?? "",
            ].joined(separator: "|")
        }.joined(separator: ";")
    }

    // MARK: - Native Text / Markdown / Code UTF-16 Range Resolution

    static func resolvedUTF16Ranges(
        for annotations: [Annotation],
        documentLocator: Locator,
        renderedString: NSAttributedString,
        isMarkdown: Bool
    ) -> [NSRange] {
        let maxLength = renderedString.length
        guard maxLength > 0 else { return [] }
        let renderedNSString = renderedString.string as NSString
        let eligible = eligibleAnnotations(from: annotations, documentLocator: documentLocator)

        var resolved: [NSRange] = []
        resolved.reserveCapacity(eligible.count)

        for annotation in eligible {
            guard let candidate = resolveSingleRange(
                for: annotation,
                documentLocator: documentLocator,
                renderedString: renderedString,
                renderedNSString: renderedNSString,
                isMarkdown: isMarkdown
            ),
            let clamped = clampRange(candidate, maxLength: maxLength) else {
                continue
            }
            resolved.append(clamped)
        }
        return resolved
    }

    @discardableResult
    static func applyNativeHighlights(
        for annotations: [Annotation],
        documentLocator: Locator,
        isMarkdown: Bool,
        baseAttributedString: NSAttributedString,
        to storage: NSMutableAttributedString,
        previousRanges: [NSRange] = []
    ) -> [NSRange] {
        let safeMaxLength = min(storage.length, baseAttributedString.length)
        let validPrevious = previousRanges.compactMap { clampRange($0, maxLength: safeMaxLength) }
        let resolvedRanges = resolvedUTF16Ranges(
            for: annotations,
            documentLocator: documentLocator,
            renderedString: baseAttributedString,
            isMarkdown: isMarkdown
        ).compactMap { clampRange($0, maxLength: storage.length) }

        guard !validPrevious.isEmpty || !resolvedRanges.isEmpty else {
            return []
        }

        storage.beginEditing()
        for oldRange in validPrevious {
            baseAttributedString.enumerateAttribute(
                .backgroundColor,
                in: oldRange,
                options: []
            ) { value, subrange, _ in
                if let value {
                    storage.addAttribute(.backgroundColor, value: value, range: subrange)
                } else {
                    storage.removeAttribute(.backgroundColor, range: subrange)
                }
            }
        }
        let color = nativeHighlightColor
        for range in resolvedRanges {
            storage.addAttribute(.backgroundColor, value: color, range: range)
        }
        storage.endEditing()
        return resolvedRanges
    }

    // MARK: - PDF Highlight Resolution

    static func resolvedPDFSelections(
        for annotations: [Annotation],
        in document: PDFDocument,
        documentLocator: Locator
    ) -> [PDFSelection] {
        guard document.pageCount > 0 else { return [] }
        let eligible = eligibleAnnotations(from: annotations, documentLocator: documentLocator)

        var selections: [PDFSelection] = []
        for annotation in eligible {
            let allowPositional = canUsePositionalAnchors(
                for: annotation,
                documentLocator: documentLocator
            )
            if let selection = resolveSinglePDFSelection(
                for: annotation,
                in: document,
                allowRectFallback: allowPositional
            ) {
                selections.append(selection)
            }
        }
        return selections
    }

    static func resolvedPDFSelections(
        for annotations: [Annotation],
        in document: PDFDocument,
        sourceID: String,
        snapshotID: String? = nil
    ) -> [PDFSelection] {
        let inferredSnapshotID = snapshotID
            ?? annotations.first(where: { $0.sourceID == sourceID })?.locator.snapshotID
            ?? ""
        let locator = Locator(
            sourceID: sourceID,
            snapshotID: inferredSnapshotID,
            adapterID: PDFAdapter.id
        )
        return resolvedPDFSelections(
            for: annotations,
            in: document,
            documentLocator: locator
        )
    }

    static func applyPDFHighlights(
        _ annotations: [Annotation],
        to document: PDFDocument,
        documentLocator: Locator
    ) {
        removeInlinePDFHighlights(from: document)
        guard document.pageCount > 0 else { return }

        let eligible = eligibleAnnotations(from: annotations, documentLocator: documentLocator)

        for annotation in eligible {
            let allowPositional = canUsePositionalAnchors(
                for: annotation,
                documentLocator: documentLocator
            )
            if let selection = resolveSinglePDFSelection(
                for: annotation,
                in: document,
                allowRectFallback: allowPositional
            ) {
                let lineSelections = selection.selectionsByLine()
                let effectiveSelections = lineSelections.isEmpty ? [selection] : lineSelections
                for lineSelection in effectiveSelections {
                    for page in lineSelection.pages {
                        let bounds = lineSelection.bounds(for: page)
                        addInlinePDFHighlight(bounds: bounds, on: page)
                    }
                }
            } else if allowPositional,
                      !hasQuoteText(annotation),
                      let pageIndex = annotation.locator.payload["pageIndex"].flatMap(Int.init),
                      pageIndex >= 0,
                      pageIndex < document.pageCount,
                      let page = document.page(at: pageIndex),
                      let rectAnchor = PDFPageRectAnchor.parse(annotation.locator.payload["rect"]),
                      let clipped = rectAnchor.clipped(to: page.bounds(for: .mediaBox)) {
                addInlinePDFHighlight(bounds: clipped, on: page)
            }
        }
    }

    static func applyPDFHighlights(
        _ annotations: [Annotation],
        to document: PDFDocument,
        sourceID: String,
        snapshotID: String? = nil
    ) {
        let inferredSnapshotID = snapshotID
            ?? annotations.first(where: { $0.sourceID == sourceID })?.locator.snapshotID
            ?? ""
        let locator = Locator(
            sourceID: sourceID,
            snapshotID: inferredSnapshotID,
            adapterID: PDFAdapter.id
        )
        applyPDFHighlights(
            annotations,
            to: document,
            documentLocator: locator
        )
    }

    static func removeInlinePDFHighlights(from document: PDFDocument) {
        guard document.pageCount > 0 else { return }
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let inlineAnnotations = page.annotations.filter {
                $0.userName == pdfAnnotationUserName
            }
            for annotation in inlineAnnotations {
                page.removeAnnotation(annotation)
            }
        }
    }

    // MARK: - Controlled WebKit Highlight Script

    static func webHighlightDescriptors(
        for annotations: [Annotation],
        documentLocator: Locator
    ) -> [WebHighlightDescriptor] {
        let eligible = eligibleAnnotations(from: annotations, documentLocator: documentLocator)
        return eligible.compactMap { annotation in
            let rawQuote = annotation.locator.textQuote?.exact ?? annotation.selectedText
            guard let quote = rawQuote?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !quote.isEmpty else {
                return nil
            }
            let allowPositional = canUsePositionalAnchors(
                for: annotation,
                documentLocator: documentLocator
            )
            let domPath = allowPositional
                ? (annotation.locator.payload["domPath"].flatMap { $0.isEmpty ? nil : $0 }
                    ?? annotation.locator.structuralPath.flatMap { $0.hasPrefix("body") ? $0 : nil })
                : nil
            return WebHighlightDescriptor(
                id: annotation.id,
                quote: quote,
                domPath: domPath
            )
        }
    }

    static func webHighlightJavaScript(
        for annotations: [Annotation],
        documentLocator: Locator
    ) -> String {
        let descriptors = webHighlightDescriptors(
            for: annotations,
            documentLocator: documentLocator
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rawJSON = (try? encoder.encode(descriptors))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let safeJSON = rawJSON
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")

        return """
            (() => {
              const highlights = \(safeJSON);
              const previousApplying = Boolean(window.__oneReaderApplyingAnchor);
              window.__oneReaderApplyingAnchor = true;
              try {
                const existing = document.querySelectorAll('mark[data-onereader-highlight]');
                for (const mark of existing) {
                  const parent = mark.parentNode;
                  if (!parent) continue;
                  while (mark.firstChild) {
                    parent.insertBefore(mark.firstChild, mark);
                  }
                  parent.removeChild(mark);
                  parent.normalize();
                }
                if (!Array.isArray(highlights) || !highlights.length || !document.body) {
                  return 0;
                }
                const rangesByNode = new Map();
                function normalizeText(value) {
                  let text = '';
                  const offsets = [];
                  for (let i = 0; i < value.length; i++) {
                    const ch = /\\s/.test(value[i]) ? ' ' : value[i];
                    if (ch === ' ' && (!text.length || text.endsWith(' '))) continue;
                    text += ch;
                    offsets.push(i);
                  }
                  if (text.endsWith(' ')) { text = text.slice(0, -1); offsets.pop(); }
                  return { text, offsets };
                }
                function queueQuoteInRoot(root, item) {
                  if (!root || !item || !item.quote) return false;
                  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                  const spans = [];
                  let text = '';
                  let lastBlock = null;
                  let node;
                  while ((node = walker.nextNode())) {
                    const parent = node.parentElement;
                    if (parent && parent.closest('script, style, noscript, textarea, [hidden]')) {
                      text += '\\u0000';
                      continue;
                    }
                    const block = parent && parent.closest('p, div, li, h1, h2, h3, h4, h5, h6, blockquote, pre, td, th');
                    if (lastBlock && block !== lastBlock) text += '\\n';
                    lastBlock = block;
                    const value = node.nodeValue || '';
                    spans.push({ node, start: text.length, end: text.length + value.length });
                    text += value;
                  }
                  const normalized = normalizeText(text);
                  const quote = normalizeText(item.quote).text;
                  if (!quote.length) return false;
                  const start = normalized.text.indexOf(quote);
                  if (start < 0 || normalized.text.indexOf(quote, start + 1) >= 0) return false;
                  const from = normalized.offsets[start];
                  const to = normalized.offsets[start + quote.length - 1] + 1;
                  let found = false;
                  for (const span of spans) {
                    const localStart = Math.max(from, span.start) - span.start;
                    const localEnd = Math.min(to, span.end) - span.start;
                    if (localEnd <= localStart) continue;
                    const ranges = rangesByNode.get(span.node) || [];
                    ranges.push({ start: localStart, end: localEnd, ids: [String(item.id || '')] });
                    rangesByNode.set(span.node, ranges);
                    found = true;
                  }
                  return found;
                }
                let appliedCount = 0;
                for (const item of highlights) {
                  if (!item || typeof item.quote !== 'string' || !item.quote.length) continue;
                  let targetRoot = null;
                  if (typeof item.domPath === 'string' && item.domPath.length) {
                    try { targetRoot = document.querySelector(item.domPath); } catch (_) {}
                  }
                  if ((targetRoot && queueQuoteInRoot(targetRoot, item)) || queueQuoteInRoot(document.body, item)) {
                    appliedCount++;
                  }
                }
                // Compute all ranges before touching the DOM. Merge overlaps,
                // then split each original text node from the end so its UTF-16
                // offsets remain valid and inline elements retain their markup.
                for (const [node, ranges] of rangesByNode) {
                  ranges.sort((a, b) => a.start - b.start);
                  const merged = [];
                  for (const range of ranges) {
                    const last = merged[merged.length - 1];
                    if (last && range.start <= last.end) {
                      last.end = Math.max(last.end, range.end);
                      last.ids.push(...range.ids);
                    } else {
                      merged.push(range);
                    }
                  }
                  for (const range of merged.reverse()) {
                    const matchedNode = range.start > 0 ? node.splitText(range.start) : node;
                    const length = range.end - range.start;
                    if (matchedNode.length > length) matchedNode.splitText(length);
                    const mark = document.createElement('mark');
                    mark.setAttribute('data-onereader-highlight', 'true');
                    mark.setAttribute('data-onereader-highlight-id', Array.from(new Set(range.ids)).join(' '));
                    mark.style.cssText = 'background-color: rgba(245, 196, 66, 0.36); color: inherit; border-radius: 2px; padding: 0 1px;';
                    if (matchedNode.parentNode) {
                      matchedNode.parentNode.replaceChild(mark, matchedNode);
                      mark.appendChild(matchedNode);
                    }
                  }
                }
                return appliedCount;
              } finally {
                requestAnimationFrame(() => {
                  window.__oneReaderApplyingAnchor = previousApplying;
                });
              }
            })();
            """
    }

    // MARK: - Private Resolution Helpers

    private static func eligibleAnnotations(
        from annotations: [Annotation],
        documentLocator: Locator
    ) -> [Annotation] {
        let documentRelativePath = normalizedRelativePath(documentLocator.relativePath)
        return annotations.filter { annotation in
            guard annotation.sourceID == documentLocator.sourceID,
                  annotation.locator.sourceID == documentLocator.sourceID,
                  annotation.anchorState != .orphaned else {
                return false
            }
            let matchesSnapshot = matchesDocumentSnapshot(
                annotation,
                documentLocator: documentLocator
            )
            let hasQuote = hasQuoteText(annotation)
            guard matchesSnapshot || (annotation.anchorState == .relocated && hasQuote) else {
                return false
            }
            let annotationRelativePath = normalizedRelativePath(annotation.locator.relativePath)
            guard annotationRelativePath == nil
                || documentRelativePath == nil
                || annotationRelativePath == documentRelativePath else {
                return false
            }
            return annotation.kind == .highlight || hasQuote
        }
    }

    private static func matchesDocumentSnapshot(
        _ annotation: Annotation,
        documentLocator: Locator
    ) -> Bool {
        guard !documentLocator.snapshotID.isEmpty else { return false }
        return annotation.snapshotID == documentLocator.snapshotID
            && annotation.locator.snapshotID == documentLocator.snapshotID
    }

    private static func canUsePositionalAnchors(
        for annotation: Annotation,
        documentLocator: Locator
    ) -> Bool {
        matchesDocumentSnapshot(annotation, documentLocator: documentLocator)
            && annotation.anchorState == .current
    }

    private static func hasQuoteText(_ annotation: Annotation) -> Bool {
        annotation.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || annotation.locator.textQuote?.exact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func normalizedRelativePath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "." else {
            return nil
        }
        return trimmed
    }

    private static func resolveSingleRange(
        for annotation: Annotation,
        documentLocator: Locator,
        renderedString: NSAttributedString,
        renderedNSString: NSString,
        isMarkdown: Bool
    ) -> NSRange? {
        let payload = annotation.locator.payload
        let startUTF16 = payload["startUTF16"].flatMap(Int.init)
        let endUTF16 = payload["endUTF16"].flatMap(Int.init)
        let allowPositional = canUsePositionalAnchors(
            for: annotation,
            documentLocator: documentLocator
        )

        if isMarkdown {
            if allowPositional, let start = startUTF16, let end = endUTF16, end > start {
                let sourceRange = NSRange(location: start, length: end - start)
                if let mapped = MarkdownSourceMap.renderedRange(
                    forSourceRange: sourceRange,
                    in: renderedString
                ), let clamped = clampRange(mapped, maxLength: renderedNSString.length),
                   let verified = verifyOrRefineRenderedMarkdownRange(
                       clamped,
                       for: annotation,
                       in: renderedNSString
                   ) {
                    return verified
                }
            }
            let preferredOffset = allowPositional
                ? (payload["renderedStartUTF16"].flatMap(Int.init)
                    ?? startUTF16.flatMap {
                        approximateRenderedOffset(forSourceOffset: $0, in: renderedString)
                    })
                : nil
            return matchQuoteOrSelectedText(
                for: annotation,
                in: renderedNSString,
                preferredLocation: preferredOffset
            )
        } else {
            if allowPositional, let start = startUTF16, let end = endUTF16, end > start {
                if let clamped = clampRange(
                    NSRange(location: start, length: end - start),
                    maxLength: renderedNSString.length
                ) {
                    let candidates = quoteTextCandidates(for: annotation)
                    if !candidates.isEmpty {
                        let actual = renderedNSString.substring(with: clamped)
                        if candidates.contains(actual) {
                            return clamped
                        }
                        return matchQuoteOrSelectedText(
                            for: annotation,
                            in: renderedNSString,
                            preferredLocation: clamped.location
                        )
                    }
                    return clamped
                }
            }
            let preferredOffset = allowPositional
                ? (startUTF16
                    ?? lineRangeInUTF16(for: annotation.locator, in: renderedNSString)?.location)
                : nil
            if let matched = matchQuoteOrSelectedText(
                for: annotation,
                in: renderedNSString,
                preferredLocation: preferredOffset
            ) {
                return matched
            }
            if allowPositional,
               quoteTextCandidates(for: annotation).isEmpty,
               let lineRange = lineRangeInUTF16(for: annotation.locator, in: renderedNSString) {
                return lineRange
            }
            return nil
        }
    }

    private static func verifyOrRefineRenderedMarkdownRange(
        _ mappedRange: NSRange,
        for annotation: Annotation,
        in renderedNSString: NSString
    ) -> NSRange? {
        let candidates = quoteTextCandidates(for: annotation)
        guard !candidates.isEmpty else {
            return mappedRange
        }
        let mappedSubstring = renderedNSString.substring(with: mappedRange)
        for candidate in candidates {
            if mappedSubstring == candidate {
                return mappedRange
            }
            if (candidate as NSString).length <= mappedRange.length {
                let subrange = renderedNSString.range(of: candidate, options: [], range: mappedRange)
                if subrange.location != NSNotFound {
                    return subrange
                }
            }
        }
        return nil
    }

    private static func approximateRenderedOffset(
        forSourceOffset sourceOffset: Int,
        in renderedString: NSAttributedString
    ) -> Int? {
        guard renderedString.length > 0 else { return nil }
        var bestDistance = Int.max
        var bestRenderedOffset: Int?

        renderedString.enumerateAttribute(
            NativeMarkdownRenderer.sourceUTF16Attribute,
            in: NSRange(location: 0, length: renderedString.length),
            options: []
        ) { value, range, stop in
            guard let sourceStart = value as? Int,
                  let sourceEnd = renderedString.attribute(
                      NativeMarkdownRenderer.sourceUTF16EndAttribute,
                      at: range.location,
                      effectiveRange: nil
                  ) as? Int,
                  sourceEnd > sourceStart else {
                return
            }
            if sourceOffset >= sourceStart && sourceOffset <= sourceEnd {
                if sourceEnd - sourceStart == range.length {
                    bestRenderedOffset = range.location + (sourceOffset - sourceStart)
                } else {
                    bestRenderedOffset = range.location
                }
                bestDistance = 0
                stop.pointee = true
                return
            }
            let distance = sourceOffset < sourceStart
                ? (sourceStart - sourceOffset)
                : (sourceOffset - sourceEnd)
            if distance < bestDistance {
                bestDistance = distance
                bestRenderedOffset = sourceOffset < sourceStart
                    ? range.location
                    : NSMaxRange(range)
            }
        }
        return bestRenderedOffset
    }

    private static func quoteTextCandidates(for annotation: Annotation) -> [String] {
        var candidates: [String] = []
        if let selected = annotation.selectedText, !selected.isEmpty {
            candidates.append(selected)
        }
        if let exact = annotation.locator.textQuote?.exact,
           !exact.isEmpty,
           !candidates.contains(exact) {
            candidates.append(exact)
        }
        return candidates
    }

    private static func matchQuoteOrSelectedText(
        for annotation: Annotation,
        in renderedNSString: NSString,
        preferredLocation: Int?
    ) -> NSRange? {
        guard renderedNSString.length > 0 else { return nil }

        if let quote = annotation.locator.textQuote,
           !quote.exact.isEmpty,
           let matched = matchTextQuote(
               quote,
               in: renderedNSString,
               preferredLocation: preferredLocation
           ) {
            return matched
        }

        if let selected = annotation.selectedText,
           !selected.isEmpty,
           let quote = annotation.locator.textQuote,
           quote.exact != selected,
           let matched = matchTextQuote(
               TextQuote(prefix: quote.prefix, exact: selected, suffix: quote.suffix),
               in: renderedNSString,
               preferredLocation: preferredLocation
           ) {
            return matched
        }

        for candidate in quoteTextCandidates(for: annotation) {
            if let matched = bestSubstringMatch(
                of: candidate,
                in: renderedNSString,
                preferredLocation: preferredLocation
            ) {
                return matched
            }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               trimmed != candidate,
               let matched = bestSubstringMatch(
                   of: trimmed,
                   in: renderedNSString,
                   preferredLocation: preferredLocation
               ) {
                return matched
            }
        }
        return nil
    }

    private static func matchTextQuote(
        _ quote: TextQuote,
        in value: NSString,
        preferredLocation: Int?
    ) -> NSRange? {
        guard !quote.exact.isEmpty, value.length > 0 else { return nil }
        var contextMatches: [NSRange] = []
        var exactMatches: [NSRange] = []

        var searchRange = NSRange(location: 0, length: value.length)
        while searchRange.length > 0 {
            let match = value.range(of: quote.exact, options: [], range: searchRange)
            guard match.location != NSNotFound else { break }
            exactMatches.append(match)

            let prefixMatches = quote.prefix.map { prefix in
                let length = min((prefix as NSString).length, match.location)
                let candidate = value.substring(
                    with: NSRange(location: match.location - length, length: length)
                )
                return candidate.hasSuffix(prefix)
            } ?? true

            let suffixMatches = quote.suffix.map { suffix in
                let suffixStart = NSMaxRange(match)
                let length = min((suffix as NSString).length, value.length - suffixStart)
                let candidate = value.substring(
                    with: NSRange(location: suffixStart, length: length)
                )
                return candidate.hasPrefix(suffix)
            } ?? true

            if prefixMatches && suffixMatches {
                contextMatches.append(match)
            }

            let next = match.location + 1
            guard next < value.length else { break }
            searchRange = NSRange(location: next, length: value.length - next)
        }

        let pool = contextMatches.isEmpty ? exactMatches : contextMatches
        guard !pool.isEmpty else { return nil }
        if let preferredLocation {
            return pool.min {
                abs($0.location - preferredLocation) < abs($1.location - preferredLocation)
            }
        }
        return pool.first
    }

    private static func bestSubstringMatch(
        of needle: String,
        in value: NSString,
        preferredLocation: Int?
    ) -> NSRange? {
        guard !needle.isEmpty, value.length > 0 else { return nil }
        var matches: [NSRange] = []
        var searchRange = NSRange(location: 0, length: value.length)
        while searchRange.length > 0 {
            let match = value.range(of: needle, options: [], range: searchRange)
            guard match.location != NSNotFound else { break }
            matches.append(match)
            let next = match.location + 1
            guard next < value.length else { break }
            searchRange = NSRange(location: next, length: value.length - next)
        }
        guard !matches.isEmpty else { return nil }
        if let preferredLocation {
            return matches.min {
                abs($0.location - preferredLocation) < abs($1.location - preferredLocation)
            }
        }
        return matches.first
    }

    private static func lineRangeInUTF16(
        for locator: Locator,
        in value: NSString
    ) -> NSRange? {
        guard value.length > 0,
              let startLine = locator.payload["startLine"].flatMap(Int.init),
              startLine >= 1 else {
            return nil
        }
        let endLine = max(startLine, locator.payload["endLine"].flatMap(Int.init) ?? startLine)
        var currentLine = 1
        var cursor = 0
        var rangeStart: Int?
        var rangeEnd: Int?

        while cursor < value.length {
            let lineRange = value.lineRange(for: NSRange(location: cursor, length: 0))
            if currentLine == startLine {
                rangeStart = lineRange.location
            }
            if currentLine == endLine {
                var contentEnd = NSMaxRange(lineRange)
                while contentEnd > lineRange.location {
                    let ch = value.character(at: contentEnd - 1)
                    if ch == 0x0A || ch == 0x0D {
                        contentEnd -= 1
                    } else {
                        break
                    }
                }
                rangeEnd = contentEnd
                break
            }
            let next = NSMaxRange(lineRange)
            if next <= cursor { break }
            cursor = next
            currentLine += 1
        }

        guard let start = rangeStart else { return nil }
        let end = rangeEnd ?? value.length
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private static func clampRange(_ range: NSRange, maxLength: Int) -> NSRange? {
        guard maxLength > 0,
              range.location != NSNotFound,
              range.length > 0 else {
            return nil
        }
        let start = max(0, min(range.location, maxLength))
        let end = max(start, min(range.location + range.length, maxLength))
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private static func resolveSinglePDFSelection(
        for annotation: Annotation,
        in document: PDFDocument,
        allowRectFallback: Bool
    ) -> PDFSelection? {
        let rawPageIndex = annotation.locator.payload["pageIndex"]
        let parsedPageIndex = rawPageIndex.flatMap(Int.init)
        if allowRectFallback, rawPageIndex != nil {
            guard let pageIndex = parsedPageIndex,
                  pageIndex >= 0,
                  pageIndex < document.pageCount else {
                return nil
            }
        }
        let targetPage: PDFPage? = (allowRectFallback ? parsedPageIndex : nil).flatMap { index in
            guard index >= 0, index < document.pageCount else { return nil }
            return document.page(at: index)
        }
        let rawQuote = annotation.locator.textQuote?.exact ?? annotation.selectedText
        let quote = rawQuote?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let quote, !quote.isEmpty {
            let exactMatches = document.findString(quote, withOptions: [])
            let matches = exactMatches.isEmpty
                ? document.findString(quote, withOptions: [.caseInsensitive])
                : exactMatches
            let candidates = targetPage.map { page in matches.filter { $0.pages.contains(page) } } ?? matches
            if candidates.count == 1 { return candidates[0] }
            // A rectangle is evidence only within the revision that captured it.
            // When a quote repeats, never silently choose the first occurrence.
            guard candidates.count > 1, allowRectFallback, let targetPage,
                  let rectAnchor = PDFPageRectAnchor.parse(annotation.locator.payload["rect"]),
                  let rect = rectAnchor.clipped(to: targetPage.bounds(for: .mediaBox)) else { return nil }
            let scored = candidates.map { selection in
                let overlap = selection.bounds(for: targetPage).intersection(rect)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                return (selection: selection, area: area)
            }.sorted { $0.area > $1.area }
            guard let best = scored.first, best.area > 0,
                  best.area > scored[1].area else { return nil }
            return best.selection
        }

        if let targetPage {
            if allowRectFallback,
               let rectAnchor = PDFPageRectAnchor.parse(annotation.locator.payload["rect"]),
               let rect = rectAnchor.clipped(to: targetPage.bounds(for: .mediaBox)),
               let selection = targetPage.selection(for: rect),
               selection.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return selection
            }
            return nil
        }

        return nil
    }

    private static func addInlinePDFHighlight(bounds: CGRect, on page: PDFPage) {
        guard !bounds.isNull,
              !bounds.isEmpty,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }
        let highlight = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        highlight.userName = pdfAnnotationUserName
        highlight.color = pdfHighlightColor
        page.addAnnotation(highlight)
    }
}
