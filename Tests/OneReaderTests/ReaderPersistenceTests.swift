import Foundation
import XCTest
@testable import OneReader

final class ReaderPersistenceTests: XCTestCase {
    func testAnnotationProgressAndHistoryRoundTrip() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let nodes = try await fixture.coordinator.list(plan: fixture.plan)
        let locator = try XCTUnwrap(nodes.first?.locator)
        let annotation = Annotation(
            id: "annotation-1",
            spaceID: fixture.imported.space.id,
            sourceID: fixture.imported.source.id,
            snapshotID: fixture.imported.snapshot.id,
            kind: .highlight,
            locator: Locator(
                sourceID: locator.sourceID,
                snapshotID: locator.snapshotID,
                adapterID: locator.adapterID,
                payload: locator.payload,
                structuralPath: locator.structuralPath,
                textQuote: TextQuote(prefix: nil, exact: "evidence", suffix: nil),
                fingerprint: "quote-digest"
            ),
            anchorState: .current,
            selectedText: "evidence",
            note: "grounded",
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )
        try fixture.database.saveAnnotation(annotation)

        var progress = ReadingProgress.empty
        progress.currentUnitID = "unit-1"
        progress.currentPlanStepID = "unit-1"
        progress.units["unit-1"] = UnitProgress(
            unitID: "unit-1",
            state: .completed,
            fraction: 1,
            updatedAt: .now
        )
        progress.sourcePositions[locator.sourceID] = SourcePosition(
            sourceID: locator.sourceID,
            locator: locator,
            updatedAt: .now,
            progressFraction: 0.625,
            granularity: .text,
            displayLabel: "README.md · 第 25 行 · 62%"
        )
        try fixture.database.saveReadingProgress(
            progress,
            spaceID: fixture.imported.space.id
        )
        let history = ReadingHistoryEntry(
            id: "history-1",
            spaceID: fixture.imported.space.id,
            sourceID: locator.sourceID,
            snapshotID: locator.snapshotID,
            locator: locator
        )
        try fixture.database.recordReadingHistory(history)

        let storedAnnotations = try fixture.database.fetchAnnotations(
            spaceID: fixture.imported.space.id
        )
        XCTAssertEqual(storedAnnotations.map(\.id), [annotation.id])
        XCTAssertEqual(storedAnnotations.first?.locator, annotation.locator)
        XCTAssertEqual(storedAnnotations.first?.selectedText, "evidence")

        let storedProgress = try fixture.database.fetchReadingProgress(
            spaceID: fixture.imported.space.id
        )
        XCTAssertEqual(storedProgress.currentPlanStepID, "unit-1")
        XCTAssertEqual(storedProgress.state(for: "unit-1"), .completed)
        XCTAssertEqual(
            storedProgress.sourcePositions[locator.sourceID]?.locator,
            locator
        )
        XCTAssertEqual(storedProgress.sourcePositions[locator.sourceID]?.progressFraction, 0.625)
        XCTAssertEqual(storedProgress.sourcePositions[locator.sourceID]?.granularity, .text)
        XCTAssertEqual(
            storedProgress.sourcePositions[locator.sourceID]?.displayLabel,
            "README.md · 第 25 行 · 62%"
        )

