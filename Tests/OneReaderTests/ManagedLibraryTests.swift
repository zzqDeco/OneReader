import Foundation
import CryptoKit
import XCTest
@testable import OneReader

final class ManagedLibraryTests: XCTestCase {
    func testAtomicImportCreatesManagedSnapshotAndDefaultSpace() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = fixture.input.appendingPathComponent("chapter.md")
        try Data("# Chapter\n\nEvidence.".utf8).write(to: original)

        let database = try LibraryDatabase(rootURL: fixture.library)
        let library = try ManagedLibrary(database: database)
        let result = try await library.importLocalSource(at: original)

        XCTAssertEqual(result.source.displayName, "chapter.md")
        XCTAssertEqual(result.source.managedState, .ready)
        XCTAssertEqual(result.snapshot.revisionKind, .contentDigest)
        XCTAssertEqual(result.snapshot.digest.count, 64)
        XCTAssertEqual(try Data(contentsOf: result.managedURL), Data("# Chapter\n\nEvidence.".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try database.fetchSources().map(\.id), [result.source.id])
        XCTAssertEqual(try database.fetchSpaces().map(\.id), [result.space.id])
        XCTAssertEqual(try database.sourceIDs(in: result.space.id), [result.source.id])
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: database.layout.stagingURL,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testIdenticalContentReusesManagedBytes() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstURL = fixture.input.appendingPathComponent("first.txt")
        let secondURL = fixture.input.appendingPathComponent("second.txt")
        let bytes = Data("same immutable bytes".utf8)
        try bytes.write(to: firstURL)
        try bytes.write(to: secondURL)

        let database = try LibraryDatabase(rootURL: fixture.library)
        let library = try ManagedLibrary(database: database)
        let first = try await library.importLocalSource(at: firstURL)
        let second = try await library.importLocalSource(at: secondURL)

        XCTAssertFalse(first.reusedContent)
        XCTAssertTrue(second.reusedContent)
        XCTAssertEqual(first.snapshot.digest, second.snapshot.digest)
        XCTAssertEqual(first.managedURL, second.managedURL)
        XCTAssertEqual(try database.fetchSources().count, 2)
        XCTAssertEqual(try database.fetchSnapshots().count, 2)
    }

    func testDirectoryDigestIncludesNestedPackageContentAndIsDeterministic() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstDirectory = fixture.input.appendingPathComponent("FirstBook", isDirectory: true)
        let secondDirectory = fixture.input.appendingPathComponent("SecondBook", isDirectory: true)

        for directory in [firstDirectory, secondDirectory] {
            let packageContents = directory
                .appendingPathComponent("Reader.app", isDirectory: true)
                .appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(
                at: packageContents,
                withIntermediateDirectories: true
            )
            try Data("chapter".utf8).write(
                to: directory.appendingPathComponent("chapter.md")
            )
            try Data("package-a".utf8).write(
                to: packageContents.appendingPathComponent("payload.txt")
            )
        }

        let database = try LibraryDatabase(rootURL: fixture.library)
        let library = try ManagedLibrary(database: database)
        let first = try await library.importLocalSource(at: firstDirectory)
        let second = try await library.importLocalSource(at: secondDirectory)

