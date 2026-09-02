#if os(macOS)
import AppKit
private typealias PlatformFont = NSFont
private typealias PlatformColor = NSColor
#else
import UIKit
private typealias PlatformFont = UIFont
private typealias PlatformColor = UIColor
#endif
import Markdown
import SwiftSoup

private enum PlatformFontTrait {
    case bold
    case italic
}

private extension PlatformColor {
    static var readerLabel: PlatformColor {
#if os(macOS)
        .labelColor
#else
        .label
#endif
    }

    static var readerSecondaryLabel: PlatformColor {
#if os(macOS)
        .secondaryLabelColor
#else
        .secondaryLabel
#endif
    }

    static var readerQuaternaryLabel: PlatformColor {
#if os(macOS)
        .quaternaryLabelColor
#else
        .quaternaryLabel
#endif
    }

    static var readerLink: PlatformColor {
#if os(macOS)
        .linkColor
#else
        .link
#endif
    }

    static var readerSeparator: PlatformColor {
#if os(macOS)
        .separatorColor
#else
        .separator
#endif
    }
}

/// Converts untrusted Markdown into a native, selectable attributed document.
/// Raw HTML and image payloads are never executed or fetched here.
struct NativeMarkdownRenderer: MarkupVisitor {
    typealias Result = NSMutableAttributedString

    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let resourceRootURL: URL?
    let maximumImageWidth: CGFloat
    private var sourceIndex: MarkdownUTF16SourceIndex?

    init(
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        resourceRootURL: URL? = nil,
        maximumImageWidth: CGFloat = 680
    ) {
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.resourceRootURL = resourceRootURL
        self.maximumImageWidth = maximumImageWidth
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
                .font: readerSerifFont(
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
        applyingFontTrait(.bold, to: renderChildren(of: strong))
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> NSMutableAttributedString {
        applyingFontTrait(.italic, to: renderChildren(of: emphasis))
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
            sourceUTF16Range: sourceIndex?.inlineCodeContentRange(
                for: inlineCode.range,
                rendered: inlineCode.code
            ),
            unavailableSourceUTF16Range: sourceIndex?.utf16Range(for: inlineCode.range),
            decodesMarkdownText: false,
            attributes: [
                .font: PlatformFont.monospacedSystemFont(
                    ofSize: max(11, fontSize - 1),
                    weight: .regular
                ),
                .backgroundColor: PlatformColor.readerQuaternaryLabel,
            ]
        )
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> NSMutableAttributedString {
        let code = codeBlock.code.trimmingCharacters(in: .newlines)
        let result = mappedAttributed(
            code,
            sourceUTF16Range: sourceIndex?.codeBlockContentRange(for: codeBlock.range),
            unavailableSourceUTF16Range: sourceIndex?.utf16Range(for: codeBlock.range),
            decodesMarkdownText: false,
            attributes: [
                .font: PlatformFont.monospacedSystemFont(
                    ofSize: max(11, fontSize - 2),
                    weight: .regular
                ),
                .foregroundColor: PlatformColor.readerLabel,
                .backgroundColor: PlatformColor.readerQuaternaryLabel,
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
                .foregroundColor: PlatformColor.readerSecondaryLabel,
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
                .foregroundColor: PlatformColor.readerLink,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ],
            range: result.fullRange
        )
        return result
    }

    mutating func visitImage(_ image: Image) -> NSMutableAttributedString {
        let alt = renderChildren(of: image)
        trimTrailingNewlines(alt)
        if let attachment = imageAttachment(for: image.source) {
            let result = NSMutableAttributedString(attachment: attachment)
            if !alt.string.isEmpty {
                let caption = attributed("\n\(alt.string)\n")
                caption.addAttributes(
                    [
                        .font: PlatformFont.systemFont(ofSize: max(11, fontSize - 2)),
                        .foregroundColor: PlatformColor.readerSecondaryLabel,
                        .paragraphStyle: paragraphStyle(paragraphSpacing: 10),
                    ],
                    range: caption.fullRange
                )
                result.append(caption)
            }
            markSourceMappingUnavailable(
                result,
                sourceRange: sourceIndex?.utf16Range(for: image.range)
            )
            return result
        }
        let result = attributed("［")
        result.append(alt.string.isEmpty ? attributed("图片暂不可用") : alt)
        result.append(attributed("］"))
        result.addAttributes(
            [
                .font: PlatformFont.systemFont(ofSize: max(11, fontSize - 1)),
                .foregroundColor: PlatformColor.readerSecondaryLabel,
            ],
            range: result.fullRange
        )
        return result
    }

    mutating func visitTable(_ table: Table) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: "")
        result.append(renderTableRow(Array(table.head.cells), isHeader: true))
        for row in table.body.rows {
            result.append(renderTableRow(Array(row.cells), isHeader: false))
        }
        result.append(attributed("\n"))
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
                .font: PlatformFont.systemFont(ofSize: max(10, fontSize - 3)),
                .foregroundColor: PlatformColor.readerSeparator,
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
        renderChildren(of: tableCell)
    }

