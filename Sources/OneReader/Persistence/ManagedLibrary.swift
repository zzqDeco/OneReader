import CryptoKit
import Foundation

struct ManagedImportResult: Sendable {
    let space: ReadingSpace
    let source: Source
    let snapshot: SourceSnapshot
    let managedURL: URL
    let reusedContent: Bool
}

actor ManagedLibrary {
    typealias TrashHandler = @Sendable (URL) throws -> URL

    let database: LibraryDatabase
    private let fileManager: FileManager
    private let storagePolicy: LibraryStoragePolicy
    private let trashHandler: TrashHandler

    init(
        database: LibraryDatabase,
        fileManager: FileManager = .default,
        storagePolicy: LibraryStoragePolicy = .production,
        trashHandler: @escaping TrashHandler = ManagedLibrary.moveToTrash
    ) throws {
        self.database = database
        self.fileManager = fileManager
        self.storagePolicy = storagePolicy
        self.trashHandler = trashHandler
        try Self.removeAbandonedStaging(
            at: database.layout.stagingURL,
            fileManager: fileManager
        )
    }

    func importLocalSource(
        at sourceURL: URL,
        intoSpaceID spaceID: String? = nil,
        allowLargeImport: Bool = false
    ) async throws -> ManagedImportResult {
        guard sourceURL.isFileURL else {
            throw LibraryStorageError.unsupportedSource(sourceURL.absoluteString)
        }

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let inspection = try await Task.detached(priority: .userInitiated) {
            try LocalSourceInspector.inspect(sourceURL)
        }.value

        if inspection.byteCount > storagePolicy.largeImportThreshold,
           !allowLargeImport {
            throw LibraryStorageError.largeImportRequiresConfirmation(inspection.byteCount)
        }

        let recordedRelativePath = try database.existingManagedPath(
            forDigest: inspection.digest
        )
        let existingRelativePath = try reusableManagedPath(
            recordedRelativePath,
            for: inspection
        )
        let additionalBytes = existingRelativePath == nil ? inspection.byteCount : 0
        let capacity = try storagePolicy.availableCapacity(at: database.layout.rootURL)
        let projectedCapacity = capacity - additionalBytes
        guard projectedCapacity >= storagePolicy.minimumFreeCapacity else {
            throw LibraryStorageError.insufficientFreeSpace(
                required: storagePolicy.minimumFreeCapacity,
                available: max(0, projectedCapacity)
            )
        }

        let stored = try stageAndCommitContent(
            sourceURL: sourceURL,
            inspection: inspection,
            existingRelativePath: existingRelativePath
        )

        let now = Date.now
        let sourceID = UUID().uuidString.lowercased()
        let snapshotID = UUID().uuidString.lowercased()
        let source = Source(
            id: sourceID,
            displayName: inspection.displayName,
            originKind: inspection.isDirectory ? .localDirectory : .localFile,
            originURL: sourceURL.standardizedFileURL,
            managedState: .ready,
            latestSnapshotID: snapshotID,
            createdAt: now,
            updatedAt: now
        )
        let snapshot = SourceSnapshot(
            id: snapshotID,
            sourceID: sourceID,
            revision: inspection.digest,
            revisionKind: inspection.isDirectory ? .directoryTreeDigest : .contentDigest,
            digest: inspection.digest,
            observedAt: now,
            origin: sourceURL.standardizedFileURL,
            managedRelativePath: try database.layout.relativePath(for: stored.url),
            byteCount: inspection.byteCount
        )

        let space: ReadingSpace
        let createsSpace: Bool
        if let spaceID {
            guard let existing = try database.fetchSpaces().first(where: { $0.id == spaceID }) else {
                if stored.createdContainer {
                    try? fileManager.removeItem(at: stored.containerURL)
                }
                throw LibraryStorageError.missingSpace(spaceID)
            }
            space = existing
            createsSpace = false
        } else {
            let title = sourceURL.deletingPathExtension().lastPathComponent
            space = ReadingSpace(title: title.isEmpty ? inspection.displayName : title)
            createsSpace = true
        }

        do {
            try database.commitImport(
                source: source,
                snapshot: snapshot,
                space: space,
                createsSpace: createsSpace
            )
        } catch {
            if stored.createdContainer {
                try? fileManager.removeItem(at: stored.containerURL)
            }
            throw error
        }

        let remainingCapacity = try storagePolicy.availableCapacity(at: database.layout.rootURL)
        guard remainingCapacity >= storagePolicy.minimumFreeCapacity else {
            try rollbackImport(
                sourceID: source.id,
                spaceID: space.id,
                removesSpace: createsSpace,
                stored: stored
            )
            throw LibraryStorageError.insufficientFreeSpace(
                required: storagePolicy.minimumFreeCapacity,
                available: remainingCapacity
            )
        }

        return ManagedImportResult(
            space: space,
            source: source,
            snapshot: snapshot,
            managedURL: stored.url,
            reusedContent: stored.reusedContent
        )
    }

    func removeSource(id sourceID: String) throws {
        let plan = try database.removalPlan(sourceID: sourceID)
        var movedItems: [(original: URL, trashed: URL)] = []

        do {
            for relativePath in plan.exclusiveManagedRelativePaths {
                let managedURL = try database.layout.url(forRelativePath: relativePath)
                let containerURL = managedURL.deletingLastPathComponent()
                guard fileManager.fileExists(atPath: containerURL.path) else {
                    continue
                }
                let trashedURL = try trashHandler(containerURL)
                movedItems.append((containerURL, trashedURL))
            }
            try database.commitRemoval(sourceID: sourceID)
        } catch {
            for item in movedItems.reversed() {
                try? fileManager.createDirectory(
                    at: item.original.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try? fileManager.moveItem(at: item.trashed, to: item.original)
            }
            throw error
        }
    }

    private func stageAndCommitContent(
        sourceURL: URL,
        inspection: LocalSourceInspection,
        existingRelativePath: String?
    ) throws -> StoredContent {
        if let existingRelativePath {
            let existingURL = try database.layout.url(forRelativePath: existingRelativePath)
            guard fileManager.fileExists(atPath: existingURL.path) else {
                throw LibraryStorageError.sourceUnavailable(existingURL.path)
            }
            try verifyManagedContent(existingURL, matches: inspection)
            return StoredContent(
                url: existingURL,
                containerURL: existingURL.deletingLastPathComponent(),
                createdContainer: false,
                reusedContent: true
            )
        }

        let digestPrefix = String(inspection.digest.prefix(2))
        let parentURL = database.layout.sourcesURL
            .appendingPathComponent(digestPrefix, isDirectory: true)
        let containerURL = parentURL
            .appendingPathComponent(inspection.digest, isDirectory: true)
        let managedURL = containerURL.appendingPathComponent(
            "payload",
            isDirectory: inspection.isDirectory
        )

        if fileManager.fileExists(atPath: managedURL.path) {
            do {
                try verifyManagedContent(managedURL, matches: inspection)
                return StoredContent(
                    url: managedURL,
                    containerURL: containerURL,
                    createdContainer: false,
                    reusedContent: true
                )
            } catch {
                // A fresh, verified staging copy below repairs a missing or
                // corrupted managed payload without changing Source identity.
            }
        }

        let stagingContainer = database.layout.stagingURL
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let stagedPayload = stagingContainer.appendingPathComponent(
            "payload",
            isDirectory: inspection.isDirectory
        )
        try fileManager.createDirectory(
            at: stagingContainer,
            withIntermediateDirectories: true,
            attributes: nil
        )

        do {
            try fileManager.copyItem(at: sourceURL, to: stagedPayload)
            let copiedInspection = try LocalSourceInspector.inspect(stagedPayload)
            guard copiedInspection.digest == inspection.digest else {
                throw LibraryStorageError.sourceUnavailable(
                    "来源在托管复制期间发生变化：\(sourceURL.lastPathComponent)"
                )
            }

            try fileManager.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            if fileManager.fileExists(atPath: containerURL.path) {
                do {
                    try verifyManagedContent(managedURL, matches: inspection)
                    try fileManager.removeItem(at: stagingContainer)
                    return StoredContent(
                        url: managedURL,
                        containerURL: containerURL,
                        createdContainer: false,
                        reusedContent: true
                    )
                } catch {
                    guard fileManager.fileExists(atPath: managedURL.path) else {
                        try fileManager.moveItem(at: stagedPayload, to: managedURL)
                        try? fileManager.removeItem(at: stagingContainer)
                        return StoredContent(
                            url: managedURL,
                            containerURL: containerURL,
                            createdContainer: false,
                            reusedContent: false
                        )
                    }
                    _ = try fileManager.replaceItemAt(
                        managedURL,
                        withItemAt: stagedPayload,
                        backupItemName: nil,
                        options: []
                    )
                    try? fileManager.removeItem(at: stagingContainer)
                    try verifyManagedContent(managedURL, matches: inspection)
                    return StoredContent(
                        url: managedURL,
                        containerURL: containerURL,
                        createdContainer: false,
                        reusedContent: false
                    )
                }
            }
            try fileManager.moveItem(at: stagingContainer, to: containerURL)
            return StoredContent(
                url: managedURL,
                containerURL: containerURL,
                createdContainer: true,
                reusedContent: false
            )
        } catch {
            try? fileManager.removeItem(at: stagingContainer)
            throw error
        }
    }

    private func reusableManagedPath(
        _ relativePath: String?,
        for inspection: LocalSourceInspection
    ) throws -> String? {
        guard let relativePath else { return nil }
        let managedURL = try database.layout.url(forRelativePath: relativePath)
        guard fileManager.fileExists(atPath: managedURL.path) else {
            return nil
        }
        do {
            try verifyManagedContent(managedURL, matches: inspection)
            return relativePath
        } catch let error as LibraryStorageError {
            if case .pathEscapesLibrary = error {
                throw error
            }
            return nil
        } catch {
            return nil
        }
    }

    private func verifyManagedContent(
        _ managedURL: URL,
        matches inspection: LocalSourceInspection
    ) throws {
        let managedInspection = try LocalSourceInspector.inspect(
            managedURL,
            fileManager: fileManager
        )
        guard managedInspection.digest == inspection.digest,
              managedInspection.isDirectory == inspection.isDirectory else {
            throw LibraryStorageError.sourceUnavailable(
                "托管内容校验失败：\(managedURL.lastPathComponent)"
            )
        }
    }

    private func rollbackImport(
        sourceID: String,
        spaceID: String,
        removesSpace: Bool,
        stored: StoredContent
    ) throws {
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM sources WHERE id = ?", arguments: [sourceID])
            if removesSpace {
                try db.execute(sql: "DELETE FROM reading_spaces WHERE id = ?", arguments: [spaceID])
            }
        }
        if stored.createdContainer {
            try? fileManager.removeItem(at: stored.containerURL)
        }
    }

    private static func removeAbandonedStaging(
        at stagingURL: URL,
        fileManager: FileManager
    ) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        for entry in entries {
            try fileManager.removeItem(at: entry)
        }
    }

    private nonisolated static func moveToTrash(_ url: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL else {
            throw LibraryStorageError.trashDestinationUnavailable(url.path)
        }
        return resultingURL as URL
    }
}

