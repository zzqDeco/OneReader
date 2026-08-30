import Foundation
import ZIPFoundation

struct ArchiveExtractionPolicy: Sendable {
    static let epub = ArchiveExtractionPolicy(
        maximumExpandedBytes: 4 * 1_024 * 1_024 * 1_024,
        expansionRatio: 10
    )

    static let github = ArchiveExtractionPolicy(
        maximumExpandedBytes: 4 * 1_024 * 1_024 * 1_024,
        expansionRatio: 100
    )

    let maximumExpandedBytes: UInt64
    let expansionRatio: UInt64
}

enum SecureArchiveExtractor {
    static func extract(
        archiveURL: URL,
        to rootURL: URL,
        policy: ArchiveExtractionPolicy,
        fileManager: FileManager = .default
    ) throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let compressedBytes = UInt64(max(
            (try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
            1
        ))
        let multiplied = compressedBytes.multipliedReportingOverflow(
            by: policy.expansionRatio
        )
        let ratioLimit = multiplied.overflow ? UInt64.max : multiplied.partialValue
        let limit = min(policy.maximumExpandedBytes, ratioLimit)

        var declaredTotal: UInt64 = 0
        var normalizedPaths = Set<String>()
        for entry in archive {
            try Task.checkCancellation()
            let safePath = try validatedPath(entry.path)
            let collisionKey = safePath.precomposedStringWithCanonicalMapping.lowercased()
            guard normalizedPaths.insert(collisionKey).inserted else {
                throw AdapterError.unsafeArchivePath("重复或大小写冲突路径：\(safePath)")
            }
            guard entry.type != .symlink else {
                throw AdapterError.archiveSymlink(safePath)
            }
            let added = declaredTotal.addingReportingOverflow(entry.uncompressedSize)
            declaredTotal = added.overflow ? .max : added.partialValue
            if added.overflow || declaredTotal > limit {
                throw AdapterError.archiveExpansionLimit(
                    limit: limit,
                    actual: declaredTotal
                )
            }
        }

        let root = rootURL.standardizedFileURL
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var actualTotal: UInt64 = 0
        for entry in archive {
            try Task.checkCancellation()
            let safePath = try validatedPath(entry.path)
            let destination = root.appendingPathComponent(safePath).standardizedFileURL
            guard destination.pathComponents.starts(with: root.pathComponents) else {
                throw AdapterError.unsafeArchivePath(entry.path)
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            switch entry.type {
            case .directory:
                try fileManager.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
            case .file:
                try extractFile(
                    entry,
                    from: archive,
                    to: destination,
                    root: root,
                    expandedTotal: &actualTotal,
                    limit: limit,
                    fileManager: fileManager
                )
            case .symlink:
                // Rejected during the complete preflight pass above.
                throw AdapterError.archiveSymlink(safePath)
            }
        }
        try Task.checkCancellation()
    }

    private static func extractFile(
        _ entry: Entry,
        from archive: Archive,
        to destination: URL,
        root: URL,
        expandedTotal: inout UInt64,
        limit: UInt64,
        fileManager: FileManager
    ) throws {
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw AdapterError.unsafeArchivePath("目标已存在：\(entry.path)")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".onereader-extract-\(UUID().uuidString.lowercased())"
        )
        guard temporary.standardizedFileURL.pathComponents.starts(with: root.pathComponents),
              fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw AdapterError.unsafeArchivePath(entry.path)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            let checksum = try archive.extract(entry, skipCRC32: false) { chunk in
                try Task.checkCancellation()
                let added = expandedTotal.addingReportingOverflow(UInt64(chunk.count))
                let actual = added.overflow ? UInt64.max : added.partialValue
                guard !added.overflow, actual <= limit else {
                    throw AdapterError.archiveExpansionLimit(limit: limit, actual: actual)
                }
                expandedTotal = actual
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
            guard checksum == entry.checksum else {
                throw AdapterError.archiveChecksumMismatch(entry.path)
            }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    static func validatedPath(_ rawPath: String) throws -> String {
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        guard !decoded.isEmpty,
              !decoded.hasPrefix("/"),
              !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw AdapterError.unsafeArchivePath(rawPath)
        }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw AdapterError.unsafeArchivePath(rawPath)
        }
        return components.joined(separator: "/")
    }
}