        let storedHistory = try fixture.database.fetchReadingHistory(
            spaceID: fixture.imported.space.id
        )
        XCTAssertEqual(storedHistory.map(\.id), [history.id])
        XCTAssertEqual(storedHistory.first?.locator, locator)
    }

    func testQuickLookRejectsStructuredHighlightButAcceptsSourceNote() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let locator = Locator(
            sourceID: fixture.imported.source.id,
            snapshotID: fixture.imported.snapshot.id,
            adapterID: QuickLookAdapter.id,
            fingerprint: fixture.imported.snapshot.digest
        )
        let highlight = Annotation(
            id: "highlight",
            spaceID: fixture.imported.space.id,
            sourceID: fixture.imported.source.id,
            snapshotID: fixture.imported.snapshot.id,
            kind: .highlight,
            locator: locator,
            anchorState: .current,
            selectedText: "not allowed",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )
        XCTAssertThrowsError(try fixture.database.saveAnnotation(highlight))

        let note = Annotation(
            id: "note",
            spaceID: fixture.imported.space.id,
            sourceID: fixture.imported.source.id,
            snapshotID: fixture.imported.snapshot.id,
            kind: .note,
            locator: locator,
            anchorState: .current,
            selectedText: nil,
            note: "source-level note",
            color: nil,
            createdAt: .now,
            updatedAt: .now
        )
        XCTAssertNoThrow(try fixture.database.saveAnnotation(note))
    }

    func testProgressRejectsLocatorOutsideSpace() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var progress = ReadingProgress.empty
        let forged = Locator(
            sourceID: "other-source",
            snapshotID: "other-snapshot",
            adapterID: MarkdownAdapter.id
        )
        progress.sourcePositions["other-source"] = SourcePosition(
            sourceID: "other-source",
            locator: forged,
            updatedAt: .now
        )
        XCTAssertThrowsError(
            try fixture.database.saveReadingProgress(
                progress,
                spaceID: fixture.imported.space.id
            )
        )
    }

    func testProgressRejectsInvalidSourceFraction() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let nodes = try await fixture.coordinator.list(plan: fixture.plan)
        let locator = try XCTUnwrap(nodes.first?.locator)
        var progress = ReadingProgress.empty
        progress.sourcePositions[locator.sourceID] = SourcePosition(
            sourceID: locator.sourceID,
            locator: locator,
            updatedAt: .now,
            progressFraction: 1.01,
            granularity: .text,
            displayLabel: "invalid"
        )

        XCTAssertThrowsError(
            try fixture.database.saveReadingProgress(
                progress,
                spaceID: fixture.imported.space.id
            )
        )
    }

    func testProgressRejectsHistoricalSnapshotAfterSourceRefresh() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let nodes = try await fixture.coordinator.list(plan: fixture.plan)
        let oldLocator = try XCTUnwrap(nodes.first?.locator)
        let newSnapshot = SourceSnapshot(
            id: "refreshed-\(UUID().uuidString)",
            sourceID: fixture.imported.source.id,
            revision: "revision-2",
            revisionKind: .contentDigest,
            digest: "digest-2",
            observedAt: .now,
            origin: fixture.imported.snapshot.origin,
            managedRelativePath: fixture.imported.snapshot.managedRelativePath,
            byteCount: fixture.imported.snapshot.byteCount
        )
        let currentLocator = Locator(
            sourceID: oldLocator.sourceID,
            snapshotID: newSnapshot.id,
            adapterID: oldLocator.adapterID,
            payload: oldLocator.payload,
            structuralPath: oldLocator.structuralPath,
            textQuote: oldLocator.textQuote,
            fingerprint: oldLocator.fingerprint
        )
        try fixture.database.commitSnapshotRefreshForTesting(
            newSnapshot,
            migrations: SourceRevisionMigrationBatch(
                annotations: [],
                positions: [
                    SourcePositionRevisionMigration(
                        spaceID: fixture.imported.space.id,
                        sourceID: fixture.imported.source.id,
                        resolvedLocator: currentLocator
                    )
                ]
            )
        )

        var staleProgress = ReadingProgress.empty
        staleProgress.sourcePositions[oldLocator.sourceID] = SourcePosition(
            sourceID: oldLocator.sourceID,
            locator: oldLocator,
            updatedAt: .now,
            progressFraction: 0.8,
            granularity: .text,
            displayLabel: "旧版本位置"
        )
        XCTAssertThrowsError(
            try fixture.database.saveReadingProgress(
                staleProgress,
                spaceID: fixture.imported.space.id
            )
        )

        var currentProgress = ReadingProgress.empty
        currentProgress.sourcePositions[currentLocator.sourceID] = SourcePosition(
            sourceID: currentLocator.sourceID,
            locator: currentLocator,
            updatedAt: .now
        )
        XCTAssertNoThrow(
            try fixture.database.saveReadingProgress(
                currentProgress,
                spaceID: fixture.imported.space.id
            )
        )
    }

    func testLegacySourcePositionWithoutMetadataStillDecodes() throws {
        let locator = Locator(
            sourceID: "legacy-source",
            snapshotID: "legacy-snapshot",
            adapterID: PlainTextAdapter.id,
            payload: ["startLine": "8"]
        )
        var progress = ReadingProgress.empty
        progress.sourcePositions[locator.sourceID] = SourcePosition(
            sourceID: locator.sourceID,
            locator: locator,
            updatedAt: Date(timeIntervalSince1970: 42)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(progress)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("progressFraction"))
        XCTAssertFalse(json.contains("granularity"))
        XCTAssertFalse(json.contains("displayLabel"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReadingProgress.self, from: encoded)
        let position = try XCTUnwrap(decoded.sourcePositions[locator.sourceID])
        XCTAssertEqual(position.locator, locator)
        XCTAssertNil(position.progressFraction)
        XCTAssertNil(position.granularity)
        XCTAssertNil(position.displayLabel)
        XCTAssertEqual(position.resolvedGranularity, .document)
    }

    func testReadingPositionUpdateNormalizesFractionAndLabel() {
        let locator = Locator(
            sourceID: "source",
            snapshotID: "snapshot",
            adapterID: PDFAdapter.id,
            payload: ["pageIndex": "4"]
        )
        let update = ReadingPositionUpdate(
            locator: locator,
            progressFraction: 1.5,
            granularity: .page,
            displayLabel: "  第 5 页  "
        )
        XCTAssertEqual(update.progressFraction, 1)
        XCTAssertEqual(update.granularity, .page)
        XCTAssertEqual(update.displayLabel, "第 5 页")

        let invalid = ReadingPositionUpdate(
            locator: locator,
            progressFraction: .nan,
            granularity: .page
        )
        XCTAssertNil(invalid.progressFraction)
    }

    func testRemovingSourceClearsSourceBoundReaderStateAndResetsRouteProgress() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let nodes = try await fixture.coordinator.list(plan: fixture.plan)
        let locator = try XCTUnwrap(nodes.first?.locator)
        let annotation = Annotation(
            id: "annotation-removal",
            spaceID: fixture.imported.space.id,
            sourceID: fixture.imported.source.id,
            snapshotID: fixture.imported.snapshot.id,
            kind: .bookmark,
            locator: locator,
            anchorState: .current,
            selectedText: nil,
            note: nil,
            color: nil,
            createdAt: .now,
            updatedAt: .now
        )
        try fixture.database.saveAnnotation(annotation)

        var progress = ReadingProgress.empty
        progress.graphVersion = "graph-v1"
        progress.currentUnitID = "unit-1"
        progress.currentPlanStepID = "step-1"
        progress.units["unit-1"] = UnitProgress(
            unitID: "unit-1",
            state: .completed,
            fraction: 1,
            updatedAt: .now
        )
        progress.sourcePositions[fixture.imported.source.id] = SourcePosition(
            sourceID: fixture.imported.source.id,
            locator: locator,
            updatedAt: .now
        )
        try fixture.database.saveReadingProgress(
            progress,
            spaceID: fixture.imported.space.id
        )
        try fixture.database.recordReadingHistory(
            ReadingHistoryEntry(
                id: "history-removal",
                spaceID: fixture.imported.space.id,
                sourceID: fixture.imported.source.id,
                snapshotID: fixture.imported.snapshot.id,
                locator: locator
            )
        )
        let manifest = try fixture.database.currentSnapshotManifest(
            spaceID: fixture.imported.space.id
        )
        let request = AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            expectedSnapshotIDs: Set(manifest.values),
            snapshotManifest: manifest
        )
        let run = AgentRun(
            id: "run-removal",
            spaceID: fixture.imported.space.id,
            task: request.task,
            generation: 1,
            state: .queued,
            providerProfileID: nil,
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

        let generations = try await fixture.library.removeSource(
            id: fixture.imported.source.id
        )

        XCTAssertTrue(
            try fixture.database.fetchAnnotations(spaceID: fixture.imported.space.id).isEmpty
        )
        XCTAssertTrue(
            try fixture.database.fetchReadingHistory(spaceID: fixture.imported.space.id).isEmpty
        )
        let storedProgress = try fixture.database.fetchReadingProgress(
            spaceID: fixture.imported.space.id
        )
        XCTAssertNil(storedProgress.graphVersion)
        XCTAssertNil(storedProgress.currentUnitID)
        XCTAssertNil(storedProgress.currentPlanStepID)
        XCTAssertTrue(storedProgress.units.isEmpty)
        XCTAssertNil(storedProgress.sourcePositions[fixture.imported.source.id])
        XCTAssertEqual(generations[fixture.imported.space.id], 2)
        XCTAssertEqual(
            try fixture.database.fetchAgentSession(spaceID: fixture.imported.space.id)?.generation,
            2
        )
        let removedRun = try XCTUnwrap(
            fixture.database.fetchAgentRuns(spaceID: fixture.imported.space.id).first
        )
        XCTAssertEqual(removedRun.state, .cancelled)
        XCTAssertEqual(removedRun.errorCategory, "source-removed")
        XCTAssertEqual(
            try fixture.database.fetchAgentEvents(runID: run.id).last?.kind,
            .cancelled
        )
    }

    private func makeFixture() async throws -> (
        root: URL,
        database: LibraryDatabase,
        library: ManagedLibrary,
        imported: ManagedImportResult,
        coordinator: AdapterCoordinator,
        plan: AdapterPlan
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneReaderReaderPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.md")
        try Data("# Source\n\nreader evidence".utf8).write(to: sourceURL)
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(
            database: database,
            storagePolicy: LibraryStoragePolicy(
                largeImportThreshold: .max,
                minimumFreeCapacity: 0,
                capacityProvider: { _ in .max }
            )
        )
        let imported = try await library.importLocalSource(at: sourceURL)
        let coordinator = try AdapterCoordinator.standard(database: database)
        let plan = try await coordinator.prepare(sourceID: imported.source.id, snapshotID: imported.snapshot.id)
        return (root, database, library, imported, coordinator, plan)
    }
}
