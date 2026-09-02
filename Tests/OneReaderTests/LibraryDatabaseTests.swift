import Foundation
import GRDB
import XCTest
@testable import OneReader

final class LibraryDatabaseTests: XCTestCase {
    func testInitializesVersionedSchemaInWALMode() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try LibraryDatabase(rootURL: root)

        XCTAssertEqual(try database.journalMode().lowercased(), "wal")
        XCTAssertEqual(
            try database.schemaMetadata(),
            [
                "adapter_schema": "1",
                "agent_runtime_schema": "5",
                "database_schema": "9",
            ]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.sourcesURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.snapshotsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.derivedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.artifactsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.stagingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.databaseURL.path))
        XCTAssertFalse(try database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'observation_fts')"
            ) ?? true
        })
    }

    func testLegacyProgressIsBackedUpWithoutBindingToNewObjects() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let legacyURL = root.appendingPathComponent("progress-v1.json")
        try Data("{\"schemaVersion\":1}".utf8).write(to: legacyURL, options: .atomic)

        let database = try LibraryDatabase(rootURL: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        let manifests = try database.migrationManifest(kind: "legacy-progress-v1")
        XCTAssertEqual(manifests.count, 1)
        XCTAssertEqual(manifests[0].source, "progress-v1.json")
        let destination = try XCTUnwrap(manifests[0].destination)
        let backupURL = try database.layout.url(forRelativePath: destination)
        XCTAssertEqual(try Data(contentsOf: backupURL), Data("{\"schemaVersion\":1}".utf8))
        let detail = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifests[0].detailJSON) as? [String: Any]
        )
        XCTAssertEqual(detail["boundToNewObjects"] as? Bool, false)
        XCTAssertTrue(try database.fetchSources().isEmpty)
        XCTAssertTrue(try database.fetchSpaces().isEmpty)
    }

    func testSourceAccessBookmarkIsStoredWithImportAndRemovedWithSource() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(rootURL: root)
        let snapshotID = "bookmark-snapshot"
        let source = Source(
            id: "bookmark-source",
            displayName: "book.md",
            originKind: .localFile,
            originURL: URL(fileURLWithPath: "/tmp/book.md"),
            managedState: .ready,
            latestSnapshotID: snapshotID
        )
        let snapshot = SourceSnapshot(
            id: snapshotID,
            sourceID: source.id,
            revision: "revision",
            revisionKind: .contentDigest,
            digest: "digest",
            observedAt: .now,
            origin: source.originURL,
            managedRelativePath: nil,
            byteCount: 0
        )
        let space = ReadingSpace(id: "bookmark-space", title: "Book")
        let bookmark = Data([0, 1, 2, 3])

        try database.commitImport(
            source: source,
            snapshot: snapshot,
            space: space,
            createsSpace: true,
            accessBookmark: bookmark
        )
        XCTAssertEqual(
            try database.sourceAccessBookmark(sourceID: source.id),
            bookmark
        )
        let replacement = Data([4, 5, 6])
        try database.saveSourceAccessBookmark(replacement, sourceID: source.id)
        XCTAssertEqual(
            try database.sourceAccessBookmark(sourceID: source.id),
            replacement
        )

        _ = try database.commitRemoval(sourceID: source.id)
        XCTAssertNil(try database.sourceAccessBookmark(sourceID: source.id))
    }

    func testV5FailureAuditRowsBackfillAndCorruptEnumsFailClosed() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try prepareVersion5AuditFixture(at: root)

        let database = try LibraryDatabase(rootURL: root)
        XCTAssertEqual(
            try database.fetchTranscriptRecords(runID: "run-v5").first?.disposition,
            .complete
        )
        XCTAssertEqual(
            try database.fetchAgentModelCallMetrics(runID: "run-v5").first?.outcome,
            .succeeded
        )

        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE agent_model_call_metrics SET outcome = 'corrupt' WHERE run_id = ?",
                arguments: ["run-v5"]
            )
        }
        XCTAssertThrowsError(
            try database.fetchAgentModelCallMetrics(runID: "run-v5")
        ) { error in
            XCTAssertEqual(
                error as? LibraryDatabaseError,
                .corruptValue(
                    table: "agent_model_call_metrics",
                    column: "outcome",
                    value: "corrupt"
                )
            )
        }

        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE agent_transcript_entries SET disposition = 'corrupt' WHERE run_id = ?",
                arguments: ["run-v5"]
            )
        }
        XCTAssertThrowsError(
            try database.fetchTranscriptRecords(runID: "run-v5")
        ) { error in
            XCTAssertEqual(
                error as? LibraryDatabaseError,
                .corruptValue(
                    table: "agent_transcript_entries",
                    column: "disposition",
                    value: "corrupt"
                )
            )
        }
    }

    func testObservationIndexPublishesAtomicallyAndInterruptedStagingIsRebuilt() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("index.txt")
        try Data("Atomic index evidence".utf8).write(to: sourceURL)
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
        let plan = try await coordinator.prepare(
            sourceID: imported.source.id,
            snapshotID: imported.snapshot.id
        )
        let nodes = try await coordinator.list(plan: plan)
        let node = try XCTUnwrap(nodes.first)
        let observation = try await coordinator.read(
            plan: plan,
            locator: node.locator,
            persistObservation: false
        )
        let interruptedGeneration = try database.beginObservationIndex(
            snapshotID: plan.snapshotID,
            planID: plan.id
        )
        try database.stageObservation(
            observation,
            title: node.title,
            generationID: interruptedGeneration
        )

        XCTAssertEqual(try database.observationCount(snapshotID: plan.snapshotID), 0)
        XCTAssertFalse(try database.isObservationIndexComplete(
            snapshotID: plan.snapshotID,
            planID: plan.id
        ))
        XCTAssertTrue(try database.searchObservations(query: "evidence").isEmpty)

        let restarted = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        XCTAssertFalse(try restarted.isObservationIndexComplete(
            snapshotID: plan.snapshotID,
            planID: plan.id
        ))
        XCTAssertThrowsError(
            try restarted.completeObservationIndex(
                snapshotID: plan.snapshotID,
                planID: plan.id,
                generationID: interruptedGeneration
            )
        )
        let restartedCoordinator = try AdapterCoordinator.standard(database: restarted)
        try await restartedCoordinator.index(plan: plan)

        XCTAssertTrue(try restarted.isObservationIndexComplete(
            snapshotID: plan.snapshotID,
            planID: plan.id
        ))
        XCTAssertEqual(try restarted.observationCount(snapshotID: plan.snapshotID), 0)
        XCTAssertEqual(try restarted.searchDocumentCount(planID: plan.id), 1)
        XCTAssertEqual(try restarted.searchObservations(query: "evidence").count, 1)
    }

    func testReadEvidenceObservationNeverLeaksIntoSearchProjection() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("evidence.txt")
        try Data("private tool evidence marker".utf8).write(to: sourceURL)
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
        let plan = try await coordinator.prepare(
            sourceID: imported.source.id,
            snapshotID: imported.snapshot.id
        )
        let nodes = try await coordinator.list(plan: plan)
        let node = try XCTUnwrap(nodes.first)
        let observation = try await coordinator.read(
            plan: plan,
            locator: node.locator,
            persistObservation: false
        )

        try database.saveObservation(observation, title: "Evidence only")

        XCTAssertEqual(try database.observationCount(snapshotID: plan.snapshotID), 1)
        XCTAssertEqual(try database.searchDocumentCount(planID: plan.id), 0)
        XCTAssertTrue(try database.searchObservations(query: "private").isEmpty)
    }

    func testPlanSwitchRejectsLateIndexPublishAndOnlyCurrentPlanIsSearchable() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("projection.txt")
        try Data("old projection evidence".utf8).write(to: sourceURL)
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
        let oldPlan = try await coordinator.prepare(
            sourceID: imported.source.id,
            snapshotID: imported.snapshot.id
        )
        let nodes = try await coordinator.list(plan: oldPlan)
        let node = try XCTUnwrap(nodes.first)
        let oldObservation = try await coordinator.read(
            plan: oldPlan,
            locator: node.locator,
            persistObservation: false
        )
        let oldGeneration = try database.beginObservationIndex(
            snapshotID: oldPlan.snapshotID,
            planID: oldPlan.id
        )
        try database.stageObservation(
            oldObservation,
            title: "Old projection",
            generationID: oldGeneration
        )

        let currentPlan = AdapterPlan(
            id: "current-plan-\(UUID().uuidString.lowercased())",
            schemaVersion: oldPlan.schemaVersion,
            sourceID: oldPlan.sourceID,
            snapshotID: oldPlan.snapshotID,
            primaryAdapterID: oldPlan.primaryAdapterID,
            auxiliaryAdapterIDs: oldPlan.auxiliaryAdapterIDs,
            capabilityRoutes: oldPlan.capabilityRoutes,
            evidence: oldPlan.evidence,
            confidence: oldPlan.confidence,
            reason: "Current plan switch fixture",
            isUserOverride: true,
            createdAt: .now
        )
        try database.saveAdapterPlan(currentPlan)

        XCTAssertThrowsError(
            try database.completeObservationIndex(
                snapshotID: oldPlan.snapshotID,
                planID: oldPlan.id,
                generationID: oldGeneration
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(try database.searchObservations(query: "old").isEmpty)
        try database.failObservationIndex(
            snapshotID: oldPlan.snapshotID,
            planID: oldPlan.id,
            generationID: oldGeneration,
            category: "plan-superseded"
        )

        let currentBody = "current projection evidence"
        let currentObservation = Observation(
            id: oldObservation.id,
            sourceID: oldObservation.sourceID,
            snapshotID: oldObservation.snapshotID,
            adapterID: oldObservation.adapterID,
            locator: oldObservation.locator,
            mediaType: oldObservation.mediaType,
            content: currentBody,
            contentReference: oldObservation.contentReference,
            contentDigest: AdapterUtilities.sha256(currentBody),
            truncated: false,
            observedAt: .now
        )
        let currentGeneration = try database.beginObservationIndex(
            snapshotID: currentPlan.snapshotID,
            planID: currentPlan.id
        )
        try database.stageObservation(
            currentObservation,
            title: "Current projection",
            generationID: currentGeneration
        )
        try database.completeObservationIndex(
            snapshotID: currentPlan.snapshotID,
            planID: currentPlan.id,
            generationID: currentGeneration
        )

        XCTAssertFalse(try database.isObservationIndexComplete(
            snapshotID: oldPlan.snapshotID,
            planID: oldPlan.id
        ))
        XCTAssertTrue(try database.isObservationIndexComplete(
            snapshotID: currentPlan.snapshotID,
            planID: currentPlan.id
        ))
        XCTAssertTrue(try database.searchObservations(query: "old").isEmpty)
        XCTAssertEqual(try database.searchObservations(query: "current").count, 1)
    }

    private func prepareVersion5AuditFixture(at root: URL) throws {
        let layout = ApplicationSupportLayout(rootURL: root)
        try layout.prepare()
        let pool = try DatabasePool(path: layout.databaseURL.path)
        let migrator = LibraryDatabase.makeMigrator()
        try migrator.migrate(pool, upTo: "v5-agent-runtime-audit")
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reading_spaces
                        (id, title, is_favorite, created_at, updated_at)
                    VALUES ('space-v5', 'Version 5', 0, ?, ?)
                    """,
                arguments: [Date.now, Date.now]
            )
            try db.execute(
                sql: """
                    INSERT INTO agent_runs
                        (id, space_id, task, generation, state, created_at)
                    VALUES ('run-v5', 'space-v5', 'scoutSpace', 1, 'completed', ?)
                    """,
                arguments: [Date.now]
            )
            try db.execute(
                sql: """
                    INSERT INTO agent_transcript_entries
                        (id, run_id, sequence, role, content, created_at)
                    VALUES ('transcript-v5', 'run-v5', 0, 'assistant', X'7B7D', ?)
                    """,
                arguments: [Date.now]
            )
            try db.execute(
                sql: """
                    INSERT INTO agent_model_call_metrics
                        (id, run_id, round, kind, input_bytes, output_bytes,
                         input_token_upper_bound, output_token_upper_bound,
                         duration_milliseconds, created_at)
                    VALUES ('metric-v5', 'run-v5', 1, 'generation', 10, 20,
                            266, 84, 5, ?)
                    """,
                arguments: [Date.now]
            )
        }
    }

    private func makeTemporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneReaderLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return url
    }
}
