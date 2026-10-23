import Foundation
import XCTest
@testable import OneReader

@MainActor
final class UnifiedLibrarySearchTests: XCTestCase {
    func testUnifiedLibrarySearchReturnsSpacesContentHitsAndPrivateNotesWithoutLeakingNotesIntoContentHits() async throws {
        let root = temporaryRoot("UnifiedSearch")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceURL = root.appendingPathComponent("quantum-guide.md")
        let markdown = """
        # Quantum Systems

        ## Telemetry Architecture

        Quantum telemetry anchors every observation to an immutable snapshot.
        """
        try Data(markdown.utf8).write(to: sourceURL)

        let suite = "OneReaderTests.UnifiedSearch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library"),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }

        model.importLocalURLs([sourceURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.spaces.count == 1
                && model.presentationDocument != nil
                && model.activePendingImportCount == 0
        }

        model.addNote("Quantum note with secretvaultmarker for unified search")
        try await waitUntil {
            model.annotations.count == 1
        }
        model.closeReadingWorkspace()

        model.librarySearchText = "Quantum"
        model.performUnifiedLibrarySearch()
        try await waitUntil {
            !model.isUnifiedSearching && !model.unifiedSearchResults.contentHits.isEmpty
        }

        XCTAssertTrue(model.hasActiveLibrarySearch)
        XCTAssertEqual(model.unifiedSearchResults.spaces.count, 1)
        XCTAssertFalse(model.unifiedSearchResults.contentHits.isEmpty)
        XCTAssertEqual(model.unifiedSearchResults.noteEntries.count, 1)

        // Private notes must never leak into full-text Observation contentHits.
        model.librarySearchText = "secretvaultmarker"
        model.performUnifiedLibrarySearch()
        try await waitUntil {
            !model.isUnifiedSearching && model.unifiedSearchResults.noteEntries.count == 1
        }
        XCTAssertTrue(model.unifiedSearchResults.spaces.isEmpty)
        XCTAssertTrue(model.unifiedSearchResults.contentHits.isEmpty)
        XCTAssertEqual(model.unifiedSearchResults.noteEntries.count, 1)
        XCTAssertTrue(model.unifiedSearchResults.noteEntries[0].preview.contains("secretvaultmarker"))

        // Clearing search text resets unifiedSearchResults to .isEmpty.
        model.librarySearchText = "   "
        model.performUnifiedLibrarySearch()
        XCTAssertFalse(model.hasActiveLibrarySearch)
        XCTAssertFalse(model.isUnifiedSearching)
        XCTAssertTrue(model.unifiedSearchResults.isEmpty)
    }

    func testOpenLibraryContentSearchHitNavigatesToTargetSpaceSourceAndLocator() async throws {
        let root = temporaryRoot("UnifiedContentHit")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceURL = root.appendingPathComponent("handbook.md")
        let markdown = """
        # First Chapter

        Introductory material.

        # Second Chapter

        UniqueSearchTokenAlpha appears in the second section.
        """
        try Data(markdown.utf8).write(to: sourceURL)

        let suite = "OneReaderTests.UnifiedContentHit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library"),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }

        model.importLocalURLs([sourceURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.spaces.count == 1
                && model.presentationDocument != nil
                && model.activePendingImportCount == 0
        }
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        let sourceID = try XCTUnwrap(model.selectedSourceID)
        model.closeReadingWorkspace()
        XCTAssertFalse(model.isReadingWorkspaceOpen)

        model.librarySearchText = "UniqueSearchTokenAlpha"
        model.performUnifiedLibrarySearch()
        try await waitUntil {
            !model.isUnifiedSearching && !model.unifiedSearchResults.contentHits.isEmpty
        }

        let hit = try XCTUnwrap(model.unifiedSearchResults.contentHits.first)
        model.openLibraryContentSearchHit(hit)
        try await waitUntil(timeout: .seconds(5)) {
            model.isReadingWorkspaceOpen
                && model.selectedSpaceID == spaceID
                && model.selectedSourceID == sourceID
                && model.currentPositionLocator == hit.locator
        }

        XCTAssertEqual(model.selectedSpaceID, spaceID)
        XCTAssertEqual(model.selectedSourceID, sourceID)
        XCTAssertEqual(model.currentPositionLocator, hit.locator)
    }

    func testOpenLibraryNoteHitOpensNoteSpaceAndSnapshotPreviewLocator() async throws {
        let root = temporaryRoot("UnifiedNoteHit")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceURL = root.appendingPathComponent("notes-source.md")
        try Data("# Field Notes\n\nAnchor paragraph for note navigation.\n".utf8).write(to: sourceURL)

        let suite = "OneReaderTests.UnifiedNoteHit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library"),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }

        model.importLocalURLs([sourceURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.spaces.count == 1
                && model.presentationDocument != nil
                && model.activePendingImportCount == 0
        }
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        let sourceID = try XCTUnwrap(model.selectedSourceID)
        let snapshotID = try XCTUnwrap(model.selectedSnapshot?.id)

        model.addNote("JumpToNoteAnchorToken")
        try await waitUntil { model.annotations.count == 1 }
        let noteLocator = try XCTUnwrap(model.annotations.first?.locator)
        model.closeReadingWorkspace()
        XCTAssertFalse(model.isReadingWorkspaceOpen)

        model.librarySearchText = "JumpToNoteAnchorToken"
        model.performUnifiedLibrarySearch()
        try await waitUntil {
            !model.isUnifiedSearching && model.unifiedSearchResults.noteEntries.count == 1
        }

        let entry = try XCTUnwrap(model.unifiedSearchResults.noteEntries.first)
        model.openLibraryNoteHit(entry)
        try await waitUntil(timeout: .seconds(5)) {
            model.isReadingWorkspaceOpen
                && model.presentationDocument != nil
                && model.isAnnotationPreview
        }

        XCTAssertEqual(model.selectedSpaceID, spaceID)
        XCTAssertEqual(model.selectedSourceID, sourceID)
        XCTAssertEqual(model.selectedSnapshot?.id, snapshotID)
        XCTAssertEqual(model.currentPositionLocator, noteLocator)

        let receipt = CaptureReceipt(
            source: .remote(URL(string: "https://example.com/article")!),
            displayName: "Queued Article"
        )
        model.captureJobs = [
            CaptureJob(
                receipt: receipt,
                phase: .importing,
                attemptCount: 1,
                requiresLargeImportConfirmation: false,
                allowLargeImport: false,
                updatedAt: .now
            )
        ]
        XCTAssertEqual(model.unifiedProcessingCount, 1)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(condition(), "Condition did not become true before timeout")
    }

    private func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OneReaderUnifiedSearch-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }
}
