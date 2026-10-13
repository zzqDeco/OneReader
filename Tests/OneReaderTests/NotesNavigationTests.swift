import Foundation
import XCTest
@testable import OneReader

@MainActor
final class NotesNavigationTests: XCTestCase {
    func testOriginalSnapshotOpeningPreservesCurrentProgressAndDoesNotUseProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesNavigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("local.md")
        try Data("# Local material\n\nPreserved quotation.\n".utf8).write(to: sourceURL)
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: LibraryStoragePolicy(largeImportThreshold: .max, minimumFreeCapacity: 0, capacityProvider: { _ in .max }))
        let imported = try await library.importLocalSource(at: sourceURL)
        let coordinator = try AdapterCoordinator.standard(database: database)
        let plan = try await coordinator.prepare(sourceID: imported.source.id, snapshotID: imported.snapshot.id)
        let nodes = try await coordinator.list(plan: plan)
        let locator = try XCTUnwrap(nodes.first?.locator)
        let annotation = Annotation(id: "old-note", spaceID: imported.space.id, sourceID: imported.source.id, snapshotID: imported.snapshot.id, kind: .bookmark, locator: locator, anchorState: .current, selectedText: nil, note: "Retained note", color: nil, createdAt: .now, updatedAt: .now)
        try database.saveAnnotation(annotation)
        let newer = SourceSnapshot(id: "new-snapshot", sourceID: imported.source.id, revision: imported.snapshot.revision, revisionKind: imported.snapshot.revisionKind, digest: imported.snapshot.digest, observedAt: .now, origin: imported.snapshot.origin, managedRelativePath: imported.snapshot.managedRelativePath, byteCount: imported.snapshot.byteCount)
        try database.commitSnapshotRefreshForTesting(newer)
        var progress = ReadingProgress.empty
        progress.lastActiveAt = Date(timeIntervalSince1970: 100)
        let newerLocator = Locator(sourceID: locator.sourceID, snapshotID: newer.id, adapterID: locator.adapterID, payload: locator.payload, structuralPath: locator.structuralPath, textQuote: locator.textQuote, fingerprint: locator.fingerprint)
        progress.sourcePositions[imported.source.id] = SourcePosition(sourceID: imported.source.id, locator: newerLocator, updatedAt: Date(timeIntervalSince1970: 100), progressFraction: 0.7, granularity: .text, displayLabel: "Current position")
        try database.saveReadingProgress(progress, spaceID: imported.space.id)
        let suite = "NotesNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(libraryRootURL: database.layout.rootURL, defaults: defaults, secretStore: InMemoryProviderSecretStore())
        try await waitUntil { model.isBootstrapComplete }
        let notes = try XCTUnwrap(model.notesCenter)
        await notes.reload()
        let entry = try XCTUnwrap(notes.entries.first)
        XCTAssertFalse(entry.isLatestSnapshot)
        XCTAssertTrue(entry.statusLabel.hasPrefix("历史快照"))
        await notes.open(entry)
        try await waitUntil { model.presentationDocument != nil }
        XCTAssertEqual(model.presentationDocument?.locator.snapshotID, imported.snapshot.id)
        XCTAssertEqual(model.selectedSnapshot?.id, imported.snapshot.id)
        XCTAssertTrue(model.isAnnotationPreview)
        model.updateReadingPosition(ReadingPositionUpdate(locator: locator, progressFraction: 0.1, granularity: .text))
        model.flushReadingPosition()
        XCTAssertEqual(try database.fetchReadingProgress(spaceID: imported.space.id), progress)
        XCTAssertTrue(model.agentRuns.isEmpty)
        XCTAssertNil(model.activeProvider)
        model.closeReadingWorkspace()
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(10)
        while !predicate() {
            if Date.now > deadline { XCTFail("Timed out waiting for local reader state"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
