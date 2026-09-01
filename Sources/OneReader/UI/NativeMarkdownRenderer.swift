import AppKit
import Markdown
import SwiftSoup

/// Converts untrusted Markdown into a native, selectable attributed document.
/// Raw HTML and image payloads are never executed or fetched here.
struct NativeMarkdownRenderer: MarkupVisitor {
    typealias Result = NSMutableAttributedString

    let fontSize: CGFloat
    let lineSpacing: CGFloat
    private var sourceIndex: MarkdownUTF16SourceIndex?

    init(fontSize: CGFloat, lineSpacing: CGFloat) {
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
    }

    mutating func render(_ source: String) -> NSAttributedString {
        sourceIndex = MarkdownUTF16SourceIndex(source: source)
        let document = Markdown.Document(parsing: source)
        let result = visit(document)
        trimTrailingNewlines(result)
        return result
    }

    mutating func defaultVisit(_ markup: any Markup) -> NSMutableAttributedString {
        renderChildren(of: markup)
    }

    mutating func visitDocument(_ document: Markdown.Document) -> NSMutableAttributedString {
        renderChildren(of: document)
    }

    mutating func visitText(_ text: Markdown.Text) -> NSMutableAttributedString {
        mappedAttributed(
            text.string,
            sourceRange: text.range,
            decodesMarkdownText: true
        )
    }

