import Foundation
import SwiftUI

struct MarkdownReaderView: View {
    let state: ReaderContentState
    let assetBaseURL: URL?
    var compact = false

    var body: some View {
        Group {
            switch state {
            case .idle:
                ContentUnavailableView(
                    "没有 Repo 原文",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("这个阅读单元只包含 PDF 证据。")
                )

            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("正在按 revision 读取原文…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case let .failed(message):
                ContentUnavailableView {
                    Label("原文暂时不可达", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                }

            case let .loaded(observation):
                MarkdownDocument(
                    markdown: observation.content,
                    assetBaseURL: assetBaseURL,
                    compact: compact
                )
            }
        }
        .background(ReaderTheme.paper)
    }
}

private struct MarkdownDocument: View {
    let markdown: String
    let assetBaseURL: URL?
    let compact: Bool

    private var blocks: [MarkdownBlock] {
        MarkdownBlockParser().parse(markdown)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: compact ? 12 : 16) {
                ForEach(blocks) { block in
                    MarkdownBlockView(block: block, assetBaseURL: assetBaseURL)
                }
            }
            .frame(maxWidth: compact ? 680 : 780, alignment: .leading)
            .padding(.horizontal, compact ? 18 : 42)
            .padding(.vertical, compact ? 24 : 36)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

private enum MarkdownBlock: Identifiable {
    case heading(id: Int, level: Int, text: String)
    case paragraph(id: Int, text: String)
    case bullet(id: Int, text: String)
    case quote(id: Int, text: String)
    case code(id: Int, language: String?, text: String)
    case image(id: Int, alt: String, path: String)
    case rule(id: Int)

    var id: Int {
        switch self {
        case let .heading(id, _, _),
             let .paragraph(id, _),
             let .bullet(id, _),
             let .quote(id, _),
             let .code(id, _, _),
             let .image(id, _, _),
             let .rule(id):
            id
        }
    }
}

private struct MarkdownBlockParser {
    func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var insideCode = false
        var nextID = 0

        func append(_ block: MarkdownBlock) {
            blocks.append(block)
            nextID += 1
        }

        func flushParagraph() {
            let value = paragraph
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                append(.paragraph(id: nextID, text: value))
            }
            paragraph.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if insideCode {
                    append(
                        .code(
                            id: nextID,
                            language: codeLanguage,
                            text: codeLines.joined(separator: "\n")
                        )
                    )
                    codeLines.removeAll(keepingCapacity: true)
                    codeLanguage = nil
                    insideCode = false
                } else {
                    flushParagraph()
                    let language = String(trimmed.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                    insideCode = true
                }
                continue
            }

            if insideCode {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                append(
                    .heading(
                        id: nextID,
                        level: heading.level,
                        text: heading.text
                    )
                )
            } else if let image = parseImage(trimmed) {
                flushParagraph()
                append(.image(id: nextID, alt: image.alt, path: image.path))
            } else if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                append(.rule(id: nextID))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                append(
                    .quote(
                        id: nextID,
                        text: String(trimmed.dropFirst())
                            .trimmingCharacters(in: .whitespaces)
                    )
                )
            } else if trimmed.range(
                of: #"^[-*+]\s+"#,
                options: .regularExpression
            ) != nil {
                flushParagraph()
                let text = trimmed.replacingOccurrences(
                    of: #"^[-*+]\s+"#,
                    with: "",
                    options: .regularExpression
                )
                append(.bullet(id: nextID, text: text))
            } else {
                paragraph.append(trimmed)
            }
        }

        if insideCode {
            append(
                .code(
                    id: nextID,
                    language: codeLanguage,
                    text: codeLines.joined(separator: "\n")
                )
            )
        }
        flushParagraph()
        return blocks
    }

    private func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let remainder = line.dropFirst(hashes.count)
        guard remainder.first == " " else { return nil }
        return (
            hashes.count,
            remainder.trimmingCharacters(in: .whitespaces)
        )
    }

    private func parseImage(_ line: String) -> (alt: String, path: String)? {
        let pattern = #"^!\[([^\]]*)\]\(([^)\s]+)(?:\s+["'][^"']*["'])?\)$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
            ),
            let altRange = Range(match.range(at: 1), in: line),
            let pathRange = Range(match.range(at: 2), in: line)
        else {
            return nil
        }
        return (String(line[altRange]), String(line[pathRange]))
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let assetBaseURL: URL?

    var body: some View {
        switch block {
        case let .heading(_, level, text):
            Text(inlineMarkdown(text))
                .font(headingFont(level))
                .foregroundStyle(level <= 2 ? .primary : ReaderTheme.deepTeal)
                .padding(.top, level <= 2 ? 12 : 5)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)

        case let .paragraph(_, text):
            Text(inlineMarkdown(text))
                .font(.system(size: 16.5, weight: .regular, design: .serif))
                .lineSpacing(6)
                .textSelection(.enabled)

        case let .bullet(_, text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(ReaderTheme.teal)
                    .frame(width: 5, height: 5)
                Text(inlineMarkdown(text))
                    .font(.system(size: 16, design: .serif))
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            .padding(.leading, 7)

        case let .quote(_, text):
            Text(inlineMarkdown(text))
                .font(.system(size: 16, weight: .regular, design: .serif))
                .italic()
                .lineSpacing(5)
                .padding(.leading, 14)
                .padding(.vertical, 8)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ReaderTheme.teal.opacity(0.7))
                        .frame(width: 3)
                }
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

        case let .code(_, language, text):
            VStack(alignment: .leading, spacing: 8) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(text)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.bottom, 2)
                }
            }
            .padding(14)
            .background(ReaderTheme.mutedFill, in: RoundedRectangle(cornerRadius: 10))

        case let .image(_, alt, path):
            if let url = resolvedURL(path) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 620)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    case .failure:
                        imagePlaceholder(alt: alt)
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 120)
                    @unknown default:
                        imagePlaceholder(alt: alt)
                    }
                }
                .accessibilityLabel(alt.isEmpty ? "原文图片" : alt)
            } else {
                imagePlaceholder(alt: alt)
            }

        case .rule:
            Divider()
                .padding(.vertical, 8)
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(size: 29, weight: .bold, design: .serif)
        case 2: .system(size: 23, weight: .semibold, design: .serif)
        case 3: .system(size: 19, weight: .semibold, design: .serif)
        default: .system(size: 17, weight: .semibold, design: .serif)
        }
    }

    private func resolvedURL(_ path: String) -> URL? {
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }
        return assetBaseURL?.appendingPathComponent(path)
    }

    private func imagePlaceholder(alt: String) -> some View {
        Label(
            alt.isEmpty ? "图片无法载入" : alt,
            systemImage: "photo"
        )
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(ReaderTheme.mutedFill, in: RoundedRectangle(cornerRadius: 10))
    }
}
