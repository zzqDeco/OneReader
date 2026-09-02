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

    static func index(of locator: Locator, in nodes: [ContentNode]) -> Int? {
        let candidates = nodes.enumerated().filter { _, node in
            let candidate = node.locator
            return candidate.sourceID == locator.sourceID
                && candidate.snapshotID == locator.snapshotID
                && candidate.adapterID == locator.adapterID
        }
        if let exact = candidates.first(where: { $0.element.locator == locator }) {
            return exact.offset
        }

        let samePath: ((Locator) -> Bool) = { candidate in
            guard let path = locator.relativePath else { return true }
            return candidate.relativePath == path
        }
        if let outlinePath = locator.payload["outlineDOMPath"],
           !outlinePath.isEmpty,
           let match = candidates.first(where: {
               samePath($0.element.locator)
                   && ($0.element.locator.payload["domPath"] == outlinePath
                       || $0.element.locator.structuralPath == outlinePath)
           }) {
            return match.offset
        }
        for key in ["pageIndex", "spineIndex", "href", "domPath"] {
            guard let value = locator.payload[key], !value.isEmpty else { continue }
            if let match = candidates.first(where: {
                samePath($0.element.locator)
                    && $0.element.locator.payload[key] == value
            }) {
                return match.offset
            }
        }
        if let path = locator.relativePath,
           let line = locator.lineRange?.lowerBound {
            let preceding = candidates.compactMap { candidate -> (Int, Int)? in
                guard candidate.element.locator.relativePath == path,
                      let start = candidate.element.locator.lineRange?.lowerBound,
                      start <= line else { return nil }
                return (candidate.offset, start)
            }.max(by: { $0.1 < $1.1 })
            if let preceding { return preceding.0 }
        }
        if let structuralPath = locator.structuralPath,
           let match = candidates.first(where: {
               $0.element.locator.structuralPath == structuralPath
           }) {
            return match.offset
        }
        if let fingerprint = locator.fingerprint,
           let match = candidates.first(where: {
               samePath($0.element.locator)
                   && $0.element.locator.fingerprint == fingerprint
           }) {
            return match.offset
        }
        if let quote = locator.textQuote?.exact,
           let match = candidates.first(where: {
               samePath($0.element.locator)
                   && $0.element.locator.textQuote?.exact == quote
           }) {
            return match.offset
        }
        if let path = locator.relativePath {
            let pathMatches = candidates.filter {
                $0.element.locator.relativePath == path
            }
            // A file path is a safe fallback only when it identifies one node.
            // Section outlines deliberately contain many nodes with the same path.
            if pathMatches.count == 1 { return pathMatches[0].offset }
        }
        return nil
    }

    static func availability(
        at locator: Locator?,
        in nodes: [ContentNode]
    ) -> (previous: Bool, next: Bool) {
        let readable = readableNodes(from: nodes)
        guard let locator,
              let index = index(of: locator, in: readable) else {
            return (false, false)
        }
        return (index > 0, index + 1 < readable.count)
    }
}

enum WebReadingPositionCapture {
    static let currentPositionJavaScript = """
        window.__oneReaderCapturePosition
          ? window.__oneReaderCapturePosition()
          : null;
        """

    static func normalizedScrollFraction(
        offset: Double,
        contentExtent: Double,
        viewportExtent: Double
    ) -> Double? {
        guard offset.isFinite,
              contentExtent.isFinite,
              viewportExtent.isFinite,
              contentExtent >= 0,
              viewportExtent >= 0 else { return nil }
        let maximum = max(0, contentExtent - viewportExtent)
        guard maximum > 0 else { return 1 }
        return min(max(offset / maximum, 0), 1)
    }

    static func update(
        for base: Locator,
        path: String?,
        outlinePath: String? = nil,
        quote: String?,
        fraction: Double?
    ) -> ReadingPositionUpdate {
        let normalizedPath = path?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let normalizedQuote = quote?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let normalizedOutlinePath = outlinePath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let normalizedFraction = fraction.flatMap { value in
            value.isFinite ? min(max(value, 0), 1) : nil
        }
        var payload = base.payload
        if let normalizedPath { payload["domPath"] = normalizedPath }
        if let normalizedOutlinePath {
            payload["outlineDOMPath"] = normalizedOutlinePath
        }
        if let normalizedFraction {
            payload["scrollFraction"] = String(format: "%.6f", normalizedFraction)
        }
        let evidenceQuote = normalizedQuote.map {
            TextQuote(prefix: nil, exact: $0, suffix: nil)
        } ?? base.textQuote
        let locator = Locator(
            sourceID: base.sourceID,
            snapshotID: base.snapshotID,
            adapterID: base.adapterID,
            schemaVersion: base.schemaVersion,
            payload: payload,
            structuralPath: normalizedPath ?? base.structuralPath,
            textQuote: evidenceQuote,
            fingerprint: normalizedQuote.map(AdapterUtilities.sha256) ?? base.fingerprint
        )
        let percentage = Int((normalizedFraction ?? 0) * 100)
        return ReadingPositionUpdate(
            locator: locator,
            progressFraction: normalizedFraction,
            granularity: .dom,
            displayLabel: ReadingPositionUpdate.label(
                for: locator,
                detail: "阅读到 \(percentage)%"
            )
        )
    }

    static func fractionOnlyUpdate(
        for base: Locator,
        fraction: Double?
    ) -> ReadingPositionUpdate {
        update(
            for: anchorWithoutDOMEvidence(base),
            path: nil,
            outlinePath: nil,
            quote: nil,
            fraction: fraction
        )
    }

    static func capturedUpdate(
        for base: Locator,
        path: String?,
        outlinePath: String? = nil,
        quote: String?,
        fraction: Double?
    ) -> ReadingPositionUpdate {
        update(
            for: anchorWithoutDOMEvidence(base),
            path: path,
            outlinePath: outlinePath,
            quote: quote,
            fraction: fraction
        )
    }

    private static func anchorWithoutDOMEvidence(_ base: Locator) -> Locator {
        var payload = base.payload
        payload.removeValue(forKey: "domPath")
        payload.removeValue(forKey: "outlineDOMPath")
        let structuralPath = base.structuralPath.flatMap { path in
            path.hasPrefix("body") ? base.relativePath : path
        }
        let anchor = Locator(
            sourceID: base.sourceID,
            snapshotID: base.snapshotID,
            adapterID: base.adapterID,
            schemaVersion: base.schemaVersion,
            payload: payload,
            structuralPath: structuralPath,
            textQuote: nil,
            fingerprint: nil
        )
        return anchor
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum ReadingPositionCaptureSignal {
    static let requested = Notification.Name(
        "io.github.zzqDeco.OneReader.captureReadingPosition"
    )
}

@MainActor
final class ReadingPositionCaptureRequest {
    private(set) var isClaimed = false
    private var completion: ((ReadingPositionUpdate?) -> Void)?

    init(completion: @escaping (ReadingPositionUpdate?) -> Void) {
        self.completion = completion
    }

    func claim() {
        isClaimed = true
    }

    func finish(with update: ReadingPositionUpdate?) {
        guard let completion else { return }
        self.completion = nil
        completion(update)
    }
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
