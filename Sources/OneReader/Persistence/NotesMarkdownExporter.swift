import Foundation

enum NotesMarkdownExporter {
    struct Progress: Sendable {
        let completed: Int
        let total: Int
    }

    /// Writes only a new child directory of the user-authorized destination.
    /// Staging and final rename are on the same volume, with no replace operation.
    static func write(
        _ snapshot: NotesExportSnapshot,
        to directory: URL,
        writeFile: @Sendable (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) },
        progress: @escaping @Sendable (Progress) async -> Void = { _ in }
    ) async throws -> URL {
        guard directory.isFileURL else { throw NotesError.invalidDestination }
        let manager = FileManager.default
        let resource = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard resource.isDirectory == true else { throw NotesError.invalidDestination }
        let staging = directory.appendingPathComponent(".onereader-export-\(UUID().uuidString.lowercased())", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? manager.removeItem(at: staging) } }
        let groups = grouped(snapshot.entries)
        var completed = 0
        for group in groups {
            try Task.checkCancellation()
            let file = fileName(title: group.title, sourceID: group.id)
            let body = try renderSource(group.entries, snapshot: snapshot, checkCancellation: { try Task.checkCancellation() })
            try writeFile(Data(body.utf8), staging.appendingPathComponent(file))
            completed += group.entries.count
            await progress(Progress(completed: completed, total: snapshot.entries.count))
        }
        try Task.checkCancellation()
        try writeFile(Data(renderIndex(snapshot).utf8), staging.appendingPathComponent("index.md"))
        let baseName = "OneReader Notes-\(day(snapshot.capturedAt))"
        for copy in 1...10_000 {
            try Task.checkCancellation()
            let suffix = copy == 1 ? "" : " (\(copy))"
            let destination = directory.appendingPathComponent(baseName + suffix, isDirectory: true)
            if manager.fileExists(atPath: destination.path) { continue }
            do {
                // moveItem never replaces a preexisting item. A racing writer is
                // handled by trying another copy name, not deleting its result.
                try manager.moveItem(at: staging, to: destination)
                committed = true
                return destination
            } catch {
                if manager.fileExists(atPath: destination.path) { continue }
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    static func renderIndex(_ snapshot: NotesExportSnapshot) -> String {
        var lines = ["# OneReader 笔记索引", "", "导出时间：\(timestamp(snapshot.capturedAt))", "", "标注数量：\(snapshot.entries.count)", "", "这是静态副本，不会双向同步。删除资料库标注不会删除本包；再次导出会创建新副本。", "", "本机回链仅适用于原设备的同一份 OneReader 资料库；其他设备仍可阅读摘录与位置。", "", "包含字段：类型、摘录、标签、创建/更新时间、来源、空间、快照、定位状态、位置、本机回链\(snapshot.options.includeNotes ? "、用户笔记" : "")\(snapshot.options.includeWebURLs ? "、去除查询参数与片段的原始网页地址" : "")", "", "## 来源", ""]
        for group in grouped(snapshot.entries) {
            let filename = fileName(title: group.title, sourceID: group.id)
            let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
            lines.append("- [\(escaped(group.title))](./\(encoded)) — \(group.entries.count) 条")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func renderSource(_ entries: [NotesEntry], snapshot: NotesExportSnapshot) -> String {
        renderSource(entries, snapshot: snapshot, checkCancellation: {})
    }

    private static func renderSource(_ entries: [NotesEntry], snapshot: NotesExportSnapshot, checkCancellation: () throws -> Void) rethrows -> String {
        guard let first = entries.first else { return "" }
        var lines = ["# \(escaped(first.sourceTitle))", "", "来源 ID：\(escaped(first.annotation.sourceID))", "", "[返回索引](./index.md)", ""]
        for entry in entries.sorted(by: entryOrder) {
            try checkCancellation()
            let annotation = entry.annotation
            lines += ["## \(annotation.kind.notesTitle) · \(escaped(entry.location))", "", "- 标注 ID：\(escaped(annotation.id))", "- 所属空间：\(escaped(entry.spaceTitle))（\(escaped(annotation.spaceID))）", "- 快照：\(escaped(annotation.snapshotID))", "- 定位状态：\(escaped(entry.statusLabel))", "- 创建：\(timestamp(annotation.createdAt))", "- 更新：\(timestamp(annotation.updatedAt))", "- 标签：\(entry.tags.map { escaped($0.name) }.joined(separator: "、"))", ""]
            if let url = NotesLocalRoute(libraryID: snapshot.libraryID, annotation: annotation).url {
                lines += ["[在本机 OneReader 查看原文](\(url.absoluteString))", ""]
            } else {
                lines += ["本机回链不可用；请按来源、快照和位置查找。", ""]
            }
            if snapshot.options.includeWebURLs, let url = entry.originalWebURL.flatMap(safeWebURL) {
                lines += ["原始网页：[打开网页](\(safeMarkdownURL(url)))", ""]
            }
            if let selected = annotation.selectedText, !selected.isEmpty {
                lines += ["### 摘录", "", quoted(selected), ""]
            } else {
                lines += ["无摘录；请通过上述来源与位置识别此书签。", ""]
            }
            if snapshot.options.includeNotes, let note = annotation.note, !note.isEmpty {
                lines += ["### 用户笔记", "", quoted(note), ""]
            }
            lines += ["---", ""]
        }
        return lines.joined(separator: "\n")
    }

    static func fileName(title: String, sourceID: String) -> String {
        var slug = ""
        for scalar in title.precomposedStringWithCanonicalMapping.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-") { slug += "-" }
            if slug.utf8.count > 120 { break }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if slug.isEmpty { slug = "untitled" }
        return "source-\(slug)-\(AdapterUtilities.sha256(sourceID).prefix(16)).md"
    }

    static func safeWebURL(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https" || parts.scheme == "http",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    /// Untrusted source text is never parsed as Markdown, HTML or image syntax.
    static func escaped(_ text: String) -> String {
        let clean = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
        let value = String(String.UnicodeScalarView(clean))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return value.map { character in
            "\\`*_{}[]()#+-.!|".contains(character) ? "\\\(character)" : String(character)
        }.joined()
    }

    private static func quoted(_ text: String) -> String {
        escaped(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
            .components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
    }

    private static func safeMarkdownURL(_ url: URL) -> String {
        url.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
    }

    private struct Group {
        let id: String
        let title: String
        let entries: [NotesEntry]
    }

    private static func grouped(_ entries: [NotesEntry]) -> [Group] {
        Dictionary(grouping: entries, by: { $0.annotation.sourceID }).map { id, values in
            Group(id: id, title: values.first?.sourceTitle.replacingOccurrences(of: "\n", with: " ") ?? "未命名来源", entries: values)
        }.sorted { $0.id < $1.id }
    }

    private static func entryOrder(_ lhs: NotesEntry, _ rhs: NotesEntry) -> Bool {
        if lhs.annotation.createdAt != rhs.annotation.createdAt { return lhs.annotation.createdAt < rhs.annotation.createdAt }
        return lhs.id < rhs.id
    }

    private static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func day(_ date: Date) -> String { String(timestamp(date).prefix(10)) }
}
