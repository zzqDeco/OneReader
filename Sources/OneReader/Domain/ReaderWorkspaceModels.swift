import Foundation

enum LibraryCollection: String, CaseIterable, Identifiable, Sendable {
    case allSpaces
    case recent
    case processing
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allSpaces: "所有空间"
        case .recent: "最近阅读"
        case .processing: "处理中"
        case .favorites: "收藏"
        }
    }

    var systemImage: String {
        switch self {
        case .allSpaces: "books.vertical"
        case .recent: "clock"
        case .processing: "waveform.path.ecg"
        case .favorites: "star"
        }
    }
}

enum WorkspaceNavigationTab: String, CaseIterable, Identifiable, Sendable {
    case outline
    case sources
    case route
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .outline: "目录"
        case .sources: "来源"
        case .route: "路线"
        case .search: "搜索"
        }
    }

    var systemImage: String {
        switch self {
        case .outline: "list.bullet.indent"
        case .sources: "square.stack.3d.up"
        case .route: "point.topleft.down.to.point.bottomright.curvepath"
        case .search: "magnifyingglass"
        }
    }
}

enum ReaderInspectorTab: String, CaseIterable, Identifiable, Sendable {
    case annotations
    case evidence
    case activity
    case ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .annotations: "笔记"
        case .evidence: "引用"
        case .activity: "运行"
        case .ask: "助手"
        }
    }

    var systemImage: String {
        switch self {
        case .annotations: "highlighter"
        case .evidence: "link"
        case .activity: "waveform.path"
        case .ask: "sparkles"
        }
    }
}

enum ImportDestination: String, CaseIterable, Identifiable, Sendable {
    case newSpace
    case currentSpace

    var id: String { rawValue }
}

enum ReaderPresentationState: Equatable, Sendable {
    case empty
    case loading
    case ready(PresentationDocument)
    case unavailable(String)
}

struct PendingImport: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case queued
        case copying
        case adapting
        case indexing
        case failed(String)

        var isActive: Bool {
            switch self {
            case .queued, .copying, .adapting, .indexing:
                true
            case .failed:
                false
            }
        }
    }

    let id: String
    let displayName: String
    let startedAt: Date
    var state: State

    init(displayName: String, state: State = .queued) {
        id = UUID().uuidString.lowercased()
        self.displayName = displayName
        startedAt = .now
        self.state = state
    }
}

enum ReaderImportRequest: Equatable, Sendable {
    case local(URL)
    case remote(URL)

    var displayName: String {
        switch self {
        case .local(let url): url.lastPathComponent
        case .remote(let url): url.host ?? url.absoluteString
        }
    }
}

struct LargeImportConfirmation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let request: ReaderImportRequest
    let destination: ImportDestination
    let byteCount: Int64
}

struct ReaderSelection: Equatable, Sendable {
    let text: String
    let locator: Locator
}

enum ReaderContentNavigation {
    private static let hiddenExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "ico", "jpeg", "jpg", "png", "svg", "webp",
        "woff", "woff2", "ttf", "otf",
    ]

    static func isVisible(_ node: ContentNode) -> Bool {
        let path = (node.locator.relativePath ?? node.locator.structuralPath ?? "")
            .lowercased()
        let pathExtension = (path as NSString).pathExtension
        if hiddenExtensions.contains(pathExtension) { return false }
        if node.mediaType?.lowercased().hasPrefix("image/") == true { return false }
        if node.mediaType?.lowercased().hasPrefix("font/") == true { return false }
        return true
    }

    static func outlineNodes(from nodes: [ContentNode]) -> [ContentNode] {
        nodes.filter(isVisible)
    }

    static func readableNodes(from nodes: [ContentNode]) -> [ContentNode] {
        outlineNodes(from: nodes).filter(\.isReadable)
    }
}

enum ReadingPositionCaptureSignal {
    static let requested = Notification.Name(
        "io.github.zzqDeco.OneReader.captureReadingPosition"
    )
}

struct ReaderActivityItem: Identifiable, Equatable, Sendable {
    enum State: String, Sendable {
        case pending
        case running
        case completed
        case attention
        case failed
    }

    let id: String
    let phase: String
    let message: String
    let state: State
    let date: Date
    let metadata: [String: String]

    init(
        id: String = UUID().uuidString.lowercased(),
        phase: String,
        message: String,
        state: State,
        date: Date = .now,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.phase = phase
        self.message = message
        self.state = state
        self.date = date
        self.metadata = metadata
    }
}

enum ReaderThemePreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case paper
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .paper: "纸张"
        case .dark: "深色"
        }
    }
}

struct ReaderPreferences: Codable, Equatable, Sendable {
    static let defaultsKey = "reader-preferences-v1"

    var fontSize: Double = 17
    var lineWidth: Double = 760
    var lineSpacing: Double = 7
    var theme: ReaderThemePreference = .system
    var pdfScale: Double = 1
}
