import Foundation
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
        first.updateReadingPosition(position)
        try await waitUntil(timeout: .seconds(2)) {
            first.currentProgress.sourcePositions[sourceID]?.locator == position
        }

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
        model.updateReadingPosition(stable)
        try await waitUntil {
            model.currentProgress.sourcePositions[sourceID]?.locator == stable
        }
        XCTAssertEqual(model.annotations.count, 2)

        let revised = "Introduction\n\nThe stable quote moved into a revised paragraph.\n"
        try Data(revised.utf8).write(to: sourceURL, options: .atomic)
        model.refreshSource(sourceID)
        try await waitUntil(timeout: .seconds(8)) {
            !model.refreshingSourceIDs.contains(sourceID)
                && model.selectedSnapshot?.id != oldSnapshotID
        }

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
