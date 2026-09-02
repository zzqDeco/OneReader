import Foundation
import GRDB
import XCTest
@testable import OneReader

@MainActor
final class AppModelLibraryTests: XCTestCase {
    func testBootstrapStartsWithEmptyLibraryAndNoDemoContent() async throws {
        let root = temporaryRoot("Empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(libraryRootURL: root, defaults: defaults)

        try await waitUntil { model.isBootstrapComplete }

        XCTAssertTrue(model.spaces.isEmpty)
        XCTAssertTrue(model.sources.isEmpty)
        XCTAssertFalse(model.isReadingWorkspaceOpen)
        XCTAssertNil(model.selectedSpaceID)
    }

    func testLocalMarkdownImportCreatesReadableSpaceWithoutProvider() async throws {
        let root = temporaryRoot("Import")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("guide.md")
        try Data("# Guide\n\nEvidence-first reading.".utf8).write(to: sourceURL)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library"),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }

        model.importLocalURLs([sourceURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.spaces.count == 1 && model.presentationDocument != nil
        }
        try await waitUntil(timeout: .seconds(5)) {
            model.activePendingImportCount == 0
        }

        XCTAssertEqual(model.sources.count, 1)
        XCTAssertTrue(model.isReadingWorkspaceOpen)
        XCTAssertEqual(model.presentationDocument?.surface, .nativeMarkdown)
        XCTAssertNil(model.activeProvider)
        XCTAssertFalse(model.contentNodes.isEmpty)
        XCTAssertFalse(model.pendingImports.contains { $0.state.isActive })
        XCTAssertEqual(
            model.activity.filter { $0.phase == "建索引" && $0.state == .running }.count,
            1
        )
    }

    func testDirectoryImportOpensRepositoryReadmeBeforeIncidentalFiles() async throws {
        let root = temporaryRoot("DirectoryDefault")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Book", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try Data("license text".utf8).write(
            to: sourceURL.appendingPathComponent("LICENSE.md")
        )
        try Data("# Book overview\n\nStart here.".utf8).write(
            to: sourceURL.appendingPathComponent("README.md")
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library"),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }

        model.importLocalURLs([sourceURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.presentationDocument?.locator.relativePath == "README.md"
        }

        XCTAssertEqual(model.presentationDocument?.surface, .nativeMarkdown)
        XCTAssertEqual(model.presentationDocument?.locator.relativePath, "README.md")
    }

    func testReaderPreferencesPersistAcrossModelInstances() throws {
        let root = temporaryRoot("Preferences")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "OneReaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppModel(
            libraryRootURL: root,
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore(),
            automaticBootstrap: false
        )
        first.preferences.theme = .dark
        first.preferences.fontSize = 21
        first.preferences.pdfScale = 1.2

        let restored = AppModel(
            libraryRootURL: root,
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore(),
            automaticBootstrap: false
        )
        XCTAssertEqual(restored.preferences.theme, .dark)
        XCTAssertEqual(restored.preferences.fontSize, 21)
        XCTAssertEqual(restored.preferences.pdfScale, 1.2)
    }

    func testPlatformFileImportPurposeOnlyAllowsBatchSelectionForNewImports() {
        XCTAssertTrue(
            PlatformFileImportPurpose.add(.newSpace).allowsMultipleSelection
        )
        XCTAssertTrue(
            PlatformFileImportPurpose.add(.currentSpace).allowsMultipleSelection
        )
        XCTAssertFalse(
            PlatformFileImportPurpose.reauthorize(sourceID: "source-1")
                .allowsMultipleSelection
        )
    }

    func testMobileOriginalSourcePolicyExposesOnlyExplicitWebLinks() {
        XCTAssertTrue(
            OriginalSourceOpenPolicy.allows(
                URL(string: "https://example.com/book"),
                onMobile: true
            )
        )
        XCTAssertFalse(
            OriginalSourceOpenPolicy.allows(
                URL(fileURLWithPath: "/private/provider/book.pdf"),
                onMobile: true
            )
        )
        XCTAssertTrue(
            OriginalSourceOpenPolicy.allows(
                URL(fileURLWithPath: "/Users/reader/book.pdf"),
                onMobile: false
            )
        )
    }

    func testReadingPositionPersistsAndRestoresAcrossModelInstances() async throws {
        let root = temporaryRoot("PositionRestore")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("long-note.txt")
        let body = "Opening paragraph.\n\nA durable position lives here.\n\nClosing paragraph."
        try Data(body.utf8).write(to: sourceURL)
        let suite = "OneReaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let libraryRoot = root.appendingPathComponent("Library")
        let first = AppModel(
            libraryRootURL: libraryRoot,
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { first.isBootstrapComplete }
        first.importLocalURLs([sourceURL])
        try await waitUntil(timeout: .seconds(5)) {
            first.presentationDocument != nil && first.activePendingImportCount == 0
        }

        let document = try XCTUnwrap(first.presentationDocument)
        let sourceID = try XCTUnwrap(first.selectedSourceID)
        let snapshotID = try XCTUnwrap(first.selectedSnapshot?.id)
        let spaceID = try XCTUnwrap(first.selectedSpaceID)
        let text = body as NSString
        let match = text.range(of: "A durable position lives here.")
        XCTAssertNotEqual(match.location, NSNotFound)
        var payload = document.locator.payload
        payload["startUTF16"] = String(match.location)
        payload["endUTF16"] = String(NSMaxRange(match))
        payload["startLine"] = "3"
        payload["endLine"] = "3"
        let position = Locator(
            sourceID: sourceID,
            snapshotID: snapshotID,
            adapterID: document.locator.adapterID,
            payload: payload,
            structuralPath: document.locator.structuralPath,
            textQuote: TextQuote(
                prefix: "Opening paragraph.\n\n",
                exact: "A durable position lives here.",
                suffix: "\n\nClosing paragraph."
            ),
            fingerprint: AdapterUtilities.sha256("A durable position lives here.")
        )
        first.updateReadingPosition(
            ReadingPositionUpdate(
                locator: position,
                progressFraction: 0.46,
                granularity: .text,
                displayLabel: "第 3 行 · 46%"
            )
        )
        try await waitUntil(timeout: .seconds(2)) {
            first.currentProgress.sourcePositions[sourceID]?.locator == position
        }
        XCTAssertEqual(
            try XCTUnwrap(first.currentProgress.sourcePositions[sourceID]?.progressFraction),
            0.46,
            accuracy: 0.000_001
        )
        XCTAssertEqual(first.currentProgress.sourcePositions[sourceID]?.granularity, .text)
        XCTAssertEqual(first.currentProgress.sourcePositions[sourceID]?.displayLabel, "第 3 行 · 46%")
        XCTAssertEqual(first.progressFraction(for: spaceID), 0.46, accuracy: 0.000_001)

        let restored = AppModel(
            libraryRootURL: libraryRoot,
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { restored.isBootstrapComplete }
        restored.openSpace(spaceID)
        try await waitUntil(timeout: .seconds(5)) {
            restored.presentationDocument?.locator == position
        }

        XCTAssertEqual(restored.selectedSourceID, sourceID)
        XCTAssertEqual(restored.currentPositionLocator, position)
        XCTAssertEqual(restored.presentationDocument?.locator, position)
        XCTAssertEqual(
            try XCTUnwrap(restored.currentProgress.sourcePositions[sourceID]?.progressFraction),
            0.46,
            accuracy: 0.000_001
        )
        XCTAssertEqual(restored.currentProgress.sourcePositions[sourceID]?.granularity, .text)
        XCTAssertEqual(restored.currentPositionDescription, "第 3 行 · 46%")
        XCTAssertEqual(
            restored.resumeDescription(for: spaceID),
            "long-note.txt · 第 3 行 · 46%"
        )
    }

    func testPendingReadingPositionFlushesBeforeSourceSwitch() async throws {
        let root = temporaryRoot("PositionSourceSwitch")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstURL = root.appendingPathComponent("first.txt")
        let secondURL = root.appendingPathComponent("second.txt")
        try Data("first source\nposition".utf8).write(to: firstURL)
        try Data("second source\nposition".utf8).write(to: secondURL)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library"),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }
        model.importLocalURLs([firstURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.presentationDocument?.title == "first.txt" && model.activePendingImportCount == 0
        }
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        let firstSourceID = try XCTUnwrap(model.selectedSourceID)
        model.importLocalURLs([secondURL], destination: .currentSpace)
        try await waitUntil(timeout: .seconds(5)) {
            model.sources.count == 2 && model.activePendingImportCount == 0
        }
        model.openSource(firstSourceID)
        try await waitUntil { model.presentationDocument?.title == "first.txt" }
        let firstLocator = try XCTUnwrap(model.presentationDocument?.locator)
        model.updateReadingPosition(
            ReadingPositionUpdate(
                locator: firstLocator,
                progressFraction: 0.73,
                granularity: .text,
                displayLabel: "第 2 行 · 73%"
            )
        )

        let secondSourceID = try XCTUnwrap(
            model.sources.first(where: { $0.id != firstSourceID })?.id
        )
        model.openSource(secondSourceID)

        XCTAssertEqual(model.selectedSpaceID, spaceID)
        XCTAssertEqual(
            try XCTUnwrap(
                model.progressBySpace[spaceID]?.sourcePositions[firstSourceID]?.progressFraction
            ),
            0.73,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            model.progressBySpace[spaceID]?.sourcePositions[firstSourceID]?.displayLabel,
            "第 2 行 · 73%"
        )
    }

    func testLatePositionFromPreviousChildCannotOverwriteCurrentChild() async throws {
        let root = temporaryRoot("PositionChildGeneration")
        defer { try? FileManager.default.removeItem(at: root) }
        let directoryURL = root.appendingPathComponent("Book", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data("first child\nold position".utf8).write(
            to: directoryURL.appendingPathComponent("first.txt")
        )
        try Data("second child\ncurrent position".utf8).write(
            to: directoryURL.appendingPathComponent("second.txt")
        )
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)")
        )
        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library"),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }
        model.importLocalURLs([directoryURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.contentNodes.contains { $0.locator.relativePath == "first.txt" }
                && model.contentNodes.contains { $0.locator.relativePath == "second.txt" }
        }

        let firstNode = try XCTUnwrap(
            model.contentNodes.first { $0.locator.relativePath == "first.txt" }
        )
        let secondNode = try XCTUnwrap(
            model.contentNodes.first { $0.locator.relativePath == "second.txt" }
        )
        model.openNode(firstNode)
        try await waitUntil { model.presentationDocument?.locator.relativePath == "first.txt" }
        let firstToken = model.currentPresentationToken
        let firstLocator = try XCTUnwrap(model.presentationDocument?.locator)

        model.openNode(secondNode)
        try await waitUntil { model.presentationDocument?.locator.relativePath == "second.txt" }
        let secondToken = model.currentPresentationToken
        let secondLocator = try XCTUnwrap(model.presentationDocument?.locator)
        XCTAssertNotEqual(firstToken, secondToken)

        model.updateReadingPosition(
            ReadingPositionUpdate(
                locator: firstLocator,
                progressFraction: 0.91,
                granularity: .text,
                displayLabel: "first.txt · 第 2 行 · 91%"
            ),
            presentationToken: firstToken
        )
        model.flushReadingPosition()
        XCTAssertEqual(
            model.currentProgress.sourcePositions[secondLocator.sourceID]?.locator.relativePath,
            "second.txt"
        )

        model.updateReadingPosition(
            ReadingPositionUpdate(
                locator: secondLocator,
                progressFraction: 0.24,
                granularity: .text,
                displayLabel: "second.txt · 第 1 行 · 24%"
            ),
            presentationToken: secondToken
        )
        model.flushReadingPosition()
        let stored = try XCTUnwrap(
            model.currentProgress.sourcePositions[secondLocator.sourceID]
        )
        XCTAssertEqual(stored.locator.relativePath, "second.txt")
        XCTAssertEqual(try XCTUnwrap(stored.progressFraction), 0.24, accuracy: 0.000_001)
        XCTAssertEqual(stored.displayLabel, "second.txt · 第 1 行 · 24%")
    }

    func testExplicitPositionFlushPersistsWithoutWaitingForDebounce() async throws {
        let root = temporaryRoot("PositionLifecycleFlush")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("background.txt")
        try Data("background position".utf8).write(to: sourceURL)
        let suite = "OneReaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let libraryRoot = root.appendingPathComponent("Library")
        let model = AppModel(
            libraryRootURL: libraryRoot,
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }
        model.importLocalURLs([sourceURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.presentationDocument != nil && model.activePendingImportCount == 0
        }
        let locator = try XCTUnwrap(model.presentationDocument?.locator)
        let sourceID = locator.sourceID
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        model.updateReadingPosition(
            ReadingPositionUpdate(
                locator: locator,
                progressFraction: 0.31,
                granularity: .text,
                displayLabel: "第 1 行 · 31%"
            )
        )
        model.flushReadingPosition()

        let restored = AppModel(
            libraryRootURL: libraryRoot,
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { restored.isBootstrapComplete }
        restored.openSpace(spaceID)
        try await waitUntil { restored.presentationDocument != nil }

        XCTAssertEqual(
            try XCTUnwrap(restored.currentProgress.sourcePositions[sourceID]?.progressFraction),
            0.31,
            accuracy: 0.000_001
        )
        XCTAssertEqual(restored.currentProgress.sourcePositions[sourceID]?.displayLabel, "第 1 行 · 31%")
    }

    func testSeparateOpenEventsDoNotCancelEarlierImport() async throws {
        let root = temporaryRoot("OpenEvents")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstURL = root.appendingPathComponent("first.md")
        let secondURL = root.appendingPathComponent("second.md")
        try Data("# First\n\nfirst body".utf8).write(to: firstURL)
        try Data("# Second\n\nsecond body".utf8).write(to: secondURL)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library"),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }

        model.handleOpenURL(firstURL)
        model.handleOpenURL(secondURL)
        try await waitUntil(timeout: .seconds(5)) {
            model.sources.count == 2 && model.activePendingImportCount == 0
        }

        XCTAssertEqual(Set(model.sources.map(\.displayName)), ["first.md", "second.md"])
        XCTAssertEqual(model.spaces.count, 2)
    }

    func testSpaceSwitchCancelsAndClearsPreviousSearchPublication() async throws {
        let root = temporaryRoot("SpaceSearchIsolation")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstURL = root.appendingPathComponent("alpha.md")
        let secondURL = root.appendingPathComponent("beta.md")
        try Data("# Alpha\n\nunique-alpha-evidence".utf8).write(to: firstURL)
        try Data("# Beta\n\nunique-beta-evidence".utf8).write(to: secondURL)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library"),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }
        model.importLocalURLs([firstURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.activePendingImportCount == 0 && model.spaces.count == 1
        }
        let firstSpaceID = try XCTUnwrap(model.selectedSpaceID)
        model.importLocalURLs([secondURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.activePendingImportCount == 0 && model.spaces.count == 2
        }
        let secondSpaceID = try XCTUnwrap(model.selectedSpaceID)
        XCTAssertNotEqual(firstSpaceID, secondSpaceID)

        model.openSpace(firstSpaceID)
        try await waitUntil { model.presentationDocument?.title == "alpha.md" }
        model.searchScope = .space
        model.searchText = "unique-alpha-evidence"
        model.performSearch()
        model.openSpace(secondSpaceID)
        try await waitUntil { model.presentationDocument?.title == "beta.md" }
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(model.selectedSpaceID, secondSpaceID)
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.evidenceAnswer)
    }

    func testLocalRefreshKeepsSourceIdentityAndPersistsRelocatedAndOrphanedAnchors() async throws {
        let root = temporaryRoot("SourceRefresh")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("refresh.txt")
        let original = "Header\n\nstable quote\n\nremoved quote\n"
        try Data(original.utf8).write(to: sourceURL)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library"),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }
        model.importLocalURLs([sourceURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.presentationDocument != nil && model.activePendingImportCount == 0
        }
        let sourceID = try XCTUnwrap(model.selectedSourceID)
        let oldSnapshotID = try XCTUnwrap(model.selectedSnapshot?.id)
        let document = try XCTUnwrap(model.presentationDocument)

        let stable = anchoredLocator(
            document.locator,
            body: original,
            exact: "stable quote"
        )
        model.currentSelection = ReaderSelection(text: "stable quote", locator: stable)
        model.addHighlight()
        let removed = anchoredLocator(
            document.locator,
            body: original,
            exact: "removed quote"
        )
        model.currentSelection = ReaderSelection(text: "removed quote", locator: removed)
        model.addNote("This anchor should become orphaned")
        model.updateReadingPosition(
            ReadingPositionUpdate(
                locator: stable,
                progressFraction: 0.42,
                granularity: .text,
                displayLabel: "第 3 行 · 42%"
            )
        )
        XCTAssertEqual(model.annotations.count, 2)

        let revised = "Introduction\n\nThe stable quote moved into a revised paragraph.\n"
        try Data(revised.utf8).write(to: sourceURL, options: .atomic)
        let oldPresentationToken = model.currentPresentationToken
        model.refreshSource(sourceID)
        try await waitUntil(timeout: .seconds(8)) {
            !model.refreshingSourceIDs.contains(sourceID)
                && model.selectedSnapshot?.id != oldSnapshotID
        }
        model.updateReadingPosition(
            ReadingPositionUpdate(
                locator: stable,
                progressFraction: 0.99,
                granularity: .text,
                displayLabel: "迟到的旧版本位置"
            ),
            presentationToken: oldPresentationToken
        )
        try await Task.sleep(for: .milliseconds(450))

        let newSnapshotID = try XCTUnwrap(model.selectedSnapshot?.id)
        XCTAssertNotEqual(newSnapshotID, oldSnapshotID)
        XCTAssertEqual(model.sources.filter { $0.id == sourceID }.count, 1)
        XCTAssertEqual(model.snapshots.filter { $0.sourceID == sourceID }.count, 2)
        let stableAnnotation = try XCTUnwrap(
            model.annotations.first { $0.selectedText == "stable quote" }
        )
        let removedAnnotation = try XCTUnwrap(
            model.annotations.first { $0.selectedText == "removed quote" }
        )
        XCTAssertEqual(stableAnnotation.anchorState, .relocated)
        XCTAssertEqual(removedAnnotation.anchorState, .orphaned)
        XCTAssertEqual(stableAnnotation.locator.snapshotID, oldSnapshotID)
        XCTAssertEqual(removedAnnotation.locator.snapshotID, oldSnapshotID)
        XCTAssertEqual(
            model.currentProgress.sourcePositions[sourceID]?.locator.snapshotID,
            newSnapshotID
        )
        XCTAssertNil(model.currentProgress.sourcePositions[sourceID]?.progressFraction)
        XCTAssertNil(model.currentProgress.sourcePositions[sourceID]?.granularity)
        XCTAssertNil(model.currentProgress.sourcePositions[sourceID]?.displayLabel)
    }

    func testRefreshCommitFailureRestoresPreviousReadableSnapshot() async throws {
        let root = temporaryRoot("RefreshCommitRecovery")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("recover.txt")
        try Data("readable before refresh".utf8).write(to: sourceURL)
        let libraryRoot = root.appendingPathComponent("Library")
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)")
        )
        let model = AppModel(
            libraryRootURL: libraryRoot,
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }
        model.importLocalURLs([sourceURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.presentationDocument != nil && model.activePendingImportCount == 0
        }
        let sourceID = try XCTUnwrap(model.selectedSourceID)
        let oldSnapshotID = try XCTUnwrap(model.selectedSnapshot?.id)
        let database = try LibraryDatabase(rootURL: libraryRoot)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER reject_test_snapshot_refresh
                    BEFORE INSERT ON snapshots
                    BEGIN
                        SELECT RAISE(ABORT, 'injected refresh commit failure');
                    END
                    """
            )
        }

        try Data("changed bytes that cannot commit".utf8).write(to: sourceURL, options: .atomic)
        model.refreshSource(sourceID)
        try await waitUntil(timeout: .seconds(8)) {
            !model.refreshingSourceIDs.contains(sourceID)
                && model.presentationDocument?.locator.snapshotID == oldSnapshotID
        }

        XCTAssertEqual(model.selectedSnapshot?.id, oldSnapshotID)
        XCTAssertEqual(model.presentationDocument?.locator.snapshotID, oldSnapshotID)
        if case .loading = model.presentationState {
            XCTFail("A failed pre-commit refresh must not strand the reader in loading")
        }
    }

    func testRefreshPresentationFailureLeavesExplicitUnavailableState() async throws {
        let root = temporaryRoot("RefreshPresentationRecovery")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("unavailable.txt")
        try Data("readable before refresh".utf8).write(to: sourceURL)
        let libraryRoot = root.appendingPathComponent("Library")
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)")
        )
        let model = AppModel(
            libraryRootURL: libraryRoot,
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }
        model.importLocalURLs([sourceURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.presentationDocument != nil && model.activePendingImportCount == 0
        }
        let sourceID = try XCTUnwrap(model.selectedSourceID)
        let oldSnapshotID = try XCTUnwrap(model.selectedSnapshot?.id)
        let database = try LibraryDatabase(rootURL: libraryRoot)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER corrupt_test_snapshot_after_commit
                    AFTER INSERT ON snapshots
                    BEGIN
                        UPDATE snapshots
                        SET managed_relative_path = 'Sources/missing-refresh-presentation.txt'
                        WHERE id = NEW.id;
                    END
                    """
            )
        }

        try Data("committed bytes with missing presentation".utf8)
            .write(to: sourceURL, options: .atomic)
        model.refreshSource(sourceID)
        try await waitUntil(timeout: .seconds(8)) {
            guard !model.refreshingSourceIDs.contains(sourceID),
                  model.selectedSnapshot?.id != oldSnapshotID else { return false }
            if case .unavailable = model.presentationState { return true }
            return false
        }

        XCTAssertNotEqual(model.selectedSnapshot?.id, oldSnapshotID)
        if case .loading = model.presentationState {
            XCTFail("A failed post-commit presentation must not remain in loading")
        }
        if case .unavailable = model.presentationState {
            // Expected explicit recovery boundary.
        } else {
            XCTFail("Expected an explicit unavailable presentation after recovery fails")
        }
    }

    func testNewFrozenPlanRemainsPendingUntilExplicitProgressMigration() async throws {
        let root = temporaryRoot("FrozenPlan")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("book.md")
        try Data("# Book\n\nGrounded reading.".utf8).write(to: sourceURL)
        let libraryRoot = root.appendingPathComponent("Library")
        let database = try LibraryDatabase(rootURL: libraryRoot)
        let library = try ManagedLibrary(
            database: database,
            storagePolicy: LibraryStoragePolicy(
                largeImportThreshold: .max,
                minimumFreeCapacity: 0,
                capacityProvider: { _ in .max }
            )
        )
        let imported = try await library.importLocalSource(at: sourceURL)
        let locator = Locator(
            sourceID: imported.source.id,
            snapshotID: imported.snapshot.id,
            adapterID: MarkdownAdapter.id
        )
        let firstUnit = readingUnit(id: "unit-1", locator: locator)
        let secondUnit = readingUnit(id: "unit-2", locator: locator)
        let earlier = Date.now.addingTimeInterval(-60)
        let graph1 = ReadingGraph(
            id: "graph-1",
            version: "version-1",
            title: "Initial",
            sourceSnapshots: [imported.snapshot],
            units: [firstUnit],
            mapperID: "test",
            mapperVersion: "1",
            generatedAt: earlier
        )
        let plan1 = ReadingPlanDraft(
            id: "plan-1",
            schemaVersion: ReadingPlanDraft.currentSchemaVersion,
            graphID: graph1.id,
            graphVersion: graph1.version,
            goal: ReadingGoal.systematic.rawValue,
            orderedUnitIDs: [firstUnit.id],
            reasons: [firstUnit.id: "initial"],
            createdAt: earlier
        )
        let graph2 = ReadingGraph(
            id: "graph-2",
            version: "version-2",
            title: "Updated",
            sourceSnapshots: [imported.snapshot],
            units: [firstUnit, secondUnit],
            mapperID: "test",
            mapperVersion: "2",
            generatedAt: .now
        )
        let plan2 = ReadingPlanDraft(
            id: "plan-2",
            schemaVersion: ReadingPlanDraft.currentSchemaVersion,
            graphID: graph2.id,
            graphVersion: graph2.version,
            goal: ReadingGoal.review.rawValue,
            orderedUnitIDs: [secondUnit.id, firstUnit.id],
            reasons: [secondUnit.id: "new", firstUnit.id: "retained"],
            createdAt: .now
        )
        try database.saveReadingStructureForTesting(
            graph: graph1,
            plan: plan1,
            spaceID: imported.space.id
        )
        var progress = ReadingProgress.empty
        progress.graphVersion = graph1.version
        progress.units[firstUnit.id] = UnitProgress(
            unitID: firstUnit.id,
            state: .completed,
            fraction: 1,
            updatedAt: .now
        )
        try database.saveReadingProgress(progress, spaceID: imported.space.id)
        try database.saveReadingStructureForTesting(
            graph: graph2,
            plan: plan2,
            spaceID: imported.space.id
        )

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: libraryRoot,
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }
        model.openSpace(imported.space.id)
        try await waitUntil { model.currentGraph != nil }

        XCTAssertEqual(model.currentGraph?.version, graph1.version)
        XCTAssertEqual(model.currentPlan?.id, plan1.id)
        XCTAssertEqual(model.pendingPlan?.id, plan2.id)
        XCTAssertEqual(model.currentProgress.state(for: firstUnit.id), .completed)

        model.adoptPendingReadingPlan()

        XCTAssertEqual(model.currentGraph?.version, graph2.version)
        XCTAssertEqual(model.currentPlan?.id, plan2.id)
        XCTAssertNil(model.pendingPlan)
        XCTAssertEqual(model.currentProgress.graphVersion, graph2.version)
        XCTAssertEqual(model.currentProgress.state(for: firstUnit.id), .completed)
        XCTAssertEqual(model.currentProgress.currentPlanStepID, secondUnit.id)
    }

    func testQuickLookImportFinishesWithoutClaimingSearchIndex() async throws {
        let root = temporaryRoot("QuickLook")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("sample.unknown")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: sourceURL)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library"),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }

        model.importLocalURLs([sourceURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.presentationDocument?.surface == .quickLook
                && model.activePendingImportCount == 0
        }

        XCTAssertFalse(model.canSearchCurrentPresentation)
        XCTAssertFalse(model.canCreateHighlight)
        XCTAssertFalse(model.spaceSupportsSearch)
        XCTAssertFalse(model.spaceSupportsAgentEvidence)
        XCTAssertFalse(model.availableNavigationTabs.contains(.search))
        XCTAssertFalse(model.availableNavigationTabs.contains(.route))
        XCTAssertFalse(model.availableInspectorTabs.contains(.ask))
        XCTAssertFalse(model.availableInspectorTabs.contains(.evidence))
        XCTAssertFalse(model.activity.contains { $0.phase == "建索引" })
    }

    func testMixedQuickLookSpaceSkipsUnsupportedSourceDuringSearch() async throws {
        let root = temporaryRoot("MixedQuickLook")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let unknownURL = root.appendingPathComponent("sample.unknown")
        let markdownURL = root.appendingPathComponent("chapter.md")
        try Data([0x00, 0x01, 0x02]).write(to: unknownURL)
        try Data("# Chapter\n\nmixed-space-evidence".utf8).write(to: markdownURL)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library"),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }
        model.importLocalURLs([unknownURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.presentationDocument?.surface == .quickLook
                && model.activePendingImportCount == 0
        }
        model.importLocalURLs([markdownURL], destination: .currentSpace)
        try await waitUntil(timeout: .seconds(5)) {
            model.selectedSpaceSources.count == 2 && model.activePendingImportCount == 0
        }

        XCTAssertTrue(model.spaceSupportsSearch)
        XCTAssertTrue(model.spaceSupportsAgentEvidence)
        model.searchScope = .space
        model.searchText = "mixed-space-evidence"
        model.performSearch()
        try await waitUntil(timeout: .seconds(5)) {
            !model.isSearching && !model.searchResults.isEmpty
        }

        XCTAssertEqual(model.searchResults.count, 1)
        XCTAssertEqual(model.searchResults.first?.locator.textQuote?.exact, "mixed-space-evidence")
        XCTAssertNil(model.notice)
    }

    func testDismissingFirstRouteCandidateResumesAtNextSourceBeforeDownstreamTasks() async throws {
        let root = temporaryRoot("RouteCheckpoint")
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = root.appendingPathComponent("Inputs", isDirectory: true)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let firstURL = inputs.appendingPathComponent("first.md")
        let secondURL = inputs.appendingPathComponent("second.md")
        try Data("# First\n\nfirst evidence".utf8).write(to: firstURL)
        try Data("# Second\n\nsecond evidence".utf8).write(to: secondURL)

        let database = try LibraryDatabase(rootURL: libraryRoot)
        let library = try ManagedLibrary(
            database: database,
            storagePolicy: LibraryStoragePolicy(
                largeImportThreshold: .max,
                minimumFreeCapacity: 0,
                capacityProvider: { _ in .max }
            )
        )
        let first = try await library.importLocalSource(at: firstURL)
        let second = try await library.importLocalSource(
            at: secondURL,
            intoSpaceID: first.space.id
        )
        let coordinator = try AdapterCoordinator.standard(database: database)
        _ = try await coordinator.prepare(
            sourceID: first.source.id,
            snapshotID: first.snapshot.id
        )
        _ = try await coordinator.prepare(
            sourceID: second.source.id,
            snapshotID: second.snapshot.id
        )
        let orderedSourceIDs = [first.source.id, second.source.id].sorted()
        let pausedSourceID = orderedSourceIDs[0]
        let remainingSourceID = orderedSourceIDs[1]
        let remainingQuery = remainingSourceID == first.source.id ? "first" : "second"
        try database.saveProviderProfile(ProviderProfile(
            id: "app-pipeline-provider",
            displayName: "App pipeline fake",
            kind: .appleOnDevice,
            modelID: "fake-on-device",
            isDefault: true,
            capabilities: [.connection, .structuredGeneration, .toolCalling],
            lastTestedAt: .now,
            lastTestSucceeded: true
        ))

        let trace = AppPipelineTrace()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: libraryRoot,
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore(),
            agentDriverFactory: AppPipelineDriverFactory(
                pausedSourceID: pausedSourceID,
                trace: trace
            )
        )
        try await waitUntil { model.isBootstrapComplete }
        model.openSpace(first.space.id)
        try await waitUntil(timeout: .seconds(5)) {
            model.presentationDocument != nil && model.activeProvider != nil
        }

        model.launchAgentPipeline()
        try await waitUntil(timeout: .seconds(5)) {
            model.waitingAgentAttentionKind == .adapterCandidate
        }
        model.dismissWaitingAgentRun()
        try await waitUntil(timeout: .seconds(5)) {
            model.agentRuns.contains {
                $0.task == .materializeGraph && $0.state == .failed
            }
        }

        let records = await trace.records()
        XCTAssertGreaterThanOrEqual(records.count, 4)
        XCTAssertEqual(records[0], .init(task: .routeAdapters, targetSourceID: pausedSourceID))
        XCTAssertEqual(records[1], .init(task: .routeAdapters, targetSourceID: remainingSourceID))
        XCTAssertEqual(records[2], .init(task: .scoutSpace, targetSourceID: nil))
        XCTAssertEqual(records[3], .init(task: .materializeGraph, targetSourceID: nil))
        let remainingSnapshotID = try XCTUnwrap(
            [first.source.id: first.snapshot.id, second.source.id: second.snapshot.id][remainingSourceID]
        )
        try await waitUntil(timeout: .seconds(5)) {
            guard let plan = try? database.fetchAdapterPlan(snapshotID: remainingSnapshotID) else {
                return false
            }
            return (try? database.isObservationIndexComplete(
                snapshotID: remainingSnapshotID,
                planID: plan.id
            )) == true
        }
        let installed = try XCTUnwrap(
            database.fetchAdapterPlan(snapshotID: remainingSnapshotID)
        )
        XCTAssertTrue(installed.id.hasPrefix("agent-adapter-plan:"))
        XCTAssertEqual(
            try database.searchObservations(
                query: remainingQuery,
                snapshotID: remainingSnapshotID,
                planID: installed.id
            ).count,
            1
        )
    }

    func testRemoteDisclosureAnswerResumeDoesNotLaunchReadingStructurePipeline() async throws {
        let root = temporaryRoot("DisclosureAnswerResume")
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = InMemoryProviderSecretStore()
        let fixture = try await makeAnswerFixture(
            root: root,
            providerKind: .openAIResponses,
            secretStore: secrets
        )
        let trace = AppPipelineTrace()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: fixture.libraryRoot,
            defaults: defaults,
            secretStore: secrets,
            agentDriverFactory: AnswerOnlyDriverFactory(
                answer: fixture.answer,
                trace: trace
            )
        )
        try await waitUntil { model.isBootstrapComplete }
        model.openSpace(fixture.imported.space.id)
        try await waitUntil(timeout: .seconds(5)) {
            model.presentationDocument != nil && model.activeProvider != nil
        }

        model.askAgent("What is the evidence?")
        try await waitUntil(timeout: .seconds(5)) {
            model.waitingAgentAttentionKind == .disclosure
        }
        model.confirmWaitingAgentRun()
        try await waitUntil(timeout: .seconds(5)) {
            model.evidenceAnswer == fixture.answer
        }
        try await Task.sleep(for: .milliseconds(150))

        let records = await trace.records()
        XCTAssertEqual(
            records,
            [.init(task: .answerWithEvidence, targetSourceID: nil)]
        )
        XCTAssertTrue(model.agentRuns.allSatisfy { $0.task == .answerWithEvidence })
    }

    func testInterruptedAnswerResumeDoesNotLaunchReadingStructurePipeline() async throws {
        let root = temporaryRoot("InterruptedAnswerResume")
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = InMemoryProviderSecretStore()
        let fixture = try await makeAnswerFixture(
            root: root,
            providerKind: .appleOnDevice,
            secretStore: secrets
        )
        let interruptedRunID = try createInterruptedAnswerRun(fixture: fixture)
        let trace = AppPipelineTrace()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: fixture.libraryRoot,
            defaults: defaults,
            secretStore: secrets,
            agentDriverFactory: AnswerOnlyDriverFactory(
                answer: fixture.answer,
                trace: trace
            )
        )
        try await waitUntil { model.isBootstrapComplete }
        model.openSpace(fixture.imported.space.id)
        try await waitUntil(timeout: .seconds(5)) {
            model.waitingAgentRun?.id == interruptedRunID
                && model.waitingAgentAttentionKind == .interrupted
        }

        model.confirmWaitingAgentRun()
        try await waitUntil(timeout: .seconds(5)) {
            model.evidenceAnswer == fixture.answer
        }
        try await Task.sleep(for: .milliseconds(150))

        let records = await trace.records()
        XCTAssertEqual(
            records,
            [.init(task: .answerWithEvidence, targetSourceID: nil)]
        )
        XCTAssertTrue(model.agentRuns.allSatisfy { $0.task == .answerWithEvidence })
    }

    func testAbandonInterruptedRunClearsInspectorAttention() async throws {
        let root = temporaryRoot("AbandonInterrupted")
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = InMemoryProviderSecretStore()
        let fixture = try await makeAnswerFixture(
            root: root,
            providerKind: .appleOnDevice,
            secretStore: secrets
        )
        let interruptedRunID = try createInterruptedAnswerRun(fixture: fixture)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: fixture.libraryRoot,
            defaults: defaults,
            secretStore: secrets,
            agentDriverFactory: AnswerOnlyDriverFactory(
                answer: fixture.answer,
                trace: AppPipelineTrace()
            )
        )
        try await waitUntil { model.isBootstrapComplete }
        model.openSpace(fixture.imported.space.id)
        try await waitUntil(timeout: .seconds(5)) {
            model.waitingAgentRun?.id == interruptedRunID
        }

        model.abandonInterruptedAgentRun()
        try await waitUntil(timeout: .seconds(5)) {
            model.waitingAgentRun == nil
        }

        let abandoned = try XCTUnwrap(
            fixture.database.fetchAgentRuns().first { $0.id == interruptedRunID }
        )
        XCTAssertEqual(abandoned.state, .cancelled)
        XCTAssertEqual(abandoned.errorCategory, "user-abandoned")
    }

    func testProviderProfileMutationRefreshesInterruptedRunAttentionCache() async throws {
        let root = temporaryRoot("ProviderMutationAttention")
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = InMemoryProviderSecretStore()
        let fixture = try await makeAnswerFixture(
            root: root,
            providerKind: .appleOnDevice,
            secretStore: secrets
        )
        let interruptedRunID = try createInterruptedAnswerRun(fixture: fixture)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: fixture.libraryRoot,
            defaults: defaults,
            secretStore: secrets,
            agentDriverFactory: AnswerOnlyDriverFactory(
                answer: fixture.answer,
                trace: AppPipelineTrace()
            )
        )
        try await waitUntil { model.isBootstrapComplete }
        model.openSpace(fixture.imported.space.id)
        try await waitUntil(timeout: .seconds(5)) {
            model.waitingAgentRun?.id == interruptedRunID
        }

        var revised = fixture.profile
        revised.modelID = "answer-test-model-revised"
        revised.updatedAt = .now
        model.saveProviderProfile(revised, secret: nil)

        try await waitUntil(timeout: .seconds(5)) {
            model.waitingAgentRun == nil
        }
        let invalidated = try XCTUnwrap(
            fixture.database.fetchAgentRuns().first { $0.id == interruptedRunID }
        )
        XCTAssertEqual(invalidated.state, .cancelled)
        XCTAssertEqual(invalidated.errorCategory, "provider-configuration-changed")
        XCTAssertFalse(model.agentRuns.contains {
            $0.id == interruptedRunID && $0.state == .interrupted
        })
    }

    func testInterruptedScoutAndMaterializeResumeFromTheirNextPipelinePhase() async throws {
        for interruptedTask in [AgentTaskKind.scoutSpace, .materializeGraph] {
            let root = temporaryRoot("PipelineResume-\(interruptedTask.rawValue)")
            defer { try? FileManager.default.removeItem(at: root) }
            let secrets = InMemoryProviderSecretStore()
            let fixture = try await makeAnswerFixture(
                root: root,
                providerKind: .appleOnDevice,
                secretStore: secrets
            )
            let interruptedRunID = try createInterruptedRun(
                fixture: fixture,
                task: interruptedTask,
                pipeline: .readingStructure
            )
            let locator = try XCTUnwrap(fixture.answer.citations.first?.locator)
            let patch = GraphPatch(
                id: "pipeline-patch-\(interruptedTask.rawValue)",
                schemaVersion: GraphPatch.currentSchemaVersion,
                graphID: "pipeline-graph-\(interruptedTask.rawValue)",
                baseGraphVersion: nil,
                snapshotIDs: [fixture.imported.snapshot.id],
                upsertUnits: [readingUnit(
                    id: "pipeline-unit-\(interruptedTask.rawValue)",
                    locator: locator
                )],
                removeUnitIDs: [],
                generatedAt: .now
            )
            let trace = AppPipelineTrace()
            let defaults = try XCTUnwrap(
                UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)")
            )
            let model = AppModel(
                libraryRootURL: fixture.libraryRoot,
                defaults: defaults,
                secretStore: secrets,
                agentDriverFactory: PipelineContinuationDriverFactory(
                    patch: patch,
                    trace: trace
                )
            )
            try await waitUntil { model.isBootstrapComplete }
            model.openSpace(fixture.imported.space.id)
            try await waitUntil(timeout: .seconds(5)) {
                model.waitingAgentRun?.id == interruptedRunID
            }

            model.confirmWaitingAgentRun()
            try await waitUntil(timeout: .seconds(5)) {
                model.agentRuns.contains {
                    $0.task == .projectRoute && $0.state == .failed
                }
            }

            let records = await trace.records().map(\.task)
            switch interruptedTask {
            case .scoutSpace:
                XCTAssertEqual(records, [.scoutSpace, .materializeGraph, .projectRoute])
            case .materializeGraph:
                XCTAssertEqual(records, [.materializeGraph, .projectRoute])
            case .routeAdapters, .projectRoute, .answerWithEvidence:
                XCTFail("Unexpected fixture task")
            }
        }
    }

