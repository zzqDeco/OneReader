import AppKit
import Markdown

/// Converts untrusted Markdown into a native, selectable attributed document.
/// Raw HTML and image payloads are never executed or fetched here.
struct NativeMarkdownRenderer: MarkupVisitor {
    typealias Result = NSMutableAttributedString

    let fontSize: CGFloat
    let lineSpacing: CGFloat

    mutating func render(_ source: String) -> NSAttributedString {
        let document = Document(parsing: source)
        let result = visit(document)
        trimTrailingNewlines(result)
        return result
    }

    mutating func defaultVisit(_ markup: any Markup) -> NSMutableAttributedString {
        renderChildren(of: markup)
    }

    mutating func visitDocument(_ document: Document) -> NSMutableAttributedString {
        renderChildren(of: document)
    }

    mutating func visitText(_ text: Markdown.Text) -> NSMutableAttributedString {
        attributed(text.string)
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
        NSMutableAttributedString(
            string: inlineCode.code,
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
        let result = NSMutableAttributedString(
            string: codeBlock.code.trimmingCharacters(in: .newlines) + "\n",
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
        let label = alt.string.isEmpty ? "图片" : alt.string
        return NSMutableAttributedString(
            string: "［\(label)］",
            attributes: [
                .font: NSFont.systemFont(ofSize: max(11, fontSize - 1)),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
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

private extension NSAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}