private struct StoredContent {
    let url: URL
    let containerURL: URL
    let createdContainer: Bool
    let reusedContent: Bool
}

private struct LocalSourceInspection: Sendable {
    let displayName: String
    let isDirectory: Bool
    let digest: String
    let byteCount: Int64
}

private enum LocalSourceInspector {
    static func inspect(_ url: URL, fileManager: FileManager = .default) throws -> LocalSourceInspection {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        let values = try url.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true {
            throw LibraryStorageError.symbolicLinkNotAllowed(url.path)
        }
        guard values.isRegularFile == true || values.isDirectory == true else {
            throw LibraryStorageError.unsupportedSource(url.path)
        }

        let result: (digest: String, byteCount: Int64)
        if values.isDirectory == true {
            result = try inspectDirectory(url, fileManager: fileManager)
        } else {
            result = try digestFile(url)
        }
        return LocalSourceInspection(
            displayName: url.lastPathComponent,
            isDirectory: values.isDirectory == true,
            digest: result.digest,
            byteCount: result.byteCount
        )
    }

    private static func inspectDirectory(
        _ rootURL: URL,
        fileManager: FileManager
    ) throws -> (digest: String, byteCount: Int64) {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw LibraryStorageError.sourceUnavailable(rootURL.path)
        }

        let entries = enumerator.compactMap { $0 as? URL }.sorted {
            relativePath(of: $0, root: rootURL) < relativePath(of: $1, root: rootURL)
        }
        if let enumerationError {
            throw enumerationError
        }
        var hasher = SHA256()
        var totalBytes: Int64 = 0
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            let path = relativePath(of: entry, root: rootURL)
            if values.isSymbolicLink == true {
                throw LibraryStorageError.symbolicLinkNotAllowed(path)
            }
            update(&hasher, string: path)
            if values.isDirectory == true {
                update(&hasher, string: "directory")
            } else if values.isRegularFile == true {
                update(&hasher, string: "file")
                let file = try digestFile(entry)
                update(&hasher, string: file.digest)
                totalBytes += file.byteCount
            } else {
                throw LibraryStorageError.unsupportedSource(path)
            }
        }
        return (hex(hasher.finalize()), totalBytes)
    }

    private static func digestFile(_ url: URL) throws -> (digest: String, byteCount: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
            byteCount += Int64(data.count)
        }
        return (hex(hasher.finalize()), byteCount)
    }

    private static func relativePath(of url: URL, root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        return url.standardizedFileURL.pathComponents
            .dropFirst(rootComponents.count)
            .joined(separator: "/")
    }

    private static func update(_ hasher: inout SHA256, string: String) {
        let data = Data(string.utf8)
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