        XCTAssertEqual(first.snapshot.revisionKind, .directoryTreeDigest)
        XCTAssertEqual(first.snapshot.digest, second.snapshot.digest)
        XCTAssertEqual(first.snapshot.byteCount, Int64("chapter".utf8.count + "package-a".utf8.count))
        XCTAssertTrue(second.reusedContent)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: first.managedURL
                    .appendingPathComponent("Reader.app/Contents/payload.txt")
                    .path
            )
        )

        try Data("package-b".utf8).write(
            to: secondDirectory.appendingPathComponent("Reader.app/Contents/payload.txt")
        )
        let changed = try await library.importLocalSource(at: secondDirectory)

        XCTAssertNotEqual(changed.snapshot.digest, first.snapshot.digest)
        XCTAssertFalse(changed.reusedContent)
    }

    func testLargeImportRequiresExplicitConfirmation() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceURL = fixture.input.appendingPathComponent("large.txt")
        try Data("12345".utf8).write(to: sourceURL)
        let policy = LibraryStoragePolicy(
            largeImportThreshold: 4,
            minimumFreeCapacity: 2,
            capacityProvider: { _ in 100 }
        )
        let database = try LibraryDatabase(rootURL: fixture.library)
        let library = try ManagedLibrary(database: database, storagePolicy: policy)

        do {
            _ = try await library.importLocalSource(at: sourceURL)
            XCTFail("Expected confirmation requirement")
        } catch let error as LibraryStorageError {
            XCTAssertEqual(error, .largeImportRequiresConfirmation(5))
        }
        let imported = try await library.importLocalSource(
            at: sourceURL,
            allowLargeImport: true
        )
        XCTAssertEqual(imported.snapshot.byteCount, 5)
    }

    func testImportRejectsCapacityBelowConfiguredReserve() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceURL = fixture.input.appendingPathComponent("three.txt")
        try Data("123".utf8).write(to: sourceURL)
        let policy = LibraryStoragePolicy(
            largeImportThreshold: 100,
            minimumFreeCapacity: 10,
            capacityProvider: { _ in 12 }
        )
        let database = try LibraryDatabase(rootURL: fixture.library)
        let library = try ManagedLibrary(database: database, storagePolicy: policy)

        do {
            _ = try await library.importLocalSource(at: sourceURL)
            XCTFail("Expected free-space rejection")
        } catch let error as LibraryStorageError {
            XCTAssertEqual(error, .insufficientFreeSpace(required: 10, available: 9))
        }
        XCTAssertTrue(try database.fetchSources().isEmpty)
    }

    func testDeduplicatedImportDoesNotChargeManagedBytesAgain() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstURL = fixture.input.appendingPathComponent("first.txt")
        let secondURL = fixture.input.appendingPathComponent("second.txt")
        try Data("shared".utf8).write(to: firstURL)
        try Data("shared".utf8).write(to: secondURL)
        let database = try LibraryDatabase(rootURL: fixture.library)
        let initialLibrary = try ManagedLibrary(
            database: database,
            storagePolicy: LibraryStoragePolicy(
                largeImportThreshold: 100,
                minimumFreeCapacity: 10,
                capacityProvider: { _ in 100 }
            )
        )
        _ = try await initialLibrary.importLocalSource(at: firstURL)

        let constrainedLibrary = try ManagedLibrary(
            database: database,
            storagePolicy: LibraryStoragePolicy(
                largeImportThreshold: 100,
                minimumFreeCapacity: 10,
                capacityProvider: { _ in 10 }
            )
        )
        let second = try await constrainedLibrary.importLocalSource(at: secondURL)

        XCTAssertTrue(second.reusedContent)
    }

    func testImportAdoptsVerifiedOrphanedContentContainer() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceURL = fixture.input.appendingPathComponent("orphan.txt")
        let bytes = Data("orphaned after crash".utf8)
        try bytes.write(to: sourceURL)
        let digest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let orphanPayload = fixture.library
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
            .appendingPathComponent("payload")

        let database = try LibraryDatabase(rootURL: fixture.library)
        try FileManager.default.createDirectory(
            at: orphanPayload.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: orphanPayload)
        let library = try ManagedLibrary(database: database)

        let result = try await library.importLocalSource(at: sourceURL)

        XCTAssertTrue(result.reusedContent)
        XCTAssertEqual(result.managedURL, orphanPayload)
        XCTAssertEqual(try database.fetchSources().map(\.id), [result.source.id])
    }

    func testReimportRepairsMissingRecordedManagedCopy() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstURL = fixture.input.appendingPathComponent("first.txt")
        let secondURL = fixture.input.appendingPathComponent("second.txt")
        let bytes = Data("recoverable bytes".utf8)
        try bytes.write(to: firstURL)
        try bytes.write(to: secondURL)
        let database = try LibraryDatabase(rootURL: fixture.library)
        let library = try ManagedLibrary(database: database)
        let first = try await library.importLocalSource(at: firstURL)
        try FileManager.default.removeItem(at: first.managedURL.deletingLastPathComponent())

        let repaired = try await library.importLocalSource(at: secondURL)

        XCTAssertFalse(repaired.reusedContent)
        XCTAssertEqual(repaired.managedURL, first.managedURL)
        XCTAssertEqual(try Data(contentsOf: repaired.managedURL), bytes)
        XCTAssertEqual(try database.fetchSources().count, 2)
    }

    func testReimportRepairsCorruptedRecordedManagedCopy() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstURL = fixture.input.appendingPathComponent("first.txt")
        let secondURL = fixture.input.appendingPathComponent("second.txt")
        let bytes = Data("expected bytes".utf8)
        try bytes.write(to: firstURL)
        try bytes.write(to: secondURL)
        let database = try LibraryDatabase(rootURL: fixture.library)
        let library = try ManagedLibrary(database: database)
        let first = try await library.importLocalSource(at: firstURL)
        try Data("corrupted".utf8).write(to: first.managedURL, options: .atomic)

        let repaired = try await library.importLocalSource(at: secondURL)

        XCTAssertFalse(repaired.reusedContent)
        XCTAssertEqual(try Data(contentsOf: repaired.managedURL), bytes)
        XCTAssertEqual(try database.fetchSources().count, 2)
    }

    func testDirectoryImportRejectsSymbolicLinks() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = fixture.input.appendingPathComponent("Book", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = fixture.input.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("escape.txt"),
            withDestinationURL: outside
        )

        let database = try LibraryDatabase(rootURL: fixture.library)
        let library = try ManagedLibrary(database: database)

        do {
            _ = try await library.importLocalSource(at: directory)
            XCTFail("Expected a symbolic-link rejection")
        } catch let error as LibraryStorageError {
            guard case .symbolicLinkNotAllowed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(try database.fetchSources().isEmpty)
    }

    func testSingleHTMLImportCopiesReferencedSiblingResourcesIntoManagedSnapshot() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let assets = fixture.input.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let html = Data("<h1>Book</h1><img src=\"images/cover.png\">".utf8)
        let image = Data([0x89, 0x50, 0x4e, 0x47])
        let sourceURL = fixture.input.appendingPathComponent("book.html")
        try html.write(to: sourceURL)
        try image.write(to: assets.appendingPathComponent("cover.png"))
        let database = try LibraryDatabase(rootURL: fixture.library)
        let library = try ManagedLibrary(database: database)

        let imported = try await library.importLocalSource(at: sourceURL)

        XCTAssertEqual(imported.snapshot.revisionKind, .contentDigest)
        XCTAssertNotEqual(imported.snapshot.revision, imported.snapshot.digest)
        XCTAssertEqual(imported.snapshot.byteCount, Int64(html.count + image.count))
        XCTAssertEqual(
            try Data(
                contentsOf: imported.managedURL.deletingLastPathComponent()
                    .appendingPathComponent("images/cover.png")
            ),
            image
        )

        try Data([0x89, 0x50, 0x4e, 0x48]).write(
            to: assets.appendingPathComponent("cover.png"),
            options: .atomic
        )
        let changed = try await library.importLocalSource(at: sourceURL)
        XCTAssertNotEqual(changed.snapshot.digest, imported.snapshot.digest)
        XCTAssertNotEqual(changed.managedURL, imported.managedURL)
        XCTAssertFalse(changed.reusedContent)
    }

    func testSingleFileImportRejectsReferencedResourceOutsideAuthorizedDirectory() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let nested = fixture.input.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: fixture.input.appendingPathComponent("outside.png"))
        let sourceURL = nested.appendingPathComponent("book.html")
        try Data("<img src=\"../outside.png\">".utf8).write(to: sourceURL)
        let database = try LibraryDatabase(rootURL: fixture.library)
        let library = try ManagedLibrary(database: database)

        do {
            _ = try await library.importLocalSource(at: sourceURL)
            XCTFail("Expected referenced-resource boundary rejection")
        } catch let error as LibraryStorageError {
            guard case .referencedResourceOutsideSource = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(try database.fetchSources().isEmpty)
    }

    func testInitializationRemovesOnlyAbandonedStagingEntries() throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let database = try LibraryDatabase(rootURL: fixture.library)
        let abandoned = database.layout.stagingURL
            .appendingPathComponent("abandoned", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: abandoned.appendingPathComponent("payload"))

        _ = try ManagedLibrary(database: database)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.sourcesURL.path))
    }

    func testInitializationReclaimsAbandonedAndInactiveEPUBDerivedData() throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let database = try LibraryDatabase(rootURL: fixture.library)
        let source = Source(
            id: "source-keep",
            displayName: "keep.epub",
            originKind: .localFile,
            originURL: nil,
            managedState: .ready,
            latestSnapshotID: "snapshot-keep"
        )
        let snapshot = SourceSnapshot(
            id: "snapshot-keep",
            sourceID: source.id,
            revision: "digest",
            revisionKind: .contentDigest,
            digest: "digest",
            observedAt: .now,
            origin: nil,
            managedRelativePath: nil,
            byteCount: 0
        )
        let space = ReadingSpace(id: "space-keep", title: "Keep")
        try database.commitImport(
            source: source,
            snapshot: snapshot,
            space: space,
            createsSpace: true
        )
        let removedSource = Source(
            id: "source-removed",
            displayName: "removed.epub",
            originKind: .localFile,
            originURL: nil,
            managedState: .ready,
            latestSnapshotID: "snapshot-removed"
        )
        let removedSnapshot = SourceSnapshot(
            id: "snapshot-removed",
            sourceID: removedSource.id,
            revision: "removed-digest",
            revisionKind: .contentDigest,
            digest: "removed-digest",
            observedAt: .now,
            origin: nil,
            managedRelativePath: nil,
            byteCount: 0
        )
        try database.commitImport(
            source: removedSource,
            snapshot: removedSnapshot,
            space: space,
            createsSpace: false
        )
        _ = try database.commitRemoval(sourceID: removedSource.id)
        let epubRoot = database.layout.derivedURL.appendingPathComponent("epub", isDirectory: true)
        let abandoned = epubRoot.appendingPathComponent(".staging-orphan", isDirectory: true)
        let committed = epubRoot.appendingPathComponent("snapshot-keep", isDirectory: true)
        let inactive = epubRoot.appendingPathComponent("snapshot-inactive", isDirectory: true)
        let removed = epubRoot.appendingPathComponent("snapshot-removed", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: committed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inactive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: abandoned.appendingPathComponent("chapter.html"))
        try Data("ready".utf8).write(to: committed.appendingPathComponent("chapter.html"))
        try Data("orphan".utf8).write(to: inactive.appendingPathComponent("chapter.html"))

        _ = try ManagedLibrary(database: database)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inactive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
    }

    func testRemovingSourceTrashesOnlyManagedCopyAndKeepsOriginal() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceURL = fixture.input.appendingPathComponent("note.txt")
        try Data("keep original".utf8).write(to: sourceURL)
        let trashURL = fixture.root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let database = try LibraryDatabase(rootURL: fixture.library)
        let library = try ManagedLibrary(
            database: database,
            trashHandler: fakeTrashHandler(at: trashURL)
        )
        let imported = try await library.importLocalSource(at: sourceURL)
        let managedContainer = imported.managedURL.deletingLastPathComponent()

        _ = try await library.removeSource(id: imported.source.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedContainer.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: trashURL.path).count,
            1
        )
        XCTAssertTrue(try database.fetchSources().isEmpty)
        XCTAssertEqual(try database.fetchSources(includeRemoved: true).first?.managedState, .removed)
        XCTAssertTrue(try database.sourceIDs(in: imported.space.id).isEmpty)
    }

    func testRemovingSourceReclaimsSnapshotDerivedEPUBCache() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceURL = fixture.input.appendingPathComponent("book.epub")
        try Data("managed archive bytes".utf8).write(to: sourceURL)
        let trashURL = fixture.root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let database = try LibraryDatabase(rootURL: fixture.library)
        let library = try ManagedLibrary(
            database: database,
            trashHandler: fakeTrashHandler(at: trashURL)
        )
        let imported = try await library.importLocalSource(at: sourceURL)
        let derived = database.layout.derivedURL
            .appendingPathComponent("epub", isDirectory: true)
            .appendingPathComponent(imported.snapshot.id, isDirectory: true)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: derived.appendingPathComponent("spine.html"))

        _ = try await library.removeSource(id: imported.source.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: derived.path))
    }

    func testRemovingOneDeduplicatedSourceKeepsSharedManagedCopy() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstURL = fixture.input.appendingPathComponent("first.txt")
        let secondURL = fixture.input.appendingPathComponent("second.txt")
        try Data("shared".utf8).write(to: firstURL)
        try Data("shared".utf8).write(to: secondURL)
        let trashURL = fixture.root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let database = try LibraryDatabase(rootURL: fixture.library)
        let library = try ManagedLibrary(
            database: database,
            trashHandler: fakeTrashHandler(at: trashURL)
        )
        let first = try await library.importLocalSource(at: firstURL)
        let second = try await library.importLocalSource(at: secondURL)

        _ = try await library.removeSource(id: first.source.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: second.managedURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trashURL.path).isEmpty)
        XCTAssertEqual(try database.fetchSources().map(\.id), [second.source.id])
    }

    private func makeFixtureDirectory() throws -> (root: URL, input: URL, library: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneReaderManagedTests-\(UUID().uuidString)", isDirectory: true)
        let input = root.appendingPathComponent("Input", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        return (root, input, library)
    }

    private func fakeTrashHandler(
        at trashURL: URL
    ) -> ManagedLibrary.TrashHandler {
        { sourceURL in
            let destination = trashURL.appendingPathComponent(
                UUID().uuidString.lowercased(),
                isDirectory: true
            )
            try FileManager.default.moveItem(at: sourceURL, to: destination)
            return destination
        }
    }
}
