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
                "database_schema": "6",
            ]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.sourcesURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.snapshotsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.derivedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.artifactsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.stagingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.databaseURL.path))
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
