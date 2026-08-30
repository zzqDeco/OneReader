import CryptoKit
import Foundation

struct AdapterContext: Sendable {
    let source: Source
    let snapshot: SourceSnapshot
    let managedURL: URL
    let contentRootURL: URL
    let derivedRootURL: URL
    let declaredMediaType: String?

    init(
        source: Source,
        snapshot: SourceSnapshot,
        managedURL: URL,
        contentRootURL: URL? = nil,
        derivedRootURL: URL,
        declaredMediaType: String? = nil
    ) {
        self.source = source
        self.snapshot = snapshot
        self.managedURL = managedURL
        self.contentRootURL = contentRootURL ?? managedURL
        self.derivedRootURL = derivedRootURL
        self.declaredMediaType = declaredMediaType
    }

    var filenameExtension: String {
        let sourceExtension = (source.displayName as NSString).pathExtension.lowercased()
        if managedURL.lastPathComponent == "payload", !sourceExtension.isEmpty {
            return sourceExtension
        }
        let managedExtension = managedURL.pathExtension.lowercased()
        if !managedExtension.isEmpty { return managedExtension }
        return sourceExtension
    }

    func validate(_ locator: Locator, adapterID: String) throws {
        guard locator.sourceID == source.id else {
            throw AdapterError.locatorSourceMismatch(
                expected: source.id,
                actual: locator.sourceID
            )
        }
        guard locator.snapshotID == snapshot.id else {
            throw AdapterError.locatorSnapshotMismatch(
                expected: snapshot.id,
                actual: locator.snapshotID
            )
        }
        guard locator.adapterID == adapterID else {
            throw AdapterError.locatorAdapterMismatch(
                expected: adapterID,
                actual: locator.adapterID
            )
        }
        guard locator.schemaVersion == Locator.currentSchemaVersion else {
            throw AdapterError.unsupportedLocatorSchema(locator.schemaVersion)
        }
    }
}

struct AdapterProbeMatch: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let adapterID: String
    let confidence: Double
    let evidence: [ProbeEvidence]
    let reason: String
    let auxiliaryAdapterIDs: [String]

    init(
        adapterID: String,
        confidence: Double,
        evidence: [ProbeEvidence],
        reason: String,
        auxiliaryAdapterIDs: [String] = []
    ) {
        id = "\(adapterID):\(evidence.map(\.id).joined(separator: ","))"
        self.adapterID = adapterID
        self.confidence = min(max(confidence, 0), 1)
        self.evidence = evidence
        self.reason = reason
        self.auxiliaryAdapterIDs = auxiliaryAdapterIDs
    }
}

enum ContentNodeKind: String, Codable, Hashable, Sendable {
    case document
    case section
    case directory
    case file
    case page
    case spineItem
    case fallback
}

struct ContentNode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let kind: ContentNodeKind
    let locator: Locator
    let depth: Int
    let order: Int
    let mediaType: String?
    let isReadable: Bool
}

struct ContentSearchHit: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let sourceID: String
    let snapshotID: String
    let adapterID: String
    let locator: Locator
    let title: String
    let context: String
    let rank: Double
}

enum PresentationSurface: String, Codable, Hashable, Sendable {
    case pdfKit
    case nativeMarkdown
    case nativeText
    case nativeCode
    case sanitizedWeb
    case quickLook
}

struct PresentationDocument: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let surface: PresentationSurface
    let locator: Locator
    let title: String
    let mediaType: String
    let content: String?
    let contentURL: URL?
    let baseURL: URL?
    let limitations: [String]
}

enum LocatorResolutionState: String, Codable, Hashable, Sendable {
    case current
    case relocated
    case orphaned
}

struct LocatorResolution: Codable, Hashable, Sendable {
    let state: LocatorResolutionState
    let requested: Locator
    let resolved: Locator?
    let reason: String
}

protocol ContentAdapter: Sendable {
    var descriptor: AdapterDescriptor { get }
}

protocol ProbingAdapter: ContentAdapter {
    func probe(_ context: AdapterContext) async throws -> AdapterProbeMatch?
}

protocol RevisionAdapter: ContentAdapter {
    func verifyRevision(in context: AdapterContext) async throws
}

protocol ListingAdapter: ContentAdapter {
    func listContent(
        in context: AdapterContext,
        under locator: Locator?,
        limit: Int
    ) async throws -> [ContentNode]
}

protocol ReadingAdapter: ContentAdapter {
    func readFragment(
        in context: AdapterContext,
        at locator: Locator,
        maxCharacters: Int
    ) async throws -> Observation
}

protocol SearchingAdapter: ContentAdapter {
    func searchContent(
        in context: AdapterContext,
        query: String,
        limit: Int
    ) async throws -> [ContentSearchHit]
}

