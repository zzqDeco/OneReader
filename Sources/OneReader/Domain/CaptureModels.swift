import Foundation

enum SpaceOrganizationState: String, Codable, CaseIterable, Identifiable, Sendable {
    case inbox, reading, read, archived
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inbox: "待整理"
        case .reading: "在读"
        case .read: "已读"
        case .archived: "归档"
        }
    }
    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .reading: "book"
        case .read: "checkmark.circle"
        case .archived: "archivebox"
        }
    }
}

enum CapturePhase: String, Codable, CaseIterable, Sendable {
    case received, waitingForImport, importing, preparing, ready, failed, cancelled
    var title: String {
        switch self {
        case .received: "已接收"
        case .waitingForImport: "等待导入"
        case .importing: "导入中"
        case .preparing: "正在准备阅读"
        case .ready: "可读"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }
    var isActive: Bool { self == .importing || self == .preparing }
    var canRetry: Bool { self == .failed || self == .cancelled }
}

/// The extension writes only this bounded, versioned receipt and its payload.
/// Absolute local paths, database locations and credentials never cross this seam.
struct CaptureReceipt: Codable, Equatable, Sendable, Identifiable {
    static let schemaVersion = 1
    enum Source: Codable, Equatable, Sendable {
        case remote(URL)
        case local(relativePath: String, isDirectory: Bool)
    }
    let version: Int
    let id: String
    let source: Source
    let displayName: String
    let targetSpaceID: String?
    let createdAt: Date
    let byteCount: Int64

    init(
        id: String = UUID().uuidString.lowercased(),
        source: Source,
        displayName: String,
        targetSpaceID: String? = nil,
        createdAt: Date = .now,
        byteCount: Int64 = 0
    ) {
        version = Self.schemaVersion
        self.id = id
        self.source = source
        self.displayName = String(displayName.prefix(512))
        self.targetSpaceID = targetSpaceID
        self.createdAt = createdAt
        self.byteCount = byteCount
    }

    func validate() throws {
        guard version == Self.schemaVersion, UUID(uuidString: id) != nil,
              id == id.lowercased(), !displayName.isEmpty, displayName.count <= 512,
              byteCount >= 0, (targetSpaceID?.count ?? 0) <= 128 else {
            throw CaptureError.invalidReceipt
        }
        switch source {
        case .remote(let url):
            try Self.validateRemoteURL(url)
        case .local(let relativePath, _):
            guard relativePath.hasPrefix("payload/"),
                  Self.isSafeRelativePath(relativePath) else {
                throw CaptureError.invalidReceipt
            }
        }
    }

    static func validateRemoteURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.absoluteString.utf8.count <= 16_384 else {
            throw CaptureError.invalidURL
        }
    }

    func describesSameContent(as other: CaptureReceipt) -> Bool {
        version == other.version && id == other.id && source == other.source
            && displayName == other.displayName && targetSpaceID == other.targetSpaceID
            && byteCount == other.byteCount
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

struct CaptureJob: Identifiable, Equatable, Sendable {
    let receipt: CaptureReceipt
    var id: String { receipt.id }
    var phase: CapturePhase
    var attemptCount: Int
    var attemptID: String?
    var errorMessage: String?
    var requiresLargeImportConfirmation: Bool
    var allowLargeImport: Bool
    var sourceID: String?
    var snapshotID: String?
    var spaceID: String?
    var updatedAt: Date

    var detail: String {
        if let errorMessage { return errorMessage }
        switch phase {
        case .received, .waitingForImport:
            if case .remote = receipt.source {
                return "链接已保存；打开 OneReader 并联网后处理。"
            }
            return "文件副本已保存，等待导入。"
        case .ready: return "已保存本地快照，可离线阅读；索引可能仍在处理中。"
        case .cancelled:
            return sourceID == nil ? "任务已取消，副本仍保留，可重试。" : "已停止处理，已导入的来源和阅读记录仍保留。"
        case .importing: return "正在保存托管副本，退出后可恢复。"
        case .preparing: return "托管副本已保存，正在选择阅读方式。"
        case .failed: return "未完成导入，请重试。"
        }
    }
}

struct CaptureImportContext: Equatable, Sendable {
    let jobID: String
    let attemptID: String
}

struct CaptureSpaceDestination: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
}

enum CaptureError: LocalizedError, Equatable {
    case sharedContainerUnavailable, invalidReceipt, conflictingReceipt, invalidURL
    case unsupportedFile, unsafeFile, attachmentTooLarge(Int64), tooManyFiles
    case insufficientCapacity, noLongerActive, missingPayload, importedSourceRemoved
    case largeImportRequiresConfirmation(Int64)

    var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable:
            "共享接收区不可用。请确认 OneReader 与分享扩展使用同一 App Group 签名后重试。"
        case .invalidReceipt: "接收记录不完整或版本不受支持，请从原 App 重新分享。"
        case .conflictingReceipt: "任务编号已存在且内容不同；未覆盖已接收的材料。"
        case .invalidURL: "仅接收不含用户名或密码的 HTTPS 链接。"
        case .unsupportedFile: "不支持此附件类型。支持 PDF、EPUB、图片、HTML、Markdown、文本和代码文件。"
        case .unsafeFile: "附件包含不安全路径或符号链接，请选择原始普通文件。"
        case .attachmentTooLarge(let bytes):
            "附件超过此入口的接收上限（\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))），请在 OneReader 中选择文件。"
        case .tooManyFiles: "附件数量过多，请分批接收。"
        case .insufficientCapacity: "设备可用空间不足；释放空间后重试，OneReader 至少保留 2 GiB。"
        case .noLongerActive: "任务已取消或由另一处理流程接管。"
        case .missingPayload: "已接收文件的副本不可用，请从原 App 重新分享。"
        case .importedSourceRemoved: "此任务的来源已被移除；不会自动重新创建。请重新收集材料。"
        case .largeImportRequiresConfirmation(let bytes):
            "材料约 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))，请确认大型导入后重试。"
        }
    }
}