    private mutating func renderTableRow(
        _ cells: [Table.Cell],
        isHeader: Bool
    ) -> NSMutableAttributedString {
        let row = attributed("│ ")
        for (index, cell) in cells.enumerated() {
            var body = renderChildren(of: cell)
            trimTrailingNewlines(body)
            if isHeader { body = applyingFontTrait(.bold, to: body) }
            row.append(body)
            row.append(attributed(index == cells.count - 1 ? " │\n" : " │ "))
        }
        row.addAttributes(
            [
                .backgroundColor: PlatformColor.readerQuaternaryLabel,
                .paragraphStyle: paragraphStyle(
                    paragraphSpacing: isHeader ? 2 : 0,
                    firstLineHeadIndent: 8,
                    headIndent: 8,
                    tailIndent: -8
                ),
            ],
            range: row.fullRange
        )
        return row
    }

    private func imageAttachment(for source: String?) -> NSTextAttachment? {
        guard let source,
              let resourceRootURL,
              !source.hasPrefix("/"),
              !source.hasPrefix("~"),
              !source.contains("://") else { return nil }
        let path = source
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let decoded = String(path).removingPercentEncoding else { return nil }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        guard !components.isEmpty,
              !components.contains(".."),
              !components.contains(where: { $0.contains("\\") }) else { return nil }

        var request = URLComponents()
        request.scheme = "onereader-content"
        request.host = "local"
        request.path = "/" + components.joined(separator: "/")
        guard let requestURL = request.url,
              let resource = try? ReadOnlyContentResourceLoader(rootURL: resourceRootURL)
                .resolve(requestURL: requestURL),
              resource.mediaType.hasPrefix("image/") else { return nil }
#if os(macOS)
        guard let image = NSImage(contentsOf: resource.fileURL), image.size.width > 0 else {
            return nil
        }
        let scale = min(1, maximumImageWidth / image.size.width)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0,
            y: 0,
            width: image.size.width * scale,
            height: image.size.height * scale
        )
#else
        guard let image = UIImage(contentsOfFile: resource.fileURL.path), image.size.width > 0 else {
            return nil
        }
        let scale = min(1, maximumImageWidth / image.size.width)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0,
            y: 0,
            width: image.size.width * scale,
            height: image.size.height * scale
        )
