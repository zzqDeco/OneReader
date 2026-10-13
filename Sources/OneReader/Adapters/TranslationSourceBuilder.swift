import Foundation
import Markdown
import SwiftSoup

/// Deterministic source extraction. Never reads translated text or lets a model choose its scope.
enum TranslationSourceBuilder {
    static func prepare(document: PresentationDocument, locator: Locator,
                        nextLocator: Locator?, selection: ReaderSelection?,
                        plan: AdapterPlan, coordinator: AdapterCoordinator,
                        database: LibraryDatabase) async throws -> [TranslationSegment] {
        let values: [TranslationSegment]
        switch document.surface {
        case .nativeMarkdown, .nativeText:
            guard let text = document.content else { throw TranslationError.noText }
            values = try textSegments(text, locator: locator, nextLocator: nextLocator,
                                      selection: selection, markdown: document.surface == .nativeMarkdown)
        case .sanitizedWeb:
            guard let html = document.content else { throw TranslationError.noText }
            values = try htmlSegments(html, locator: locator, selection: selection)
        case .pdfKit, .quickLook:
            // OCR can supply a real read route without changing the PDF/image presentation.
            guard let readID = plan.capabilityRoutes[.read] else { throw TranslationError.noText }
            var readLocator = locator
            if readID != locator.adapterID, plan.capabilityRoutes[.list] == readID {
                let nodes = try await coordinator.list(plan: plan, limit: 2_000)
                if let current = nodes.first(where: {
                    $0.isReadable && $0.locator.adapterID == readID && $0.locator.pdfPageIndex == locator.pdfPageIndex
                }) { readLocator = current.locator }
            }
            let anchor = Locator(sourceID: readLocator.sourceID, snapshotID: readLocator.snapshotID,
                adapterID: readID, payload: readLocator.payload, structuralPath: readLocator.structuralPath,
                textQuote: readLocator.textQuote, fingerprint: readLocator.fingerprint)
            let observation = try await coordinator.read(plan: plan, locator: anchor,
                maxCharacters: TranslationRequest.maximumCharacters, persistObservation: false)
            values = try textSegments(observation.content, locator: observation.locator,
                nextLocator: nil, selection: selection, markdown: false, pageRelative: true)
        case .nativeCode:
            throw TranslationError.noText
        }
        guard values.contains(where: { !$0.isVerbatim }) else { throw TranslationError.noText }
        for value in values {
            try Task.checkCancellation()
            try database.saveObservation(Observation(
                id: "translation-source:\(value.id)", sourceID: value.locator.sourceID,
                snapshotID: value.locator.snapshotID, adapterID: value.locator.adapterID,
                locator: value.locator, mediaType: "text/plain; source=translation-fragment",
                content: value.originalText, contentReference: nil, contentDigest: value.originalDigest,
                truncated: false, observedAt: .now
            ))
        }
        return values
    }

