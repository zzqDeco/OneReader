import Foundation

struct LibraryStoragePolicy: Sendable {
    static let production = LibraryStoragePolicy(
        largeImportThreshold: ApplicationSupportLayout.largeImportThreshold,
        minimumFreeCapacity: ApplicationSupportLayout.minimumFreeCapacity,
        capacityProvider: { rootURL in
            try ApplicationSupportLayout.availableCapacity(at: rootURL)
        }
    )

    let largeImportThreshold: Int64
    let minimumFreeCapacity: Int64
    private let capacityProvider: @Sendable (URL) throws -> Int64

    init(
        largeImportThreshold: Int64,
        minimumFreeCapacity: Int64,
        capacityProvider: @escaping @Sendable (URL) throws -> Int64
    ) {
        self.largeImportThreshold = largeImportThreshold
        self.minimumFreeCapacity = minimumFreeCapacity
        self.capacityProvider = capacityProvider
    }

    func availableCapacity(at rootURL: URL) throws -> Int64 {
        try capacityProvider(rootURL)
    }
}

struct ApplicationSupportLayout: Sendable {
    static let minimumFreeCapacity: Int64 = 2 * 1_024 * 1_024 * 1_024
    static let largeImportThreshold: Int64 = 4 * 1_024 * 1_024 * 1_024

    let rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL.standardizedFileURL
            return
        }

        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.rootURL = base.appendingPathComponent("OneReader", isDirectory: true)
    }

    var databaseURL: URL {
        rootURL.appendingPathComponent("Library.sqlite", isDirectory: false)
    }

    var sourcesURL: URL {
        rootURL.appendingPathComponent("Sources", isDirectory: true)
    }

    var snapshotsURL: URL {
        rootURL.appendingPathComponent("Snapshots", isDirectory: true)
    }

    var derivedURL: URL {
        rootURL.appendingPathComponent("Derived", isDirectory: true)
    }

    var artifactsURL: URL {
        rootURL.appendingPathComponent("Artifacts", isDirectory: true)
    }

    var legacyURL: URL {
        rootURL.appendingPathComponent("Legacy", isDirectory: true)
    }

    var stagingURL: URL {
        rootURL.appendingPathComponent(".Staging", isDirectory: true)
    }

    var legacyProgressURL: URL {
        rootURL.appendingPathComponent("progress-v1.json", isDirectory: false)
    }

    func prepare(fileManager: FileManager = .default) throws {
        for directory in [
            rootURL,
            sourcesURL,
            snapshotsURL,
            derivedURL,
            artifactsURL,
            legacyURL,
            stagingURL,
        ] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }

    func availableCapacity() throws -> Int64 {
        try Self.availableCapacity(at: rootURL)
    }

    static func availableCapacity(at rootURL: URL) throws -> Int64 {
        let values = try rootURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let important = values.volumeAvailableCapacityForImportantUsage {
            return important
        }
        if let available = values.volumeAvailableCapacity {
            return Int64(available)
        }
        return 0
    }

    func relativePath(for url: URL) throws -> String {
        let rootPath = rootURL.standardizedFileURL.pathComponents
        let candidatePath = url.standardizedFileURL.pathComponents
        guard candidatePath.starts(with: rootPath) else {
            throw LibraryStorageError.pathEscapesLibrary(url.path)
        }
        return candidatePath.dropFirst(rootPath.count).joined(separator: "/")
    }

    func url(forRelativePath path: String) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw LibraryStorageError.pathEscapesLibrary(path)
        }
        let candidate = rootURL.appendingPathComponent(path).standardizedFileURL
        _ = try relativePath(for: candidate)
        return candidate
    }
}

enum LibraryStorageError: LocalizedError, Equatable {
    case unsupportedSource(String)
    case sourceUnavailable(String)
    case pathEscapesLibrary(String)
    case symbolicLinkNotAllowed(String)
    case referencedResourceOutsideSource(String)
    case largeImportRequiresConfirmation(Int64)
    case insufficientFreeSpace(required: Int64, available: Int64)
    case missingSpace(String)
    case missingSource(String)
    case trashDestinationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSource(path):
            "不支持导入该来源：\(path)"
        case let .sourceUnavailable(path):
            "来源不可读取：\(path)"
        case let .pathEscapesLibrary(path):
            "路径超出 OneReader 托管范围：\(path)"
        case let .symbolicLinkNotAllowed(path):
            "托管导入不跟随符号链接：\(path)"
        case let .referencedResourceOutsideSource(path):
            "正文引用的资源超出已授权目录：\(path)"
        case let .largeImportRequiresConfirmation(byteCount):
            "该来源约为 \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))，需要确认后才能导入。"
        case let .insufficientFreeSpace(required, available):
            "可用空间不足。需要保留 \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))，当前可用 \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))。"
        case let .missingSpace(id):
            "Reading Space 不存在：\(id)"
        case let .missingSource(id):
            "Source 不存在：\(id)"
        case let .trashDestinationUnavailable(path):
            "无法确认废纸篓中的托管副本位置：\(path)"
        }
    }
}