#endif
        return attachment
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
                .font: readerSerifFont(ofSize: fontSize),
                .foregroundColor: PlatformColor.readerLabel,
            ]
        )
    }

    private mutating func mappedAttributed(
        _ string: String,
        sourceRange: SourceRange?,
        decodesMarkdownText: Bool,
        attributes: [NSAttributedString.Key: Any]? = nil
    ) -> NSMutableAttributedString {
        mappedAttributed(
            string,
            sourceUTF16Range: sourceIndex?.utf16Range(for: sourceRange),
            unavailableSourceUTF16Range: sourceIndex?.utf16Range(for: sourceRange),
            decodesMarkdownText: decodesMarkdownText,
            attributes: attributes
        )
    }

    private mutating func mappedAttributed(
        _ string: String,
        sourceUTF16Range: NSRange?,
        unavailableSourceUTF16Range: NSRange? = nil,
        decodesMarkdownText: Bool,
        attributes: [NSAttributedString.Key: Any]? = nil
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(
            string: string,
            attributes: attributes ?? [
                .font: readerSerifFont(ofSize: fontSize),
                .foregroundColor: PlatformColor.readerLabel,
            ]
        )
        guard !string.isEmpty else { return result }
        guard let sourceIndex,
              let sourceUTF16Range else {
            markSourceMappingUnavailable(
                result,
                sourceRange: unavailableSourceUTF16Range
            )
            return result
        }
        let runs = MarkdownLeafSourceMapper.runs(
            rendered: string,
            source: sourceIndex.source,
            sourceRange: sourceUTF16Range,
            decodesMarkdownText: decodesMarkdownText
        )
        guard MarkdownLeafSourceMapper.fullyCovers(
            renderedUTF16Length: (string as NSString).length,
            runs: runs
        ) else {
            markSourceMappingUnavailable(
                result,
                sourceRange: unavailableSourceUTF16Range ?? sourceUTF16Range
            )
            return result
        }
        for run in runs {
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

    private func markSourceMappingUnavailable(
        _ result: NSMutableAttributedString,
        sourceRange: NSRange?
    ) {
        guard result.length > 0 else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .oneReaderSourceMappingUnavailable: true,
        ]
        if let sourceRange {
            attributes[.oneReaderSourceUTF16Start] = sourceRange.location
            attributes[.oneReaderSourceUTF16End] = NSMaxRange(sourceRange)
        }
        result.addAttributes(attributes, range: result.fullRange)
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
        _ trait: PlatformFontTrait,
        to result: NSMutableAttributedString
    ) -> NSMutableAttributedString {
        let snapshot = NSAttributedString(attributedString: result)
        snapshot.enumerateAttribute(.font, in: snapshot.fullRange) { value, range, _ in
            let font = (value as? PlatformFont) ?? PlatformFont.systemFont(ofSize: fontSize)
#if os(macOS)
            let mask: NSFontTraitMask = trait == .bold ? .boldFontMask : .italicFontMask
            let converted = NSFontManager.shared.convert(font, toHaveTrait: mask)
#else
            var symbolicTraits = font.fontDescriptor.symbolicTraits
            symbolicTraits.insert(trait == .bold ? .traitBold : .traitItalic)
            let descriptor = font.fontDescriptor.withSymbolicTraits(symbolicTraits)
                ?? font.fontDescriptor
            let converted = PlatformFont(descriptor: descriptor, size: font.pointSize)
#endif
            result.addAttribute(.font, value: converted, range: range)
        }
        return result
    }

    private func readerSerifFont(
        ofSize size: CGFloat,
        weight: PlatformFont.Weight = .regular
    ) -> PlatformFont {
        let system = PlatformFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = system.fontDescriptor.withDesign(.serif) else {
            return system
        }
#if os(macOS)
        return PlatformFont(descriptor: descriptor, size: size) ?? system
#else
        return PlatformFont(descriptor: descriptor, size: size)
#endif
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

    func inlineCodeContentRange(
        for range: SourceRange?,
        rendered: String
    ) -> NSRange? {
        guard let fullRange = utf16Range(for: range) else { return nil }
        let value = source as NSString
        guard NSMaxRange(fullRange) <= value.length else { return nil }
        let raw = value.substring(with: fullRange) as NSString
        guard raw.length >= 2, raw.character(at: 0) == 0x60 else { return nil }

        var openingLength = 0
        while openingLength < raw.length, raw.character(at: openingLength) == 0x60 {
            openingLength += 1
        }
        var closingStart = raw.length
        while closingStart > openingLength, raw.character(at: closingStart - 1) == 0x60 {
            closingStart -= 1
        }
        guard raw.length - closingStart == openingLength,
              closingStart >= openingLength else { return nil }
        var contentStart = openingLength
        var contentEnd = closingStart
        let content = NSRange(
            location: contentStart,
            length: contentEnd - contentStart
        )
        guard raw.rangeOfCharacter(
            from: .newlines,
            options: [],
            range: content
        ).location == NSNotFound else { return nil }

        if contentEnd - contentStart >= 2,
           raw.character(at: contentStart) == 0x20,
           raw.character(at: contentEnd - 1) == 0x20 {
            let allSpaces = (contentStart..<contentEnd).allSatisfy {
                raw.character(at: $0) == 0x20
            }
            if !allSpaces {
                contentStart += 1
                contentEnd -= 1
            }
        }
        let normalizedRange = NSRange(
            location: contentStart,
            length: contentEnd - contentStart
        )
        guard raw.substring(with: normalizedRange) == rendered else { return nil }
        return NSRange(
            location: fullRange.location + normalizedRange.location,
            length: normalizedRange.length
        )
    }

    func codeBlockContentRange(for range: SourceRange?) -> NSRange? {
        guard let fullRange = utf16Range(for: range) else { return nil }
        let value = source as NSString
        guard NSMaxRange(fullRange) <= value.length else { return nil }
        guard fullRange.location == 0
                || value.character(at: fullRange.location - 1) == 0x0A
                || value.character(at: fullRange.location - 1) == 0x0D else {
            // swift-markdown may exclude opening-fence indentation from its range.
            return nil
        }
        let raw = value.substring(with: fullRange) as NSString
        let lines = Self.lineRanges(in: raw)
        guard let openingLine = lines.first else { return fullRange }
        let openingContent = Self.contentRange(of: openingLine, in: raw)
        var cursor = openingContent.location
        var leadingSpaces = 0
        while cursor < NSMaxRange(openingContent),
              raw.character(at: cursor) == 0x20,
              leadingSpaces < 4 {
            leadingSpaces += 1
            cursor += 1
        }
        guard leadingSpaces == 0,
              cursor < NSMaxRange(openingContent),
              raw.character(at: cursor) == 0x60 || raw.character(at: cursor) == 0x7E else {
            // Indented blocks and indented fences normalize structural spaces.
            return nil
        }
        let fenceCharacter = raw.character(at: cursor)
        var openingFenceLength = 0
        while cursor + openingFenceLength < NSMaxRange(openingContent),
              raw.character(at: cursor + openingFenceLength) == fenceCharacter {
            openingFenceLength += 1
        }
        guard openingFenceLength >= 3 else { return nil }

        let contentStart = NSMaxRange(openingLine)
        var contentEnd = raw.length
        for line in lines.dropFirst().reversed() {
            let lineContent = Self.contentRange(of: line, in: raw)
            var closingCursor = lineContent.location
            var closingLeadingSpaces = 0
            while closingCursor < NSMaxRange(lineContent),
                  raw.character(at: closingCursor) == 0x20,
                  closingLeadingSpaces < 4 {
                closingLeadingSpaces += 1
                closingCursor += 1
            }
            guard closingLeadingSpaces <= 3 else { continue }
            var closingFenceLength = 0
            while closingCursor + closingFenceLength < NSMaxRange(lineContent),
                  raw.character(at: closingCursor + closingFenceLength) == fenceCharacter {
                closingFenceLength += 1
            }
            guard closingFenceLength >= openingFenceLength else { continue }
            let suffixStart = closingCursor + closingFenceLength
            let suffixRange = NSRange(
                location: suffixStart,
                length: NSMaxRange(lineContent) - suffixStart
            )
            guard Self.containsOnlyHorizontalWhitespace(suffixRange, in: raw) else { continue }
            contentEnd = line.location
            break
        }
        guard contentEnd >= contentStart else { return nil }
        return NSRange(
            location: fullRange.location + contentStart,
            length: contentEnd - contentStart
        )
    }

    private static func lineRanges(in value: NSString) -> [NSRange] {
        guard value.length > 0 else { return [] }
        var result: [NSRange] = []
        var start = 0
        while start < value.length {
            var end = start
            while end < value.length,
                  value.character(at: end) != 0x0A,
                  value.character(at: end) != 0x0D {
                end += 1
            }
            if end < value.length {
                if value.character(at: end) == 0x0D,
                   end + 1 < value.length,
                   value.character(at: end + 1) == 0x0A {
                    end += 2
                } else {
                    end += 1
                }
            }
            result.append(NSRange(location: start, length: end - start))
            start = end
        }
        return result
    }

    private static func contentRange(of line: NSRange, in value: NSString) -> NSRange {
        var end = NSMaxRange(line)
        if end > line.location, value.character(at: end - 1) == 0x0A {
            end -= 1
        }
        if end > line.location, value.character(at: end - 1) == 0x0D {
            end -= 1
        }
        return NSRange(location: line.location, length: end - line.location)
    }

    private static func containsOnlyHorizontalWhitespace(
        _ range: NSRange,
        in value: NSString
    ) -> Bool {
        guard range.length > 0 else { return true }
        for offset in range.location..<NSMaxRange(range) {
            let character = value.character(at: offset)
            if character != 0x20, character != 0x09 { return false }
        }
        return true
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

    static func fullyCovers(renderedUTF16Length: Int, runs: [Run]) -> Bool {
        guard renderedUTF16Length > 0, !runs.isEmpty else { return false }
        var coveredEnd = 0
        for run in runs {
            guard run.rendered.length > 0,
                  run.rendered.location == coveredEnd else { return false }
            coveredEnd = NSMaxRange(run.rendered)
        }
        return coveredEnd == renderedUTF16Length
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
        var intersectsUnavailableLeaf = false
        rendered.enumerateAttributes(
            in: rendered.fullRange
        ) { attributes, _, stop in
            guard attributes[.oneReaderSourceMappingUnavailable] as? Bool == true,
                  let sourceStart = attributes[.oneReaderSourceUTF16Start] as? Int,
                  let sourceEnd = attributes[.oneReaderSourceUTF16End] as? Int,
                  sourceStart < NSMaxRange(sourceRange),
                  sourceEnd > sourceRange.location else { return }
            intersectsUnavailableLeaf = true
            stop.pointee = true
        }
        guard !intersectsUnavailableLeaf else { return nil }
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
        var intersectsUnavailableLeaf = false
        rendered.enumerateAttribute(
            .oneReaderSourceMappingUnavailable,
            in: renderedRange
        ) { value, _, stop in
            guard value as? Bool == true else { return }
            intersectsUnavailableLeaf = true
            stop.pointee = true
        }
        guard !intersectsUnavailableLeaf else { return nil }
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
    static let oneReaderSourceMappingUnavailable = NSAttributedString.Key(
        "com.onereader.markdown.source-mapping-unavailable"
    )
}

private extension NSAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}