    static func textSegments(_ text: String, locator: Locator, nextLocator: Locator? = nil,
                             selection: ReaderSelection? = nil, markdown: Bool,
                             pageRelative: Bool = false) throws -> [TranslationSegment] {
        let source = text as NSString
        let scope: NSRange
        if let selection {
            if !pageRelative,
               let start = Int(selection.locator.payload["startUTF16"] ?? ""),
               let end = Int(selection.locator.payload["endUTF16"] ?? ""), end > start,
               let range = Range(NSRange(location: start, length: end - start), in: text),
               selection.locator.textQuote?.exact == String(text[range]) {
                scope = NSRange(range, in: text)
            } else {
                let quote = selection.locator.textQuote?.exact ?? selection.text
                let matches = ranges(of: quote, in: text)
                guard matches.count == 1 else { throw TranslationError.selectionNotGrounded }
                scope = matches[0]
            }
        } else if pageRelative {
            scope = NSRange(location: 0, length: source.length)
        } else {
            let start = offset(line: locator.lineRange?.lowerBound ?? 1, in: text)
            let end = nextLocator?.lineRange.map { offset(line: $0.lowerBound, in: text) } ?? source.length
            scope = NSRange(location: start, length: max(0, end - start))
        }
        let parseText: String
        let parseOffset: Int
        if selection == nil, let bounded = Range(scope, in: text) {
            let end = text.index(bounded.lowerBound, offsetBy: 16_384, limitedBy: bounded.upperBound) ?? bounded.upperBound
            parseText = String(text[bounded.lowerBound..<end])
            parseOffset = scope.location
        } else {
            parseText = text; parseOffset = 0
        }
        func absolute(_ range: NSRange) -> NSRange {
            NSRange(location: range.location + parseOffset, length: range.length)
        }
        var blocks: [(NSRange, Bool)] = []
        var codeRanges: [NSRange] = []
        for pattern in [#"\$\$[\s\S]*?\$\$|\$[^$\n]+\$"#, #"\]\([^\n)]*\)"#, #"https?://[^\s<>]+"#] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                codeRanges += regex.matches(in: parseText, range: NSRange(location: 0, length: parseText.utf16.count)).map { absolute($0.range) }
            }
        }
        if markdown {
            let document = Document(parsing: parseText)
            func visitInline(_ node: any Markup) {
                if node is InlineCode, let range = node.range,
                   let native = sourceRange(range, in: parseText) { codeRanges.append(absolute(native)) }
                for child in node.children { visitInline(child) }
            }
            visitInline(document)
            func visit(_ node: any Markup) {
                if node is Paragraph || node is Heading || node is CodeBlock || node is HTMLBlock || node is ThematicBreak {
                    if let range = node.range, let native = sourceRange(range, in: parseText) {
                        blocks.append((absolute(native), node is CodeBlock || node is HTMLBlock || node is ThematicBreak))
                    }
                    return
                }
                for child in node.children { visit(child) }
            }
            visit(document)
        } else {
            let expression = try NSRegularExpression(pattern: #"[^\r\n]+(?:\r?\n(?!\s*\r?\n)[^\r\n]+)*"#)
            blocks = expression.matches(in: parseText, range: NSRange(location: 0, length: parseText.utf16.count)).map { (absolute($0.range), false) }
        }
        var values: [TranslationSegment] = []
        var total = 0
        for (block, verbatim) in blocks {
            let range = NSIntersectionRange(block, scope)
            guard range.length > 0, let swiftRange = Range(range, in: text) else { continue }
            // Grapheme-safe chunks retain distinct source positions even for repeated paragraphs.
            var lower = swiftRange.lowerBound
            while lower < swiftRange.upperBound, values.count < TranslationRequest.maximumSegments {
                let maximum = min(TranslationRequest.maximumSegmentCharacters, TranslationRequest.maximumCharacters - total)
                guard maximum > 0 else { break }
                var upper = lower
                var size = 0
                while upper < swiftRange.upperBound {
                    let next = text.index(after: upper)
                    let count = text[upper..<next].utf16.count
                    guard size + count <= maximum else { break }
                    size += count; upper = next
                }
                guard upper > lower else { break }
                let part = NSRange(lower..<upper, in: text)
                let body = String(text[lower..<upper])
                var payload = cleanPayload(locator.payload)
                if pageRelative {
                    payload["pageTextStartUTF16"] = String(part.location)
                    payload["pageTextEndUTF16"] = String(NSMaxRange(part))
                } else {
                    payload["indexTextRange"] = "utf16"
                    payload["startUTF16"] = String(part.location)
                    payload["endUTF16"] = String(NSMaxRange(part))
                    payload["startLine"] = String(1 + text[..<lower].filter { $0 == "\n" }.count)
                    payload["endLine"] = String(1 + text[..<upper].filter { $0 == "\n" }.count)
                }
                let anchor = Locator(sourceID: locator.sourceID, snapshotID: locator.snapshotID,
                    adapterID: locator.adapterID, payload: payload, structuralPath: locator.structuralPath,
                    textQuote: TextQuote(prefix: nil, exact: body, suffix: nil), fingerprint: AdapterUtilities.sha256(body))
                let inlineCode = codeRanges.compactMap { code -> String? in
                    let overlap = NSIntersectionRange(code, part)
                    guard overlap.length > 0 else { return nil }
                    return source.substring(with: overlap)
                }
                values.append(makeSegment(body, locator: anchor, order: values.count,
                    verbatim: verbatim, protectedText: inlineCode))
                total += size; lower = upper
            }
            if total >= TranslationRequest.maximumCharacters || values.count >= TranslationRequest.maximumSegments { break }
        }
        return values
    }

    static func htmlSegments(_ html: String, locator: Locator, selection: ReaderSelection?) throws -> [TranslationSegment] {
        let document = try SwiftSoup.parse(html)
        try document.select("script,style,iframe,form,svg,math").remove()
        var elements = try document.select("h1,h2,h3,h4,h5,h6,p,li,pre,td,th").array()
        // Avoid emitting duplicate paragraphs nested under list items/table cells.
        elements = elements.filter { element in
            !["li", "td", "th"].contains(element.tagName()) || (try? element.select("p,pre").isEmpty()) == true
        }
        if elements.isEmpty, let body = document.body() { elements = [body] }
        let requestedPath = selection?.locator.payload["domPath"] ?? locator.payload["domPath"]
        let start = try requestedPath.flatMap { path in
            try elements.firstIndex { try HTMLSanitizer.stableDOMPath(for: $0) == path }
        } ?? 0
        var output: [TranslationSegment] = []
        var total = 0
        for element in elements.dropFirst(start) {
            if selection == nil, !output.isEmpty, element.tagName().hasPrefix("h"), element.tagName().count == 2 { break }
            var body = try element.text()
            if let selection {
                let quote = selection.locator.textQuote?.exact ?? selection.text
                let matches = ranges(of: quote, in: body)
                if matches.count != 1 { continue }
                body = (body as NSString).substring(with: matches[0])
            }
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // Large DOM blocks are left untranslated rather than losing inline-code boundaries.
            guard body.utf16.count <= TranslationRequest.maximumSegmentCharacters,
                  total + body.utf16.count <= TranslationRequest.maximumCharacters else { break }
            var payload = cleanPayload(locator.payload)
            payload["domPath"] = try HTMLSanitizer.stableDOMPath(for: element)
            let anchor = Locator(sourceID: locator.sourceID, snapshotID: locator.snapshotID,
                adapterID: locator.adapterID, payload: payload, structuralPath: payload["domPath"],
                textQuote: TextQuote(prefix: nil, exact: body, suffix: nil), fingerprint: AdapterUtilities.sha256(body))
            let protected = try element.select("code,kbd,samp").array().map { try $0.text() }
            output.append(makeSegment(body, locator: anchor, order: output.count,
                verbatim: element.tagName() == "pre", protectedText: protected))
            total += body.utf16.count
            if selection != nil || output.count >= TranslationRequest.maximumSegments { break }
        }
        if selection != nil, output.isEmpty { throw TranslationError.selectionNotGrounded }
        return output
    }