    func testV8MigrationRebuildsLibrarySearchWithoutOpeningSpace() async throws {
        let root = temporaryRoot("V8SearchRebuild")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepareVersion8SearchFixture(
            libraryRoot: root.appendingPathComponent("Library", isDirectory: true)
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: fixture.libraryRoot,
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil(timeout: .seconds(5)) { model.isBootstrapComplete }
        XCTAssertFalse(model.isReadingWorkspaceOpen)
        XCTAssertNil(model.selectedSpaceID)

        let observer = try DatabasePool(path: fixture.databaseURL.path)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        var isComplete = false
        while !isComplete, clock.now < deadline {
            isComplete = try await observer.read { db in
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM observation_index_runs
                            WHERE snapshot_id = ? AND plan_id = ? AND state = 'completed'
                        )
                        """,
                    arguments: [fixture.snapshotID, fixture.planID]
                ) ?? false
            }
            if !isComplete { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(isComplete, "Bootstrap should rebuild every active v8 plan")
        try observer.close()

        let verification = try LibraryDatabase(rootURL: fixture.libraryRoot)
        XCTAssertEqual(try verification.schemaMetadata()["database_schema"], "9")
        XCTAssertEqual(
            try verification.searchObservations(query: "migration-evidence").count,
            1
        )
        XCTAssertTrue(try verification.adapterPlansRequiringSearchIndex().isEmpty)
    }

    func testInvalidLibraryRootFailsClosedAndPreservesUnrelatedFile() async throws {
        let root = temporaryRoot("Invalid")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidRoot = root.appendingPathComponent("blocked")
        let original = Data("do-not-overwrite".utf8)
        try original.write(to: invalidRoot)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(libraryRootURL: invalidRoot, defaults: defaults)

        try await waitUntil { model.isBootstrapComplete }

        XCTAssertNotNil(model.notice)
        XCTAssertTrue(model.spaces.isEmpty)
        XCTAssertEqual(try Data(contentsOf: invalidRoot), original)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Condition did not become true before timeout")
    }

    private func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OneReaderAppModel-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeAnswerFixture(
        root: URL,
        providerKind: ProviderKind,
        secretStore: InMemoryProviderSecretStore
    ) async throws -> AppAnswerFixture {
        let inputs = root.appendingPathComponent("Inputs", isDirectory: true)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let input = inputs.appendingPathComponent("answer.md")
        try Data("# Session\n\nEvidence.\n".utf8).write(to: input)
        let database = try LibraryDatabase(rootURL: libraryRoot)
        let library = try ManagedLibrary(
            database: database,
            storagePolicy: LibraryStoragePolicy(
                largeImportThreshold: .max,
                minimumFreeCapacity: 0,
                capacityProvider: { _ in .max }
            )
        )
        let imported = try await library.importLocalSource(at: input)
        let coordinator = try AdapterCoordinator.standard(database: database)
        let plan = try await coordinator.prepare(
            sourceID: imported.source.id,
            snapshotID: imported.snapshot.id
        )
        let nodes = try await coordinator.list(plan: plan)
        let node = try XCTUnwrap(nodes.first)
        var rootPayload = node.locator.payload
        rootPayload["startLine"] = nil
        rootPayload["endLine"] = nil
        rootPayload["headingLevel"] = nil
        let rootLocator = Locator(
            sourceID: node.locator.sourceID,
            snapshotID: node.locator.snapshotID,
            adapterID: node.locator.adapterID,
            payload: rootPayload
        )
        let observation = try await coordinator.read(plan: plan, locator: rootLocator)
        XCTAssertTrue(observation.content.contains("Evidence."))
        let reference: String?
        if providerKind.requiresSecret {
            reference = await secretStore.save(secret: "test-secret", reference: nil)
        } else {
            reference = nil
        }
        let profile = ProviderProfile(
            displayName: "Answer test provider",
            kind: providerKind,
            endpoint: providerKind == .openAIResponses
                ? URL(string: "https://example.invalid/v1")
                : nil,
            modelID: "answer-test-model",
            keychainReference: reference,
            isDefault: true,
            capabilities: [.connection, .structuredGeneration, .toolCalling],
            lastTestedAt: .now,
            lastTestSucceeded: true
        )
        try database.saveProviderProfile(profile)
        let answer = EvidenceAnswer(
            schemaVersion: EvidenceAnswer.currentSchemaVersion,
            answer: "The source contains grounded evidence.",
            citations: [EvidenceCitation(
                id: "answer-citation",
                fragmentID: nil,
                sourceID: imported.source.id,
                snapshotID: imported.snapshot.id,
                locator: observation.locator,
                quote: "Evidence."
            )],
            limitations: []
        )
        return AppAnswerFixture(
            libraryRoot: libraryRoot,
            database: database,
            imported: imported,
            profile: profile,
            answer: answer
        )
    }

    private func createInterruptedAnswerRun(fixture: AppAnswerFixture) throws -> String {
        try createInterruptedRun(
            fixture: fixture,
            task: .answerWithEvidence,
            pipeline: nil,
            question: "What is the evidence?"
        )
    }

    private func createInterruptedRun(
        fixture: AppAnswerFixture,
        task: AgentTaskKind,
        pipeline: AgentPipelineKind?,
        question: String? = nil
    ) throws -> String {
        let manifest = try fixture.database.currentSnapshotManifest(
            spaceID: fixture.imported.space.id
        )
        let request = AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: task,
            pipeline: pipeline,
            question: question,
            expectedSnapshotIDs: Set(manifest.values),
            snapshotManifest: manifest
        )
        let run = AgentRun(
            id: UUID().uuidString.lowercased(),
            spaceID: request.spaceID,
            task: request.task,
            generation: 1,
            state: .queued,
            providerProfileID: fixture.profile.id,
            providerDestinationIdentity: try ProviderPolicy.destinationIdentity(fixture.profile),
            providerRevisionIdentity: try ProviderPolicy.revisionIdentity(fixture.profile),
            createdAt: .now,
            startedAt: nil,
            finishedAt: nil,
            errorCategory: nil
        )
        try fixture.database.beginAgentRun(run, request: request)
        try fixture.database.markAgentRunRunningCAS(
            id: run.id,
            spaceID: run.spaceID,
            generation: run.generation
        )
        return run.id
    }

    private func prepareVersion8SearchFixture(
        libraryRoot: URL
    ) throws -> AppV8SearchFixture {
        let layout = ApplicationSupportLayout(rootURL: libraryRoot)
        try layout.prepare()
        let managedDirectory = layout.sourcesURL
            .appendingPathComponent("legacy-v8", isDirectory: true)
        try FileManager.default.createDirectory(
            at: managedDirectory,
            withIntermediateDirectories: true
        )
        let managedURL = managedDirectory.appendingPathComponent("payload")
        let body = "# migration-evidence\n\nLegacy content remains globally searchable.\n"
        let bodyData = Data(body.utf8)
        try bodyData.write(to: managedURL)
        let digest = AdapterUtilities.sha256(bodyData)
        let sourceID = "source-v8-search"
        let snapshotID = "snapshot-v8-search"
        let spaceID = "space-v8-search"
        let planID = "plan-v8-search"
        let plan = AdapterPlan(
            id: planID,
            schemaVersion: AdapterPlan.currentSchemaVersion,
            sourceID: sourceID,
            snapshotID: snapshotID,
            primaryAdapterID: MarkdownAdapter.id,
            auxiliaryAdapterIDs: [],
            capabilityRoutes: Dictionary(
                uniqueKeysWithValues: AdapterCapability.allCases.map { ($0, MarkdownAdapter.id) }
            ),
            evidence: [ProbeEvidence(
                id: "v8-markdown-probe",
                adapterID: MarkdownAdapter.id,
                rule: "fixture",
                detail: "Version 8 migration fixture",
                confidence: 1
            )],
            confidence: 1,
            reason: "Version 8 active search plan",
            isUserOverride: false,
            createdAt: .now
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let planJSON = try encoder.encode(plan)
        let locator = Locator(
            sourceID: sourceID,
            snapshotID: snapshotID,
            adapterID: MarkdownAdapter.id,
            payload: ["path": "legacy.md"]
        )
        let locatorJSON = try encoder.encode(locator)
        let pool = try DatabasePool(path: layout.databaseURL.path)
        try LibraryDatabase.makeMigrator().migrate(
            pool,
            upTo: "v8-source-access-bookmarks"
        )
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sources
                        (id, display_name, origin_kind, origin_url, managed_state,
                         latest_snapshot_id, created_at, updated_at)
                    VALUES (?, 'legacy.md', 'localFile', NULL, 'ready', ?, ?, ?)
                    """,
                arguments: [sourceID, snapshotID, Date.now, Date.now]
            )
            try db.execute(
                sql: """
                    INSERT INTO snapshots
                        (id, source_id, revision_kind, revision, digest, origin_url,
                         managed_relative_path, byte_count, created_at)
                    VALUES (?, ?, 'contentDigest', ?, ?, NULL, ?, ?, ?)
                    """,
                arguments: [
                    snapshotID,
                    sourceID,
                    digest,
                    digest,
                    try layout.relativePath(for: managedURL),
                    bodyData.count,
                    Date.now,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO reading_spaces
                        (id, title, is_favorite, created_at, updated_at)
                    VALUES (?, 'Legacy library', 0, ?, ?)
                    """,
                arguments: [spaceID, Date.now, Date.now]
            )
            try db.execute(
                sql: """
                    INSERT INTO space_sources (space_id, source_id, position, added_at)
                    VALUES (?, ?, 0, ?)
                    """,
                arguments: [spaceID, sourceID, Date.now]
            )
            try db.execute(
                sql: """
                    INSERT INTO adapter_plans
                        (id, source_id, snapshot_id, schema_version, payload_json,
                         confidence, is_user_override, created_at)
                    VALUES (?, ?, ?, ?, ?, 1, 0, ?)
                    """,
                arguments: [
                    planID,
                    sourceID,
                    snapshotID,
                    plan.schemaVersion,
                    planJSON,
                    plan.createdAt,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO observations
                        (id, source_id, snapshot_id, adapter_id, locator_json,
                         media_type, title, body, digest, truncated, created_at)
                    VALUES ('observation-v8-search', ?, ?, ?, ?, 'text/markdown',
                            'legacy.md', ?, ?, 0, ?)
                    """,
                arguments: [
                    sourceID,
                    snapshotID,
                    MarkdownAdapter.id,
                    locatorJSON,
                    body,
                    digest,
                    Date.now,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO observation_fts
                        (observation_id, source_id, snapshot_id, title, body)
                    VALUES ('observation-v8-search', ?, ?, 'legacy.md', ?)
                    """,
                arguments: [sourceID, snapshotID, body]
            )
        }
        XCTAssertEqual(try pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM library_metadata WHERE key = 'database_schema'"
            )
        }, "8")
        try pool.close()
        return AppV8SearchFixture(
            libraryRoot: libraryRoot,
            databaseURL: layout.databaseURL,
            snapshotID: snapshotID,
            planID: planID
        )
    }

    private func anchoredLocator(
        _ root: Locator,
        body: String,
        exact: String
    ) -> Locator {
        let range = body.range(of: exact)!
        let utf16 = NSRange(range, in: body)
        var payload = root.payload
        payload["startUTF16"] = String(utf16.location)
        payload["endUTF16"] = String(NSMaxRange(utf16))
        payload["startLine"] = String(body[..<range.lowerBound].reduce(1) {
            $1 == "\n" ? $0 + 1 : $0
        })
        return Locator(
            sourceID: root.sourceID,
            snapshotID: root.snapshotID,
            adapterID: root.adapterID,
            payload: payload,
            structuralPath: root.structuralPath,
            textQuote: TextQuote(prefix: nil, exact: exact, suffix: nil),
            fingerprint: AdapterUtilities.sha256(exact)
        )
    }

    private func readingUnit(id: String, locator: Locator) -> ReadingUnit {
        ReadingUnit(
            id: id,
            title: id,
            summary: "summary",
            fragments: [SourceFragment(
                id: "fragment-\(id)",
                sourceID: locator.sourceID,
                locator: locator,
                role: .evidence,
                label: id
            )],
            relations: [],
            estimatedMinutes: 5,
            importance: 0.8,
            confidence: 0.9,
            sourceOrder: 0,
            preferredPresentation: .markdown
        )
    }
}

private struct AppAnswerFixture {
    let libraryRoot: URL
    let database: LibraryDatabase
    let imported: ManagedImportResult
    let profile: ProviderProfile
    let answer: EvidenceAnswer
}

private struct AppV8SearchFixture {
    let libraryRoot: URL
    let databaseURL: URL
    let snapshotID: String
    let planID: String
}

private actor AppPipelineTrace {
    struct Record: Equatable, Sendable {
        let task: AgentTaskKind
        let targetSourceID: String?
    }

    private var values: [Record] = []

    func append(_ record: Record) {
        values.append(record)
    }

    func records() -> [Record] { values }
}

private struct AnswerOnlyDriverFactory: ReadingAgentDriverFactory {
    let answer: EvidenceAnswer
    let trace: AppPipelineTrace

    func makeDriver(context: AgentDriverContext) -> any ReadingAgentModelDriver {
        AnswerOnlyDriver(context: context, answer: answer, trace: trace)
    }
}

private struct AnswerOnlyDriver: ReadingAgentModelDriver {
    let context: AgentDriverContext
    let answer: EvidenceAnswer
    let trace: AppPipelineTrace

    func generate(
        _ request: AgentModelRequest,
        runtime: ReadingToolRuntime,
        previousTranscript: Data?
    ) async throws -> AgentModelResult {
        _ = try await context.budget.consumeModelRound()
        await trace.append(.init(
            task: request.request.task,
            targetSourceID: request.request.targetSourceID
        ))
        guard request.request.task == .answerWithEvidence else {
            throw ReadingAgentError.providerUnavailable(
                "answer-test-unexpected-\(request.request.task.rawValue)"
            )
        }
        return AgentModelResult(output: .evidenceAnswer(answer), usage: nil)
    }
}

private struct PipelineContinuationDriverFactory: ReadingAgentDriverFactory {
    let patch: GraphPatch
    let trace: AppPipelineTrace

    func makeDriver(context: AgentDriverContext) -> any ReadingAgentModelDriver {
        PipelineContinuationDriver(context: context, patch: patch, trace: trace)
    }
}

private struct PipelineContinuationDriver: ReadingAgentModelDriver {
    let context: AgentDriverContext
    let patch: GraphPatch
    let trace: AppPipelineTrace

    func generate(
        _ request: AgentModelRequest,
        runtime: ReadingToolRuntime,
        previousTranscript: Data?
    ) async throws -> AgentModelResult {
        _ = try await context.budget.consumeModelRound()
        await trace.append(.init(
            task: request.request.task,
            targetSourceID: request.request.targetSourceID
        ))
        switch request.request.task {
        case .scoutSpace:
            return AgentModelResult(
                output: .scoutingSummary("The persisted pipeline scout is complete."),
                usage: nil
            )
        case .materializeGraph:
            return AgentModelResult(output: .graphPatch(patch), usage: nil)
        case .projectRoute:
            throw ReadingAgentError.providerUnavailable("pipeline-resume-test-stop")
        case .routeAdapters, .answerWithEvidence:
            throw ReadingAgentError.providerUnavailable(
                "pipeline-resume-unexpected-\(request.request.task.rawValue)"
            )
        }
    }
}

private struct AppPipelineDriverFactory: ReadingAgentDriverFactory {
    let pausedSourceID: String
    let trace: AppPipelineTrace

    func makeDriver(context: AgentDriverContext) -> any ReadingAgentModelDriver {
        AppPipelineDriver(
            context: context,
            pausedSourceID: pausedSourceID,
            trace: trace
        )
    }
}

private struct AppPipelineDriver: ReadingAgentModelDriver {
    let context: AgentDriverContext
    let pausedSourceID: String
    let trace: AppPipelineTrace

    func generate(
        _ request: AgentModelRequest,
        runtime: ReadingToolRuntime,
        previousTranscript: Data?
    ) async throws -> AgentModelResult {
        _ = try await context.budget.consumeModelRound()
        await trace.append(.init(
            task: request.request.task,
            targetSourceID: request.request.targetSourceID
        ))
        switch request.request.task {
        case .routeAdapters:
            guard let sourceID = request.request.targetSourceID,
                  let snapshotID = request.request.targetSnapshotID,
                  let base = try context.database.fetchAdapterPlan(snapshotID: snapshotID) else {
                throw ReadingAgentError.validationRejected("pipeline-test-plan-missing")
            }
            let proposed: AdapterPlan
            if sourceID == pausedSourceID {
                let fallback = QuickLookAdapter.id
                let auxiliary = Array(
                    Set(base.auxiliaryAdapterIDs + [base.primaryAdapterID])
                        .subtracting([fallback])
                ).sorted()
                proposed = AdapterPlan(
                    id: "pipeline-low-candidate",
                    schemaVersion: base.schemaVersion,
                    sourceID: sourceID,
                    snapshotID: snapshotID,
                    primaryAdapterID: fallback,
                    auxiliaryAdapterIDs: auxiliary,
                    capabilityRoutes: base.capabilityRoutes,
                    evidence: base.evidence,
                    confidence: 0.99,
                    reason: "Pause the first source for explicit confirmation",
                    isUserOverride: false,
                    createdAt: .now
                )
            } else {
                proposed = AdapterPlan(
                    id: "pipeline-high-\(sourceID)",
                    schemaVersion: base.schemaVersion,
                    sourceID: sourceID,
                    snapshotID: snapshotID,
                    primaryAdapterID: base.primaryAdapterID,
                    auxiliaryAdapterIDs: base.auxiliaryAdapterIDs,
                    capabilityRoutes: base.capabilityRoutes,
                    evidence: base.evidence,
                    confidence: base.confidence,
                    reason: "Adopt the grounded deterministic composition",
                    isUserOverride: false,
                    createdAt: .now
                )
            }
            return AgentModelResult(output: .adapterPlan(proposed), usage: nil)
        case .scoutSpace:
            return AgentModelResult(
                output: .scoutingSummary("Both routed sources remain readable."),
                usage: nil
            )
        case .materializeGraph:
            throw ReadingAgentError.providerUnavailable("pipeline-test-stop")
        case .projectRoute, .answerWithEvidence:
            throw ReadingAgentError.providerUnavailable("pipeline-test-unexpected-task")
        }
    }
}
