import Foundation

struct AnnotationTag: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let normalizedName: String
    let annotationCount: Int

    static func normalized(_ name: String) throws -> (name: String, key: String) {
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NotesError.invalidTag
        }
        let display = name.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !display.isEmpty, display.count <= 64,
              !display.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NotesError.invalidTag
        }
        return (display, display.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")))
    }
}

enum NotesError: LocalizedError, Equatable {
    case invalidTag
    case duplicateTag(String)
    case changedAnnotation
    case missingAnnotation
    case invalidRoute
    case differentLibrary
    case unavailableSource
    case exportTooLarge
    case invalidDestination

    var errorDescription: String? {
        switch self {
        case .invalidTag: "标签需为 1–64 个字符，不能包含控制字符。"
        case .duplicateTag(let name): "已有同名标签“\(name)”。合并会转移关系，需要明确确认。"
        case .changedAnnotation: "这条标注已在其他位置修改。请重新载入后再操作，未覆盖新内容。"
        case .missingAnnotation: "标注已移除；未修改其他内容。"
        case .invalidRoute: "这不是受支持的 OneReader 本地笔记回链。"
        case .differentLibrary: "回链属于另一份本地资料库；没有导入或联网。请在原设备资料库打开。"
        case .unavailableSource: "原来源或快照不可用。保留的摘录与笔记仍可查看，没有刷新或重新导入。"
        case .exportTooLarge: "导出范围超过 100,000 条或 128 MiB 文本，请按来源或空间缩小范围。"
        case .invalidDestination: "请选择可写的本地目录。导出不会覆盖已有文件。"
        }
    }
}

enum NotesSort: String, CaseIterable, Identifiable, Sendable {
    case newest, oldest
    var id: String { rawValue }
    var title: String { self == .newest ? "创建时间：最新在前" : "创建时间：最早在前" }
}

struct NotesQuery: Equatable, Sendable {
    var search = ""
    var spaceID: String?
    var sourceID: String?
    var kind: AnnotationKind?
    var tagIDs: Set<String> = []
    var createdAfter: Date?
    var createdBefore: Date?
    var sort: NotesSort = .newest
}

struct NotesCursor: Equatable, Sendable {
    let createdAt: Date
    let id: String
}

struct NotesEntry: Identifiable, Equatable, Sendable {
    var annotation: Annotation
    let sourceTitle: String
    let spaceTitle: String
    let sourceAvailable: Bool
    let isLatestSnapshot: Bool
    let originalWebURL: URL?
    var tags: [AnnotationTag]
    var id: String { annotation.id }

    var location: String {
        annotation.locator.adapterID == QuickLookAdapter.id
            ? "来源级位置（Quick Look 不提供页内定位）"
            : annotation.locator.conciseDescription
    }

    var statusLabel: String {
        guard sourceAvailable else { return "orphaned · 来源不可用" }
        if annotation.anchorState == .orphaned { return "orphaned · 定位待恢复" }
        if !isLatestSnapshot { return "历史快照 · \(annotation.anchorState.rawValue)" }
        return annotation.anchorState == .relocated ? "relocated · 已重定位" : "current · 当前快照"
    }

    var preview: String {
        annotation.selectedText?.nilIfNotesEmpty
            ?? annotation.note?.nilIfNotesEmpty
            ?? "\(annotation.kind.notesTitle) · \(sourceTitle) · \(location)"
    }
}

struct NotesPage: Sendable {
    let entries: [NotesEntry]
    let nextCursor: NotesCursor?
    let totalCount: Int
}

struct NotesExportOptions: Equatable, Sendable {
    var includeNotes = true
    var includeWebURLs = false
}

struct NotesExportSnapshot: Sendable {
    let libraryID: String
    let entries: [NotesEntry]
    let options: NotesExportOptions
    let capturedAt: Date
}

struct NotesLocalRoute: Equatable, Sendable {
    static let scheme = "onereader"
    let libraryID: String
    let annotationID: String
    let sourceID: String
    let snapshotID: String

    init(libraryID: String, annotation: Annotation) {
        self.libraryID = libraryID
        annotationID = annotation.id
        sourceID = annotation.sourceID
        snapshotID = annotation.snapshotID
    }

    init(url: URL) throws {
        guard url.absoluteString.utf8.count <= 2048,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == Self.scheme, parts.host == "notes", parts.path == "/v1",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, items.count == 4,
              Set(items.map(\.name)) == ["library", "annotation", "source", "snapshot"] else {
            throw NotesError.invalidRoute
        }
        var values: [String: String] = [:]
        for item in items {
            guard let value = item.value, Self.validID(value) else { throw NotesError.invalidRoute }
            values[item.name] = value
        }
        libraryID = values["library"]!
        annotationID = values["annotation"]!
        sourceID = values["source"]!
        snapshotID = values["snapshot"]!
    }

    var url: URL? {
        guard [libraryID, annotationID, sourceID, snapshotID].allSatisfy(Self.validID) else { return nil }
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "notes"
        parts.path = "/v1"
        parts.queryItems = [URLQueryItem(name: "library", value: libraryID),
                            URLQueryItem(name: "annotation", value: annotationID),
                            URLQueryItem(name: "source", value: sourceID),
                            URLQueryItem(name: "snapshot", value: snapshotID)]
        return parts.url
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

extension AnnotationKind {
    var notesTitle: String {
        switch self { case .bookmark: "书签"; case .highlight: "高亮"; case .note: "笔记" }
    }
    var notesSymbol: String {
        switch self { case .bookmark: "bookmark"; case .highlight: "highlighter"; case .note: "note.text" }
    }
}

private extension String {
    var nilIfNotesEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