    private static func makeSegment(_ text: String, locator: Locator, order: Int,
                                    verbatim: Bool, protectedText: [String] = []) -> TranslationSegment {
        var protectedRanges: [NSRange] = []
        // Targets and code/math are opaque; they are restored by the host, never interpreted as markup.
        let patterns = [#"`+[^`]*`+"#, #"\$\$[\s\S]*?\$\$|\$[^$\n]+\$"#,
                        #"\]\([^\n)]*\)"#, #"https?://[^\s<>]+"#, #"<[^>]+>"#]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                protectedRanges += regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).map(\.range)
            }
        }
        for item in protectedText where !item.isEmpty { protectedRanges += ranges(of: item, in: text) }
        var accepted: [NSRange] = []
        for range in protectedRanges.sorted(by: { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }) {
            if let last = accepted.last, NSMaxRange(last) > range.location { continue }
            accepted.append(range)
        }
        var modelText = text
        var spans: [TranslationProtectedSpan] = []
        let digest = AdapterUtilities.sha256(text)
        for (index, range) in accepted.enumerated().reversed() {
            let token = "⟦OR_KEEP_\(digest.prefix(8))_\(index)⟧"
            let original = (text as NSString).substring(with: range)
            if let swiftRange = Range(range, in: modelText) {
                modelText.replaceSubrange(swiftRange, with: token)
                spans.insert(TranslationProtectedSpan(token: token, original: original), at: 0)
            }
        }
        let id = "fragment:" + AdapterUtilities.sha256(locator.stableID + "|" + digest)
        return TranslationSegment(id: id, order: order,
            fragment: SourceFragment(id: id, sourceID: locator.sourceID, locator: locator,
                                     role: .primary, label: "原文第 \(order + 1) 段"),
            originalText: text, originalDigest: digest, modelText: modelText,
            protectedSpans: spans, isVerbatim: verbatim)
    }

    private static func cleanPayload(_ payload: [String: String]) -> [String: String] {
        var removed: Set<String> = ["renderedStartUTF16", "textViewportOffsetY", "textViewportX",
            "positionKind", "viewportX", "viewportY", "viewportScreenX", "viewportScreenY",
            "scrollFraction", "outlineDOMPath", "pageTextStartUTF16", "pageTextEndUTF16"]
        // A native viewport rectangle is not a paragraph's bounds. OCR span rectangles are.
        if payload["derivedText"] != "ocr" { removed.insert("rect") }
        return payload.filter { !removed.contains($0.key) }
    }

    private static func ranges(of needle: String, in text: String) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        var result: [NSRange] = [], start = text.startIndex
        while start < text.endIndex, let range = text.range(of: needle, range: start..<text.endIndex) {
            result.append(NSRange(range, in: text)); start = range.upperBound
        }
        return result
    }

    private static func offset(line: Int, in text: String) -> Int {
        guard line > 1 else { return 0 }
        var current = 1
        for index in text.indices where text[index] == "\n" {
            current += 1
            if current == line { return text.index(after: index).utf16Offset(in: text) }
        }
        return text.utf16.count
    }

    private static func sourceRange(_ range: SourceRange, in text: String) -> NSRange? {
        func index(_ location: SourceLocation) -> String.Index? {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            guard location.line > 0, location.line <= lines.count, location.column > 0 else { return nil }
            let line = lines[location.line - 1]
            guard location.column - 1 <= line.utf8.count else { return nil }
            return String.Index(line.utf8.index(line.utf8.startIndex, offsetBy: location.column - 1), within: text)
        }
        guard let lower = index(range.lowerBound), let upper = index(range.upperBound), upper >= lower else { return nil }
        return NSRange(lower..<upper, in: text)
    }
}