    mutating func visitHeading(_ heading: Heading) -> NSMutableAttributedString {
        let result = renderChildren(of: heading)
        trimTrailingNewlines(result)
        result.append(attributed("\n"))
        let scale: CGFloat
        switch heading.level {
        case 1: scale = 1.72
        case 2: scale = 1.42
        case 3: scale = 1.20
        default: scale = 1.06
        }
        result.addAttributes(
            [
                .font: NSFont.systemFont(
                    ofSize: fontSize * scale,
                    weight: heading.level <= 2 ? .bold : .semibold
                ),
                .paragraphStyle: paragraphStyle(
                    paragraphSpacingBefore: heading.level <= 2 ? 18 : 12,
                    paragraphSpacing: heading.level <= 2 ? 12 : 8
                ),
            ],
            range: result.fullRange
        )
        return result
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> NSMutableAttributedString {
        let result = renderChildren(of: paragraph)
        trimTrailingNewlines(result)
        result.append(attributed("\n"))
        result.addAttribute(
            .paragraphStyle,
            value: paragraphStyle(paragraphSpacing: 10),
            range: result.fullRange
        )
        return result
    }

    mutating func visitStrong(_ strong: Strong) -> NSMutableAttributedString {
        applyingFontTrait(.boldFontMask, to: renderChildren(of: strong))
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> NSMutableAttributedString {
        applyingFontTrait(.italicFontMask, to: renderChildren(of: emphasis))
    }

    mutating func visitStrikethrough(
        _ strikethrough: Strikethrough
    ) -> NSMutableAttributedString {
        let result = renderChildren(of: strikethrough)
        result.addAttribute(
            .strikethroughStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: result.fullRange
        )
        return result
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> NSMutableAttributedString {
        mappedAttributed(
            inlineCode.code,
            sourceRange: inlineCode.range,
            decodesMarkdownText: false,
            attributes: [
                .font: NSFont.monospacedSystemFont(
                    ofSize: max(11, fontSize - 1),
                    weight: .regular
                ),
                .backgroundColor: NSColor.quaternaryLabelColor,
            ]
        )
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> NSMutableAttributedString {
        let code = codeBlock.code.trimmingCharacters(in: .newlines)
        let result = mappedAttributed(
            code,
            sourceRange: codeBlock.range,
            decodesMarkdownText: false,
            attributes: [
                .font: NSFont.monospacedSystemFont(
                    ofSize: max(11, fontSize - 2),
                    weight: .regular
                ),
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.quaternaryLabelColor,
                .paragraphStyle: paragraphStyle(
                    paragraphSpacingBefore: 8,
                    paragraphSpacing: 12,
                    firstLineHeadIndent: 12,
                    headIndent: 12,
                    tailIndent: -12
                ),
            ]
        )
        result.append(attributed("\n"))
        return result
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> NSMutableAttributedString {
        let result = renderChildren(of: blockQuote)
        trimTrailingNewlines(result)
        result.insert(attributed("│  "), at: 0)
        result.append(attributed("\n"))
        result.addAttributes(
            [
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle(
                    paragraphSpacingBefore: 8,
                    paragraphSpacing: 10,
                    firstLineHeadIndent: 8,
                    headIndent: 24,
                    tailIndent: -8
                ),
            ],
            range: result.fullRange
        )
        return result
    }

    mutating func visitUnorderedList(
        _ unorderedList: UnorderedList
    ) -> NSMutableAttributedString {
        renderList(unorderedList, startIndex: nil)
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> NSMutableAttributedString {
        renderList(orderedList, startIndex: Int(orderedList.startIndex))
    }

    mutating func visitListItem(_ listItem: ListItem) -> NSMutableAttributedString {
        renderChildren(of: listItem)
    }

    mutating func visitLink(_ link: Link) -> NSMutableAttributedString {
        let result = renderChildren(of: link)
        guard let destination = link.destination,
              let url = URL(string: destination),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return result
        }
        result.addAttributes(
            [
                .link: url,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ],
            range: result.fullRange
        )
        return result
    }

    mutating func visitImage(_ image: Image) -> NSMutableAttributedString {
        let alt = renderChildren(of: image)
        trimTrailingNewlines(alt)
        let result = attributed("［")
        result.append(alt.string.isEmpty ? attributed("图片") : alt)
        result.append(attributed("］"))
        result.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: max(11, fontSize - 1)),
                .foregroundColor: NSColor.secondaryLabelColor,
            ],
            range: result.fullRange
        )
        return result
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> NSMutableAttributedString {
        attributed(" ")
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> NSMutableAttributedString {
        attributed("\n")
    }

    mutating func visitThematicBreak(
        _ thematicBreak: ThematicBreak
    ) -> NSMutableAttributedString {
        NSMutableAttributedString(
            string: "────────────────────────\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: max(10, fontSize - 3)),
                .foregroundColor: NSColor.separatorColor,
                .paragraphStyle: paragraphStyle(
                    paragraphSpacingBefore: 10,
                    paragraphSpacing: 10
                ),
            ]
        )
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> NSMutableAttributedString {
        NSMutableAttributedString(string: "")
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> NSMutableAttributedString {
        NSMutableAttributedString(string: "")
    }

    mutating func visitTableRow(_ tableRow: Table.Row) -> NSMutableAttributedString {
        let result = renderChildren(of: tableRow)
        trimTrailingCharacters(CharacterSet(charactersIn: "\t"), in: result)
        result.append(attributed("\n"))
        return result
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) -> NSMutableAttributedString {
        let result = renderChildren(of: tableCell)
        result.append(attributed("\t"))
        return result
    }

    private mutating func renderChildren(
        of markup: any Markup
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: "")
        for child in markup.children {
            result.append(visit(child))
        }
        return result
    }

    private mutating func renderList(
        _ markup: any Markup,
        startIndex: Int?
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: "")
        var itemIndex = startIndex ?? 1
        for child in markup.children {
            guard let item = child as? ListItem else { continue }
            let body = visitListItem(item)
            trimTrailingNewlines(body)
            let prefix = startIndex == nil ? "•  " : "\(itemIndex).  "
            body.insert(attributed(prefix), at: 0)
            body.append(attributed("\n"))
            body.addAttribute(
                .paragraphStyle,
                value: paragraphStyle(
                    paragraphSpacing: 4,
                    firstLineHeadIndent: 8,
                    headIndent: 28,
                    tailIndent: -8
                ),
                range: body.fullRange
            )
            result.append(body)
            itemIndex += 1
        }
        result.append(attributed("\n"))
        return result
    }

    private func attributed(_ string: String) -> NSMutableAttributedString {
        NSMutableAttributedString(
            string: string,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.labelColor,
            ]
        )
    }

    private mutating func mappedAttributed(
        _ string: String,
        sourceRange: SourceRange?,
        decodesMarkdownText: Bool,
        attributes: [NSAttributedString.Key: Any]? = nil
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(
            string: string,
            attributes: attributes ?? [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        guard !string.isEmpty,
              let sourceIndex,
              let sourceUTF16Range = sourceIndex.utf16Range(for: sourceRange) else {
            return result
        }
        for run in MarkdownLeafSourceMapper.runs(
            rendered: string,
            source: sourceIndex.source,
            sourceRange: sourceUTF16Range,
            decodesMarkdownText: decodesMarkdownText
        ) {
            result.addAttributes(
                [
                    .oneReaderSourceUTF16Start: run.source.location,
                    .oneReaderSourceUTF16End: NSMaxRange(run.source),
                ],
                range: run.rendered
            )
        }
        return result
    }

    private func paragraphStyle(
        paragraphSpacingBefore: CGFloat = 0,
        paragraphSpacing: CGFloat = 0,
        firstLineHeadIndent: CGFloat = 0,
        headIndent: CGFloat = 0,
        tailIndent: CGFloat = 0
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacingBefore = paragraphSpacingBefore
        style.paragraphSpacing = paragraphSpacing
        style.firstLineHeadIndent = firstLineHeadIndent
        style.headIndent = headIndent
        style.tailIndent = tailIndent
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private func applyingFontTrait(
        _ trait: NSFontTraitMask,
        to result: NSMutableAttributedString
    ) -> NSMutableAttributedString {
        let snapshot = NSAttributedString(attributedString: result)
        snapshot.enumerateAttribute(.font, in: snapshot.fullRange) { value, range, _ in
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: fontSize)
            let converted = NSFontManager.shared.convert(font, toHaveTrait: trait)
            result.addAttribute(.font, value: converted, range: range)
        }
        return result
    }

    private func trimTrailingNewlines(_ value: NSMutableAttributedString) {
        trimTrailingCharacters(.newlines, in: value)
    }

    private func trimTrailingCharacters(
        _ characters: CharacterSet,
        in value: NSMutableAttributedString
    ) {
        while let scalar = value.string.unicodeScalars.last,
              characters.contains(scalar) {
            let string = value.string as NSString
            let range = string.rangeOfComposedCharacterSequence(at: string.length - 1)
            value.deleteCharacters(in: range)
        }
    }
}

private struct MarkdownUTF16SourceIndex {
    let source: String
    private let lineStartUTF8Offsets: [Int]
    private let utf8Count: Int

    init(source: String) {
        self.source = source
        let bytes = Array(source.utf8)
        var starts = [0]
        for (offset, byte) in bytes.enumerated() where byte == 0x0A {
            starts.append(offset + 1)
        }
        lineStartUTF8Offsets = starts
        utf8Count = bytes.count
    }

    func utf16Range(for range: SourceRange?) -> NSRange? {
        guard let range,
              let lower = utf16Offset(for: range.lowerBound),
              let upper = utf16Offset(for: range.upperBound),
              upper >= lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    private func utf16Offset(for location: SourceLocation) -> Int? {
        guard location.line > 0,
              location.line <= lineStartUTF8Offsets.count,
              location.column > 0 else { return nil }
        let byteOffset = lineStartUTF8Offsets[location.line - 1] + location.column - 1
        guard byteOffset >= 0, byteOffset <= utf8Count else { return nil }
        let utf8 = source.utf8
        let utf8Index = utf8.index(utf8.startIndex, offsetBy: byteOffset)
        guard let stringIndex = String.Index(utf8Index, within: source) else { return nil }
        return stringIndex.utf16Offset(in: source)
    }
}

private enum MarkdownLeafSourceMapper {
    struct Run {
        let rendered: NSRange
        let source: NSRange
    }

    static func runs(
        rendered: String,
        source: String,
        sourceRange: NSRange,
        decodesMarkdownText: Bool
    ) -> [Run] {
        let sourceValue = source as NSString
        let renderedValue = rendered as NSString
        guard sourceRange.location != NSNotFound,
              NSMaxRange(sourceRange) <= sourceValue.length else { return [] }
        let raw = sourceValue.substring(with: sourceRange) as NSString
        var sourceOffset = 0
        var renderedOffset = 0
        var result: [Run] = []

        while sourceOffset < raw.length, renderedOffset < renderedValue.length {
            let renderedCharacterRange = renderedValue.rangeOfComposedCharacterSequence(
                at: renderedOffset
            )
            let renderedCharacter = renderedValue.substring(with: renderedCharacterRange)

            if decodesMarkdownText,
               raw.character(at: sourceOffset) == 0x5C,
               sourceOffset + 1 < raw.length {
                let escapedRange = raw.rangeOfComposedCharacterSequence(at: sourceOffset + 1)
                if raw.substring(with: escapedRange) == renderedCharacter {
                    result.append(Run(
                        rendered: renderedCharacterRange,
                        source: NSRange(
                            location: sourceRange.location + sourceOffset,
                            length: NSMaxRange(escapedRange) - sourceOffset
                        )
                    ))
                    sourceOffset = NSMaxRange(escapedRange)
                    renderedOffset = NSMaxRange(renderedCharacterRange)
                    continue
                }
            }

            if decodesMarkdownText,
               raw.character(at: sourceOffset) == 0x26,
               let entity = entityRun(
                   raw: raw,
                   sourceOffset: sourceOffset,
                   rendered: renderedValue,
                   renderedOffset: renderedOffset,
                   sourceBase: sourceRange.location
               ) {
                result.append(entity.run)
                sourceOffset = entity.nextSourceOffset
                renderedOffset = entity.nextRenderedOffset
                continue
            }

            let sourceCharacterRange = raw.rangeOfComposedCharacterSequence(at: sourceOffset)
            if raw.substring(with: sourceCharacterRange) == renderedCharacter {
                result.append(Run(
                    rendered: renderedCharacterRange,
                    source: NSRange(
                        location: sourceRange.location + sourceCharacterRange.location,
                        length: sourceCharacterRange.length
                    )
                ))
                sourceOffset = NSMaxRange(sourceCharacterRange)
                renderedOffset = NSMaxRange(renderedCharacterRange)
            } else {
                sourceOffset = NSMaxRange(sourceCharacterRange)
            }
        }
        return result
    }

    private static func entityRun(
        raw: NSString,
        sourceOffset: Int,
        rendered: NSString,
        renderedOffset: Int,
        sourceBase: Int
    ) -> (run: Run, nextSourceOffset: Int, nextRenderedOffset: Int)? {
        let remaining = NSRange(
            location: sourceOffset,
            length: min(64, raw.length - sourceOffset)
        )
        let semicolon = raw.range(of: ";", options: [], range: remaining)
        guard semicolon.location != NSNotFound else { return nil }
        let entityRange = NSRange(
            location: sourceOffset,
            length: NSMaxRange(semicolon) - sourceOffset
        )
        let encoded = raw.substring(with: entityRange)
        guard let decoded = try? Entities.unescape(encoded),
              decoded != encoded,
              !decoded.isEmpty else { return nil }
        let decodedLength = (decoded as NSString).length
        guard renderedOffset + decodedLength <= rendered.length,
              rendered.substring(with: NSRange(
                  location: renderedOffset,
                  length: decodedLength
              )) == decoded else { return nil }
        return (
            Run(
                rendered: NSRange(location: renderedOffset, length: decodedLength),
                source: NSRange(
                    location: sourceBase + sourceOffset,
                    length: entityRange.length
                )
            ),
            NSMaxRange(entityRange),
            renderedOffset + decodedLength
        )
    }
}

enum MarkdownSourceMap {
    static func renderedRange(
        forSourceRange sourceRange: NSRange,
        in rendered: NSAttributedString
    ) -> NSRange? {
        guard sourceRange.location != NSNotFound, sourceRange.length >= 0 else { return nil }
        var renderedStart: Int?
        var renderedEnd: Int?
        rendered.enumerateAttribute(
            .oneReaderSourceUTF16Start,
            in: rendered.fullRange
        ) { value, range, _ in
            guard let sourceStart = value as? Int,
                  let sourceEnd = rendered.attribute(
                      .oneReaderSourceUTF16End,
                      at: range.location,
                      effectiveRange: nil
                  ) as? Int,
                  sourceStart < NSMaxRange(sourceRange),
                  sourceEnd > sourceRange.location else { return }
            let lower = max(sourceRange.location, sourceStart)
            let upper = min(NSMaxRange(sourceRange), sourceEnd)
            let candidateStart: Int
            let candidateEnd: Int
            if sourceEnd - sourceStart == range.length {
                candidateStart = range.location + lower - sourceStart
                candidateEnd = range.location + upper - sourceStart
            } else {
                candidateStart = range.location
                candidateEnd = NSMaxRange(range)
            }
            renderedStart = min(renderedStart ?? candidateStart, candidateStart)
            renderedEnd = max(renderedEnd ?? candidateEnd, candidateEnd)
        }
        guard let renderedStart, let renderedEnd, renderedEnd >= renderedStart else { return nil }
        return NSRange(location: renderedStart, length: renderedEnd - renderedStart)
    }

    static func sourceRange(
        forRenderedRange renderedRange: NSRange,
        in rendered: NSAttributedString
    ) -> NSRange? {
        guard renderedRange.location != NSNotFound,
              renderedRange.length > 0,
              NSMaxRange(renderedRange) <= rendered.length else { return nil }
        var sourceStart: Int?
        var sourceEnd: Int?
        rendered.enumerateAttribute(
            .oneReaderSourceUTF16Start,
            in: rendered.fullRange
        ) { value, effectiveRange, _ in
            guard let mappedStart = value as? Int,
                  let mappedEnd = rendered.attribute(
                      .oneReaderSourceUTF16End,
                      at: effectiveRange.location,
                      effectiveRange: nil
                  ) as? Int else { return }
            let intersection = NSIntersectionRange(renderedRange, effectiveRange)
            guard intersection.length > 0 else { return }
            let candidateStart: Int
            let candidateEnd: Int
            if mappedEnd - mappedStart == effectiveRange.length {
                candidateStart = mappedStart + intersection.location - effectiveRange.location
                candidateEnd = candidateStart + intersection.length
            } else {
                candidateStart = mappedStart
                candidateEnd = mappedEnd
            }
            sourceStart = min(sourceStart ?? candidateStart, candidateStart)
            sourceEnd = max(sourceEnd ?? candidateEnd, candidateEnd)
        }
        guard let sourceStart, let sourceEnd, sourceEnd >= sourceStart else { return nil }
        return NSRange(location: sourceStart, length: sourceEnd - sourceStart)
    }
}

extension NSAttributedString.Key {
    static let oneReaderSourceUTF16Start = NSAttributedString.Key(
        "com.onereader.markdown.source-utf16-start"
    )
    static let oneReaderSourceUTF16End = NSAttributedString.Key(
        "com.onereader.markdown.source-utf16-end"
    )
}

private extension NSAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}
