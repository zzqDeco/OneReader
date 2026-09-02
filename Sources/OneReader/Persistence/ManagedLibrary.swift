import CryptoKit
import Foundation
import SwiftSoup

struct ManagedImportResult: Sendable {
    let space: ReadingSpace
    let source: Source
    let snapshot: SourceSnapshot
    let managedURL: URL
    let reusedContent: Bool
    let authorizationWarning: String?
}

struct ManagedRefreshCandidate: Sendable {
    let source: Source
    let previousSnapshotID: String
    let snapshot: SourceSnapshot
    let managedURL: URL
    let reusedContent: Bool
    let changed: Bool
    fileprivate let createdContainerURL: URL?
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
        try Self.removeAbandonedEPUBStaging(
            at: database.layout.derivedURL.appendingPathComponent("epub", isDirectory: true),
            fileManager: fileManager
        )
        try Self.removeOrphanedEPUBDerived(
            at: database.layout.derivedURL.appendingPathComponent("epub", isDirectory: true),
            activeSnapshotIDs: database.activeSnapshotIDs(),
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

        let accessBookmark: Data?
        let authorizationWarning: String?
        do {
            accessBookmark = try sourceURL.bookmarkData(
                options: Self.bookmarkCreationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            authorizationWarning = nil
        } catch {
            accessBookmark = nil
            authorizationWarning = "未能保存持久读取授权；刷新此本地来源时可能需要重新选择原文件。"
        }
        let inspection = try await Task.detached(priority: .userInitiated) {
            try LocalSourceInspector.inspect(sourceURL)
        }.value

        return try importInspectedSource(
            at: sourceURL,
            inspection: inspection,
            displayName: inspection.displayName,
            originKind: inspection.isDirectory ? .localDirectory : .localFile,
            originURL: sourceURL.standardizedFileURL,
            revisionKind: inspection.isDirectory ? .directoryTreeDigest : .contentDigest,
            revision: inspection.primaryRevision,
            intoSpaceID: spaceID,
            allowLargeImport: allowLargeImport,
            accessBookmark: accessBookmark,
            authorizationWarning: authorizationWarning
        )
    }

    func importFetchedSource(
        at stagedSourceURL: URL,
        displayName: String,
        originKind: SourceOriginKind,
        originURL: URL,
        revisionKind: SourceRevisionKind,
        revision: String? = nil,
        intoSpaceID spaceID: String? = nil,
        allowLargeImport: Bool = false
    ) async throws -> ManagedImportResult {
        guard stagedSourceURL.isFileURL,
              originKind == .remoteURL || originKind == .githubRepository else {
            throw LibraryStorageError.unsupportedSource(originURL.absoluteString)
        }
        let inspection = try await Task.detached(priority: .userInitiated) {
            try LocalSourceInspector.inspect(stagedSourceURL)
        }.value
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return try importInspectedSource(
            at: stagedSourceURL,
            inspection: inspection,
            displayName: normalizedName.isEmpty ? inspection.displayName : normalizedName,
            originKind: originKind,
            originURL: originURL,
            revisionKind: revisionKind,
            revision: revision ?? inspection.digest,
            intoSpaceID: spaceID,
            allowLargeImport: allowLargeImport
        )
    }

    func stageLocalRefresh(
        sourceID: String,
        allowLargeImport: Bool = false
    ) async throws -> ManagedRefreshCandidate {
        guard let source = try database.fetchSources().first(where: { $0.id == sourceID }),
              source.managedState == .ready,
              let originURL = source.originURL,
              source.originKind == .localFile || source.originKind == .localDirectory else {
            throw LibraryStorageError.missingSource(sourceID)
        }
        let authorizedURL: URL
        if let bookmark = try database.sourceAccessBookmark(sourceID: sourceID) {
            var isStale = false
            do {
                authorizedURL = try URL(
                    resolvingBookmarkData: bookmark,
                    options: Self.bookmarkResolutionOptions,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if isStale {
                    let renewed = try authorizedURL.bookmarkData(
                        options: Self.bookmarkCreationOptions,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    try database.saveSourceAccessBookmark(renewed, sourceID: sourceID)
                }
            } catch {
                throw LibraryStorageError.sourceAccessRequiresAuthorization(
                    source.displayName
                )
            }
        } else {
            authorizedURL = originURL
        }
        let didAccess = authorizedURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { authorizedURL.stopAccessingSecurityScopedResource() }
        }
        guard fileManager.isReadableFile(atPath: authorizedURL.path) else {
            throw LibraryStorageError.sourceAccessRequiresAuthorization(
                source.displayName
            )
        }
        let inspection = try await Task.detached(priority: .userInitiated) {
            try LocalSourceInspector.inspect(authorizedURL)
        }.value
        guard inspection.isDirectory == (source.originKind == .localDirectory) else {
            throw LibraryStorageError.unsupportedSource("来源的文件/目录类型已改变")
        }
        return try stageInspectedRefresh(
            source: source,
            sourceURL: authorizedURL,
            inspection: inspection,
            revisionKind: inspection.isDirectory ? .directoryTreeDigest : .contentDigest,
            revision: inspection.primaryRevision,
            allowLargeImport: allowLargeImport
        )
    }

    func authorizeLocalSource(sourceID: String, selectedURL: URL) throws {
        guard let source = try database.fetchSources().first(where: { $0.id == sourceID }),
              let originURL = source.originURL,
              source.originKind == .localFile || source.originKind == .localDirectory,
              selectedURL.standardizedFileURL == originURL.standardizedFileURL else {
            throw LibraryStorageError.unsupportedSource("请选择原来的本地来源")
        }
        let didAccess = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { selectedURL.stopAccessingSecurityScopedResource() }
        }
        let bookmark = try selectedURL.bookmarkData(
            options: Self.bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try database.saveSourceAccessBookmark(bookmark, sourceID: sourceID)
    }

    func stageFetchedRefresh(
        sourceID: String,
        at stagedSourceURL: URL,
        revisionKind: SourceRevisionKind,
        revision: String? = nil,
        allowLargeImport: Bool = false
    ) async throws -> ManagedRefreshCandidate {
        guard let source = try database.fetchSources().first(where: { $0.id == sourceID }),
              source.managedState == .ready,
              source.originKind == .remoteURL || source.originKind == .githubRepository else {
            throw LibraryStorageError.missingSource(sourceID)
        }
        let inspection = try await Task.detached(priority: .userInitiated) {
            try LocalSourceInspector.inspect(stagedSourceURL)
        }.value
        return try stageInspectedRefresh(
            source: source,
            sourceURL: stagedSourceURL,
            inspection: inspection,
            revisionKind: revisionKind,
            revision: revision ?? inspection.digest,
            allowLargeImport: allowLargeImport
        )
    }

    func discardRefreshCandidate(_ candidate: ManagedRefreshCandidate) throws {
        guard candidate.changed,
              let containerURL = candidate.createdContainerURL,
              try database.existingManagedPath(forDigest: candidate.snapshot.digest) == nil,
              fileManager.fileExists(atPath: containerURL.path) else { return }
        try fileManager.removeItem(at: containerURL)
    }

    private func stageInspectedRefresh(
        source: Source,
        sourceURL: URL,
        inspection: LocalSourceInspection,
        revisionKind: SourceRevisionKind,
        revision: String,
        allowLargeImport: Bool
    ) throws -> ManagedRefreshCandidate {
        guard !revision.isEmpty, revisionKind != .unresolved,
              let previousSnapshotID = source.latestSnapshotID,
              let previous = try database.fetchSnapshots(sourceID: source.id)
                .first(where: { $0.id == previousSnapshotID }) else {
            throw LibraryStorageError.unsupportedSource("来源缺少可刷新的当前 Snapshot")
        }
        if previous.revision == revision,
           previous.revisionKind == revisionKind,
           previous.digest == inspection.digest,
           let relativePath = previous.managedRelativePath {
            return ManagedRefreshCandidate(
                source: source,
                previousSnapshotID: previousSnapshotID,
                snapshot: previous,
                managedURL: try database.layout.url(forRelativePath: relativePath),
                reusedContent: true,
                changed: false,
                createdContainerURL: nil
            )
        }
        if inspection.byteCount > storagePolicy.largeImportThreshold,
           !allowLargeImport {
            throw LibraryStorageError.largeImportRequiresConfirmation(inspection.byteCount)
        }
        let existingRelativePath = try reusableManagedPath(
            try database.existingManagedPath(forDigest: inspection.digest),
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
        let snapshotID = UUID().uuidString.lowercased()
        let snapshot = SourceSnapshot(
            id: snapshotID,
            sourceID: source.id,
            revision: revision,
            revisionKind: revisionKind,
            digest: inspection.digest,
            observedAt: now,
            origin: source.originURL,
            managedRelativePath: try database.layout.relativePath(for: stored.url),
            byteCount: inspection.byteCount
        )
        var refreshedSource = source
        refreshedSource.latestSnapshotID = snapshotID
        refreshedSource.updatedAt = now
        return ManagedRefreshCandidate(
            source: refreshedSource,
            previousSnapshotID: previousSnapshotID,
            snapshot: snapshot,
            managedURL: stored.url,
            reusedContent: stored.reusedContent,
            changed: true,
            createdContainerURL: stored.createdContainer ? stored.containerURL : nil
        )
    }

    private func importInspectedSource(
        at sourceURL: URL,
        inspection: LocalSourceInspection,
        displayName: String,
        originKind: SourceOriginKind,
        originURL: URL,
        revisionKind: SourceRevisionKind,
        revision: String,
        intoSpaceID spaceID: String?,
        allowLargeImport: Bool,
        accessBookmark: Data? = nil,
        authorizationWarning: String? = nil
    ) throws -> ManagedImportResult {
        guard !revision.isEmpty, revisionKind != .unresolved else {
            throw LibraryStorageError.unsupportedSource("来源缺少不可变 revision")
        }

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
            displayName: displayName,
            originKind: originKind,
            originURL: originURL,
            managedState: .ready,
            latestSnapshotID: snapshotID,
            createdAt: now,
            updatedAt: now
        )
        let snapshot = SourceSnapshot(
            id: snapshotID,
            sourceID: sourceID,
            revision: revision,
            revisionKind: revisionKind,
            digest: inspection.digest,
            observedAt: now,
            origin: originURL,
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
            let title = (displayName as NSString).deletingPathExtension
            space = ReadingSpace(title: title.isEmpty ? displayName : title)
            createsSpace = true
        }

        do {
            try database.commitImport(
                source: source,
                snapshot: snapshot,
                space: space,
                createsSpace: createsSpace,
                accessBookmark: accessBookmark
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
            reusedContent: stored.reusedContent,
            authorizationWarning: authorizationWarning
        )
    }

    func removeSource(id sourceID: String) throws -> [String: Int] {
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
            let generations = try database.commitRemoval(sourceID: sourceID)
            removeDerivedData(forSnapshotIDs: plan.snapshotIDs)
#if os(iOS)
            // iOS has no user-visible Trash API. Keep the move reversible until
            // the database transaction succeeds, then discard the staged copy.
            for item in movedItems {
                try? fileManager.removeItem(at: item.trashed)
            }
#endif
            return generations
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

    private func removeDerivedData(forSnapshotIDs snapshotIDs: [String]) {
        let namespaces = ["epub"]
        for snapshotID in snapshotIDs where Self.isSafePathComponent(snapshotID) {
            for namespace in namespaces {
                let url = database.layout.derivedURL
                    .appendingPathComponent(namespace, isDirectory: true)
                    .appendingPathComponent(snapshotID, isDirectory: true)
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
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
            for resource in inspection.referencedResources {
                let destination = stagingContainer.appendingPathComponent(
                    resource.relativePath
                )
                guard destination.standardizedFileURL.pathComponents.starts(
                    with: stagingContainer.standardizedFileURL.pathComponents
                ) else {
                    throw LibraryStorageError.referencedResourceOutsideSource(
                        resource.relativePath
                    )
                }
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: resource.sourceURL, to: destination)
            }
            guard try LocalSourceInspector.verifyManagedPayload(
                stagedPayload,
                matches: inspection,
                fileManager: fileManager
            ) else {
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
                    let replacedContainer = try fileManager.replaceItemAt(
                        containerURL,
                        withItemAt: stagingContainer,
                        backupItemName: nil,
                        options: []
                    ) ?? containerURL
                    let replacedManagedURL = replacedContainer.appendingPathComponent(
                        "payload",
                        isDirectory: inspection.isDirectory
                    )
                    try verifyManagedContent(replacedManagedURL, matches: inspection)
                    return StoredContent(
                        url: replacedManagedURL,
                        containerURL: replacedContainer,
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
        guard try LocalSourceInspector.verifyManagedPayload(
            managedURL,
            matches: inspection,
            fileManager: fileManager
        ) else {
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
            try db.execute(
                sql: "DELETE FROM observation_fts WHERE source_id = ?",
                arguments: [sourceID]
            )
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

    private static func removeAbandonedEPUBStaging(
        at epubDerivedURL: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: epubDerivedURL.path) else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: epubDerivedURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for entry in entries where entry.lastPathComponent.hasPrefix(".staging-") {
            let values = try entry.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                continue
            }
            try fileManager.removeItem(at: entry)
        }
    }

    private static func removeOrphanedEPUBDerived(
        at epubDerivedURL: URL,
        activeSnapshotIDs: Set<String>,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: epubDerivedURL.path) else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: epubDerivedURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for entry in entries where !entry.lastPathComponent.hasPrefix(".staging-") {
            let values = try entry.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            if activeSnapshotIDs.contains(entry.lastPathComponent),
               values.isDirectory == true,
               values.isSymbolicLink != true {
                continue
            }
            try fileManager.removeItem(at: entry)
        }
    }

    private nonisolated static func moveToTrash(_ url: URL) throws -> URL {
#if os(macOS)
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL else {
            throw LibraryStorageError.trashDestinationUnavailable(url.path)
        }
        return resultingURL as URL
#else
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneReader-RemovalTrash", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        let destination = stagingRoot.appendingPathComponent(
            "\(UUID().uuidString.lowercased())-\(url.lastPathComponent)",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
#endif
    }

    private nonisolated static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
#if os(macOS)
        [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
#else
        [.minimalBookmark]
#endif
    }

    private nonisolated static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
#if os(macOS)
        [.withSecurityScope, .withoutUI]
#else
        [.withoutUI]
#endif
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
    let primaryRevision: String
    let byteCount: Int64
    let referencedResources: [LocalSourceResource]
}

private struct LocalSourceResource: Sendable {
    let sourceURL: URL
    let relativePath: String
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

        let result: (digest: String, primaryRevision: String, byteCount: Int64,
            resources: [LocalSourceResource])
        if values.isDirectory == true {
            let directory = try inspectDirectory(url, fileManager: fileManager)
            result = (directory.digest, directory.digest, directory.byteCount, [])
        } else {
            let primary = try digestFile(url)
            let resources = try referencedResources(
                for: url,
                primaryByteCount: primary.byteCount,
                fileManager: fileManager
            )
            let digest = resources.isEmpty
                ? primary.digest
                : bundleDigest(primaryDigest: primary.digest, resources: resources)
            result = (
                digest,
                primary.digest,
                primary.byteCount + resources.reduce(0) { $0 + $1.byteCount },
                resources
            )
        }
        return LocalSourceInspection(
            displayName: url.lastPathComponent,
            isDirectory: values.isDirectory == true,
            digest: result.digest,
            primaryRevision: result.primaryRevision,
            byteCount: result.byteCount,
            referencedResources: result.resources
        )
    }

    static func verifyManagedPayload(
        _ managedURL: URL,
        matches inspection: LocalSourceInspection,
        fileManager: FileManager
    ) throws -> Bool {
        if inspection.isDirectory {
            let candidate = try inspectDirectory(managedURL, fileManager: fileManager)
            return candidate.digest == inspection.digest
                && candidate.byteCount == inspection.byteCount
        }
        let primary = try digestFile(managedURL)
        guard primary.digest == inspection.primaryRevision else { return false }
        let container = managedURL.deletingLastPathComponent()
        var verifiedResources: [LocalSourceResource] = []
        for resource in inspection.referencedResources {
            let url = container.appendingPathComponent(resource.relativePath).standardizedFileURL
            guard url.pathComponents.starts(with: container.standardizedFileURL.pathComponents),
                  fileManager.fileExists(atPath: url.path) else {
                return false
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
            let candidate = try digestFile(url)
            guard candidate.digest == resource.digest,
                  candidate.byteCount == resource.byteCount else { return false }
            verifiedResources.append(
                LocalSourceResource(
                    sourceURL: url,
                    relativePath: resource.relativePath,
                    digest: candidate.digest,
                    byteCount: candidate.byteCount
                )
            )
        }
        let digest = verifiedResources.isEmpty
            ? primary.digest
            : bundleDigest(primaryDigest: primary.digest, resources: verifiedResources)
        return digest == inspection.digest
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

    private static func referencedResources(
        for sourceURL: URL,
        primaryByteCount: Int64,
        fileManager: FileManager
    ) throws -> [LocalSourceResource] {
        guard primaryByteCount <= 32 * 1_024 * 1_024 else { return [] }
        let ext = sourceURL.pathExtension.lowercased()
        guard ["html", "htm", "xhtml", "md", "markdown", "mdown", "mkd"]
            .contains(ext),
              let text = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return []
        }
        let references: [String]
        if ["html", "htm", "xhtml"].contains(ext) {
            let document = try SwiftSoup.parse(text, sourceURL.absoluteString)
            var values: [String] = []
            for selectorAndAttribute in [
                ("img[src]", "src"),
                ("source[src]", "src"),
                ("video[poster]", "poster"),
                ("link[rel=stylesheet][href]", "href"),
            ] {
                values.append(contentsOf: try document
                    .select(selectorAndAttribute.0)
                    .array()
                    .map { try $0.attr(selectorAndAttribute.1) })
            }
            references = values
        } else {
            let regex = try NSRegularExpression(
                pattern: #"!\[[^\]]*\]\(\s*<?([^\s)>]+)>?(?:\s+[^)]*)?\)"#
            )
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            references = regex.matches(in: text, range: range).compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }
        }

        let authorizedRoot = sourceURL.deletingLastPathComponent().standardizedFileURL
        var seen = Set<String>()
        var resources: [LocalSourceResource] = []
        for rawReference in references {
            let withoutFragment = rawReference.split(separator: "#", maxSplits: 1)
                .first.map(String.init) ?? rawReference
            let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1)
                .first.map(String.init) ?? withoutFragment
            let decoded = withoutQuery.removingPercentEncoding ?? withoutQuery
            if decoded.isEmpty || decoded.hasPrefix("data:") || decoded.hasPrefix("#") {
                continue
            }
            if URL(string: decoded)?.scheme != nil { continue }
            guard !decoded.hasPrefix("/"), !decoded.contains("\\") else {
                throw LibraryStorageError.referencedResourceOutsideSource(rawReference)
            }
            let candidate = authorizedRoot.appendingPathComponent(decoded).standardizedFileURL
            guard candidate.pathComponents.starts(with: authorizedRoot.pathComponents) else {
                throw LibraryStorageError.referencedResourceOutsideSource(rawReference)
            }
            let relativePath = candidate.pathComponents
                .dropFirst(authorizedRoot.pathComponents.count)
                .joined(separator: "/")
            guard !relativePath.isEmpty, seen.insert(relativePath).inserted else { continue }
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            let values = try candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw LibraryStorageError.symbolicLinkNotAllowed(relativePath)
            }
            guard values.isRegularFile == true else { continue }
            let digest = try digestFile(candidate)
            resources.append(
                LocalSourceResource(
                    sourceURL: candidate,
                    relativePath: relativePath,
                    digest: digest.digest,
                    byteCount: digest.byteCount
                )
            )
        }
        return resources.sorted { $0.relativePath < $1.relativePath }
    }

    private static func bundleDigest(
        primaryDigest: String,
        resources: [LocalSourceResource]
    ) -> String {
        var hasher = SHA256()
        update(&hasher, string: "primary")
        update(&hasher, string: primaryDigest)
        for resource in resources.sorted(by: { $0.relativePath < $1.relativePath }) {
            update(&hasher, string: resource.relativePath)
            update(&hasher, string: resource.digest)
        }
        return hex(hasher.finalize())
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