protocol RenderingAdapter: ContentAdapter {
    func presentation(
        in context: AdapterContext,
        at locator: Locator?
    ) async throws -> PresentationDocument
}

protocol ResolvingAdapter: ContentAdapter {
    func resolve(
        _ locator: Locator,
        in context: AdapterContext
    ) async throws -> LocatorResolution
}

enum AdapterError: LocalizedError, Equatable {
    case adapterNotRegistered(String)
    case capabilityUnavailable(adapterID: String, capability: AdapterCapability)
    case unsupportedContent(String)
    case invalidLocator(String)
    case locatorSourceMismatch(expected: String, actual: String)
    case locatorSnapshotMismatch(expected: String, actual: String)
    case locatorAdapterMismatch(expected: String, actual: String)
    case unsupportedLocatorSchema(Int)
    case unreadableText(String)
    case textSizeLimit(limit: Int, actual: Int64)
    case unsafeArchivePath(String)
    case archiveSymlink(String)
    case archiveExpansionLimit(limit: UInt64, actual: UInt64)
    case archiveChecksumMismatch(String)
    case archiveMissingContainer
    case archiveMissingPackage(String)
    case archiveMalformedPackage(String)
    case unsafeHTML(String)
    case redirectRejected(String)
    case resourceOutsideSource(String)

    var errorDescription: String? {
        switch self {
        case let .adapterNotRegistered(id):
            "适配器未注册：\(id)"
        case let .capabilityUnavailable(adapterID, capability):
            "适配器 \(adapterID) 不提供 \(capability.rawValue) 能力。"
        case let .unsupportedContent(detail):
            "无法用当前适配器读取：\(detail)"
        case let .invalidLocator(detail):
            "Locator 无效：\(detail)"
        case let .locatorSourceMismatch(expected, actual):
            "Locator Source 不匹配：期望 \(expected)，实际 \(actual)。"
        case let .locatorSnapshotMismatch(expected, actual):
            "Locator Snapshot 不匹配：期望 \(expected)，实际 \(actual)。"
        case let .locatorAdapterMismatch(expected, actual):
            "Locator Adapter 不匹配：期望 \(expected)，实际 \(actual)。"
        case let .unsupportedLocatorSchema(version):
            "不支持 Locator schema \(version)。"
        case let .unreadableText(path):
            "文本无法按 UTF-8 解码：\(path)"
        case let .textSizeLimit(limit, actual):
            "文本超过结构化读取上限：\(actual) / \(limit) 字节。"
        case let .unsafeArchivePath(path):
            "压缩包路径越界：\(path)"
        case let .archiveSymlink(path):
            "压缩包包含不允许的符号链接：\(path)"
        case let .archiveExpansionLimit(limit, actual):
            "压缩包展开量超过上限：\(actual) / \(limit) 字节。"
        case let .archiveChecksumMismatch(path):
            "压缩包条目校验失败：\(path)"
        case .archiveMissingContainer:
            "EPUB 缺少 META-INF/container.xml。"
        case let .archiveMissingPackage(path):
            "EPUB 缺少 OPF package：\(path)"
        case let .archiveMalformedPackage(detail):
            "EPUB package 无法解析：\(detail)"
        case let .unsafeHTML(detail):
            "HTML 净化失败：\(detail)"
        case let .redirectRejected(url):
            "重定向目标不在允许范围：\(url)"
        case let .resourceOutsideSource(path):
            "资源路径超出来源边界：\(path)"
        }
    }
}

enum AdapterUtilities {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    static func bounded(_ value: Int, maximum: Int) -> Int {
        max(0, min(value, maximum))
    }

    static func excerpt(
        from text: String,
        matching range: Range<String.Index>,
        radius: Int = 90
    ) -> String {
        let lower = text.index(
            range.lowerBound,
            offsetBy: -radius,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let upper = text.index(
            range.upperBound,
            offsetBy: radius,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        return String(text[lower..<upper])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func makeObservation(
        context: AdapterContext,
        adapterID: String,
        locator: Locator,
        mediaType: String,
        content: String,
        maxCharacters: Int,
        contentReference: String? = nil
    ) -> Observation {
        let safeLimit = max(0, maxCharacters)
        let truncated = content.count > safeLimit
        let boundedContent = truncated ? String(content.prefix(safeLimit)) : content
        let digest = sha256(content)
        return Observation(
            id: "\(locator.stableID):\(digest.prefix(12))",
            sourceID: context.source.id,
            snapshotID: context.snapshot.id,
            adapterID: adapterID,
            locator: locator,
            mediaType: mediaType,
            content: boundedContent,
            contentReference: contentReference,
            contentDigest: digest,
            truncated: truncated,
            observedAt: .now
        )
    }
}
