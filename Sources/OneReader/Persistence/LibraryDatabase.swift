import Foundation
import GRDB

enum LibraryDatabaseError: LocalizedError, Equatable {
    case corruptValue(table: String, column: String, value: String)

    var errorDescription: String? {
        switch self {
        case let .corruptValue(table, column, value):
            "数据库字段无法解码：\(table).\(column)=\(value)"
        }
    }
}

final class LibraryDatabase: @unchecked Sendable {
    static let schemaVersion = 6

    let layout: ApplicationSupportLayout
    let pool: DatabasePool

    init(rootURL: URL? = nil) throws {
        layout = ApplicationSupportLayout(rootURL: rootURL)
        try layout.prepare()

        var configuration = Configuration()
        configuration.label = "OneReader.Library"
        configuration.maximumReaderCount = 4
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }

        pool = try DatabasePool(
            path: layout.databaseURL.path,
            configuration: configuration
        )

        let migrator = Self.makeMigrator()
        try migrator.migrate(pool)
        try interruptIncompleteAgentRuns()
        try LegacyProgressMigration.backUpIfNeeded(layout: layout, pool: pool)
    }

    func schemaMetadata() throws -> [String: String] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT key, value FROM library_metadata ORDER BY key"
            )
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let key: String = row["key"]
                let value: String = row["value"]
                return (key, value)
            })
        }
    }

    func journalMode() throws -> String {
        try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown"
        }
    }

    func fetchSources(includeRemoved: Bool = false) throws -> [Source] {
        try pool.read { db in
            let predicate = includeRemoved ? "" : "WHERE managed_state != 'removed'"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM sources
                    \(predicate)
                    ORDER BY updated_at DESC, id
                    """
            )
            return try rows.map(Self.decodeSource)
        }
    }

    func fetchSpaces() throws -> [ReadingSpace] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM reading_spaces ORDER BY updated_at DESC, id"
            )
            return rows.map(Self.decodeSpace)
        }
    }

    func fetchSnapshots(sourceID: String? = nil) throws -> [SourceSnapshot] {
        try pool.read { db in
            let rows: [Row]
            if let sourceID {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM snapshots WHERE source_id = ? ORDER BY created_at DESC",
                    arguments: [sourceID]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM snapshots ORDER BY created_at DESC"
                )
            }
            return try rows.map(Self.decodeSnapshot)
        }
    }

    func activeSnapshotIDs() throws -> Set<String> {
        try pool.read { db in
            Set(try String.fetchAll(
                db,
                sql: """
                    SELECT snapshots.id
                    FROM snapshots
                    JOIN sources ON sources.id = snapshots.source_id
                    WHERE sources.managed_state != 'removed'
                    """
            ))
        }
    }

    func sourceIDs(in spaceID: String) throws -> [String] {
        try pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT source_id
                    FROM space_sources
                    WHERE space_id = ?
                    ORDER BY position, added_at
                    """,
                arguments: [spaceID]
            )
        }
    }

    func spaceIDs(containing sourceID: String) throws -> [String] {
        try pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT space_id FROM space_sources WHERE source_id = ? ORDER BY space_id",
                arguments: [sourceID]
            )
        }
    }

    func existingManagedPath(forDigest digest: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT snapshots.managed_relative_path
                    FROM snapshots
                    JOIN sources ON sources.id = snapshots.source_id
                    WHERE snapshots.digest = ?
                      AND snapshots.managed_relative_path IS NOT NULL
                      AND sources.managed_state != 'removed'
                    ORDER BY snapshots.created_at
                    LIMIT 1
                    """,
                arguments: [digest]
            )
        }
    }

    func containsSpace(_ id: String) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM reading_spaces WHERE id = ?)",
                arguments: [id]
            ) ?? false
        }
    }

    func commitImport(
        source: Source,
        snapshot: SourceSnapshot,
        space: ReadingSpace,
        createsSpace: Bool
    ) throws {
        try pool.write { db in
            if createsSpace {
                try db.execute(
                    sql: """
                        INSERT INTO reading_spaces
                            (id, title, is_favorite, created_at, updated_at, last_opened_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        space.id,
                        space.title,
                        space.isFavorite,
                        space.createdAt,
                        space.updatedAt,
                        space.lastOpenedAt,
                    ]
                )
            } else {
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM reading_spaces WHERE id = ?)",
                    arguments: [space.id]
                ) ?? false
                guard exists else {
                    throw LibraryStorageError.missingSpace(space.id)
                }
            }

            try db.execute(
                sql: """
                    INSERT INTO sources
                        (id, display_name, origin_kind, origin_url, managed_state,
                         latest_snapshot_id, failure_reason, is_favorite, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    source.id,
                    source.displayName,
                    source.originKind.rawValue,
                    source.originURL?.absoluteString,
                    source.managedState.rawValue,
                    source.latestSnapshotID,
                    source.failureReason,
                    source.isFavorite,
                    source.createdAt,
                    source.updatedAt,
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO snapshots
                        (id, source_id, revision_kind, revision, digest, origin_url,
                         managed_relative_path, byte_count, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    snapshot.id,
                    snapshot.sourceID,
                    snapshot.revisionKind.rawValue,
                    snapshot.revision,
                    snapshot.digest,
                    snapshot.origin?.absoluteString,
                    snapshot.managedRelativePath,
                    snapshot.byteCount,
                    snapshot.observedAt,
                ]
            )

            let position = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM space_sources WHERE space_id = ?",
                arguments: [space.id]
            ) ?? 0
            try db.execute(
                sql: """
                    INSERT INTO space_sources (space_id, source_id, position, added_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [space.id, source.id, position, Date.now]
            )
        }
    }

    fileprivate func commitSnapshotRefreshAndInvalidateRuns(
        _ snapshot: SourceSnapshot
    ) throws -> [String: Int] {
        try pool.write { db in
            guard let state = try String.fetchOne(
                db,
                sql: "SELECT managed_state FROM sources WHERE id = ?",
                arguments: [snapshot.sourceID]
            ), state == SourceManagedState.ready.rawValue else {
                throw LibraryStorageError.missingSource(snapshot.sourceID)
            }
            let spaceIDs = try String.fetchAll(
                db,
                sql: "SELECT space_id FROM space_sources WHERE source_id = ? ORDER BY space_id",
                arguments: [snapshot.sourceID]
            )
            try db.execute(
                sql: """
                    INSERT INTO snapshots
                        (id, source_id, revision_kind, revision, digest, origin_url,
                         managed_relative_path, byte_count, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    snapshot.id,
                    snapshot.sourceID,
                    snapshot.revisionKind.rawValue,
                    snapshot.revision,
                    snapshot.digest,
                    snapshot.origin?.absoluteString,
                    snapshot.managedRelativePath,
                    snapshot.byteCount,
                    snapshot.observedAt,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE sources
                    SET latest_snapshot_id = ?, updated_at = ?
                    WHERE id = ? AND managed_state = 'ready'
                    """,
                arguments: [snapshot.id, snapshot.observedAt, snapshot.sourceID]
            )
            guard db.changesCount == 1 else {
                throw LibraryStorageError.missingSource(snapshot.sourceID)
            }
            let metadata = try JSONEncoder.databaseEncoder.encode([
                "category": "source-revision-changed",
                "sourceID": snapshot.sourceID,
                "snapshotID": snapshot.id,
            ])
            var generations: [String: Int] = [:]
            for spaceID in spaceIDs {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id
                        FROM agent_runs
                        WHERE space_id = ? AND state IN ('queued', 'running', 'waitingForUser')
                        ORDER BY created_at, id
                        """,
                    arguments: [spaceID]
                )
                for row in rows {
                    let runID: String = row["id"]
                    try db.execute(
                        sql: """
                            UPDATE agent_runs
                            SET state = 'cancelled', finished_at = ?,
                                error_category = 'source-revision-changed'
                            WHERE id = ? AND state IN ('queued', 'running', 'waitingForUser')
                            """,
                        arguments: [Date.now, runID]
                    )
                    try db.execute(
                        sql: "UPDATE agent_outputs SET disposition = 'superseded' WHERE run_id = ?",
                        arguments: [runID]
                    )
                    let sequence = try Int.fetchOne(
                        db,
                        sql: "SELECT COALESCE(MAX(sequence), -1) + 1 FROM agent_events WHERE run_id = ?",
                        arguments: [runID]
                    ) ?? 0
                    try db.execute(
                        sql: """
                            INSERT INTO agent_events
                                (id, run_id, sequence, kind, phase, message,
                                 metadata_json, created_at)
                            VALUES (?, ?, ?, 'cancelled', 'revision', ?, ?, ?)
                            """,
                        arguments: [
                            UUID().uuidString.lowercased(),
                            runID,
                            sequence,
                            "来源版本已刷新；旧 Run 已取消。",
                            metadata,
                            Date.now,
                        ]
                    )
                }
                try db.execute(
                    sql: """
                        UPDATE reading_agent_sessions
                        SET generation = generation + 1,
                            transcript_json = NULL,
                            projection_json = NULL,
                            updated_at = ?
                        WHERE space_id = ?
                        """,
                    arguments: [Date.now, spaceID]
                )
                generations[spaceID] = try Int.fetchOne(
                    db,
                    sql: "SELECT generation FROM reading_agent_sessions WHERE space_id = ?",
                    arguments: [spaceID]
                ) ?? 0
            }
            return generations
        }
    }

    #if DEBUG
    func commitSnapshotRefreshForTesting(_ snapshot: SourceSnapshot) throws {
        _ = try commitSnapshotRefreshAndInvalidateRuns(snapshot)
    }
    #endif

    func removalPlan(sourceID: String) throws -> ManagedRemovalPlan {
        try pool.read { db in
            let exists = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM sources
                        WHERE id = ? AND managed_state != 'removed'
                    )
                    """,
                arguments: [sourceID]
            ) ?? false
            guard exists else {
                throw LibraryStorageError.missingSource(sourceID)
            }

            let paths = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT managed_relative_path
                    FROM snapshots
                    WHERE source_id = ? AND managed_relative_path IS NOT NULL
                    ORDER BY managed_relative_path
                    """,
                arguments: [sourceID]
            )
            let exclusivePaths = try paths.filter { path in
                try !(Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1
                            FROM snapshots
                            JOIN sources ON sources.id = snapshots.source_id
                            WHERE snapshots.managed_relative_path = ?
                              AND snapshots.source_id != ?
                              AND sources.managed_state != 'removed'
                        )
                        """,
                    arguments: [path, sourceID]
                ) ?? false)
            }
            return ManagedRemovalPlan(
                sourceID: sourceID,
                exclusiveManagedRelativePaths: exclusivePaths,
                snapshotIDs: try String.fetchAll(
                    db,
                    sql: "SELECT id FROM snapshots WHERE source_id = ? ORDER BY created_at, id",
                    arguments: [sourceID]
                )
            )
        }
    }

    func commitRemoval(sourceID: String) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    UPDATE sources
                    SET managed_state = 'removed', latest_snapshot_id = NULL, updated_at = ?
                    WHERE id = ? AND managed_state != 'removed'
                """,
                arguments: [Date.now, sourceID]
            )
            guard db.changesCount == 1 else {
                throw LibraryStorageError.missingSource(sourceID)
            }
            try db.execute(
                sql: "DELETE FROM space_sources WHERE source_id = ?",
                arguments: [sourceID]
            )
        }
    }

    func saveAdapterPlan(_ plan: AdapterPlan) throws {
        let payload = try JSONEncoder.databaseEncoder.encode(plan)
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO adapter_plans
                        (id, source_id, snapshot_id, schema_version, payload_json,
                         confidence, is_user_override, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        payload_json = excluded.payload_json,
                        confidence = excluded.confidence,
                        is_user_override = excluded.is_user_override,
                        created_at = excluded.created_at
                    """,
                arguments: [
                    plan.id,
                    plan.sourceID,
                    plan.snapshotID,
                    plan.schemaVersion,
                    payload,
                    plan.confidence,
                    plan.isUserOverride,
                    plan.createdAt,
                ]
            )
        }
    }

    func fetchAdapterPlan(snapshotID: String) throws -> AdapterPlan? {
        try pool.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: """
                    SELECT payload_json
                    FROM adapter_plans
                    WHERE snapshot_id = ?
                    ORDER BY is_user_override DESC, created_at DESC
                    LIMIT 1
                    """,
                arguments: [snapshotID]
            ) else { return nil }
            return try JSONDecoder.databaseDecoder.decode(AdapterPlan.self, from: data)
        }
    }

    func saveObservation(_ observation: Observation, title: String? = nil) throws {
        let locatorJSON = try JSONEncoder.databaseEncoder.encode(observation.locator)
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO observations
                        (id, source_id, snapshot_id, adapter_id, locator_json,
                         media_type, title, body, content_reference, digest,
                         truncated, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        locator_json = excluded.locator_json,
                        media_type = excluded.media_type,
                        title = excluded.title,
                        body = excluded.body,
                        content_reference = excluded.content_reference,
                        digest = excluded.digest,
                        truncated = excluded.truncated,
                        created_at = excluded.created_at
                    """,
                arguments: [
                    observation.id,
                    observation.sourceID,
                    observation.snapshotID,
                    observation.adapterID,
                    locatorJSON,
                    observation.mediaType,
                    title,
                    observation.content,
                    observation.contentReference,
                    observation.contentDigest,
                    observation.truncated,
                    observation.observedAt,
                ]
            )
            try db.execute(
                sql: "DELETE FROM observation_fts WHERE observation_id = ?",
                arguments: [observation.id]
            )
            try db.execute(
                sql: """
                    INSERT INTO observation_fts
                        (observation_id, source_id, snapshot_id, title, body)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    observation.id,
                    observation.sourceID,
                    observation.snapshotID,
                    title ?? "",
                    observation.content,
                ]
            )
        }
    }

    func searchObservations(
        query: String,
        snapshotID: String? = nil,
        limit: Int = 20
    ) throws -> [ContentSearchHit] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { term in
            "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        guard !terms.isEmpty else { return [] }
        let matchQuery = terms.joined(separator: " AND ")
        return try pool.read { db in
            var sql = """
                SELECT observations.locator_json,
                       observations.source_id,
                       observations.snapshot_id,
                       observations.adapter_id,
                       COALESCE(observations.title, '') AS title,
                       snippet(observation_fts, 4, '[', ']', ' … ', 24) AS context,
                       bm25(observation_fts) AS score
                FROM observation_fts
                JOIN observations
                  ON observations.id = observation_fts.observation_id
                JOIN sources
                  ON sources.id = observations.source_id
                WHERE observation_fts MATCH ?
                  AND sources.managed_state != 'removed'
                """
            var arguments: StatementArguments = [matchQuery]
            if let snapshotID {
                sql += " AND observations.snapshot_id = ?"
                arguments += [snapshotID]
            }
            sql += " ORDER BY score LIMIT ?"
            arguments += [min(max(1, limit), 20)]
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return try rows.enumerated().map { index, row in
                let locatorData: Data = row["locator_json"]
                let locator = try JSONDecoder.databaseDecoder.decode(
                    Locator.self,
                    from: locatorData
                )
                let sourceID: String = row["source_id"]
                let rowSnapshotID: String = row["snapshot_id"]
                let adapterID: String = row["adapter_id"]
                let title: String = row["title"]
                let context: String = row["context"]
                let score: Double = row["score"]
                return ContentSearchHit(
                    id: "fts:\(locator.stableID):\(index)",
                    sourceID: sourceID,
                    snapshotID: rowSnapshotID,
                    adapterID: adapterID,
                    locator: locator,
                    title: title,
                    context: context,
                    rank: -score
                )
            }
        }
    }

    func rebuildObservationIndex() throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM observation_fts")
            try db.execute(sql: """
                INSERT INTO observation_fts
                    (observation_id, source_id, snapshot_id, title, body)
                SELECT id, source_id, snapshot_id, COALESCE(title, ''), COALESCE(body, '')
                FROM observations
                ORDER BY created_at, id
                """)
        }
    }

    func observationCount(sourceID: String? = nil) throws -> Int {
        try pool.read { db in
            if let sourceID {
                return try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM observations WHERE source_id = ?",
                    arguments: [sourceID]
                ) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM observations") ?? 0
        }
    }

    func migrationManifest(
        kind: String
    ) throws -> [(source: String, destination: String?, detailJSON: Data)] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT source_path, destination_path, detail_json
                    FROM migration_manifest
                    WHERE kind = ?
                    ORDER BY migrated_at
                    """,
                arguments: [kind]
            )
            return rows.map { row in
                let source: String = row["source_path"]
                let destination: String? = row["destination_path"]
                let detailJSON: Data = row["detail_json"]
                return (source, destination, detailJSON)
            }
        }
    }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerMigrations(&migrator)
        return migrator
    }

    private static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1-library") { db in
            try db.execute(sql: """
                CREATE TABLE library_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );

                CREATE TABLE sources (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    origin_kind TEXT NOT NULL,
                    origin_url TEXT,
                    managed_state TEXT NOT NULL,
                    latest_snapshot_id TEXT,
                    failure_reason TEXT,
                    is_favorite INTEGER NOT NULL DEFAULT 0,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL
                );

                CREATE TABLE snapshots (
                    id TEXT PRIMARY KEY NOT NULL,
                    source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    revision_kind TEXT NOT NULL,
                    revision TEXT NOT NULL,
                    digest TEXT NOT NULL,
                    origin_url TEXT,
                    managed_relative_path TEXT,
                    byte_count INTEGER NOT NULL,
                    created_at DATETIME NOT NULL
                );
                CREATE INDEX snapshots_source_created ON snapshots(source_id, created_at DESC);
                CREATE INDEX snapshots_digest ON snapshots(digest);

                CREATE TABLE reading_spaces (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    is_favorite INTEGER NOT NULL DEFAULT 0,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    last_opened_at DATETIME
                );

                CREATE TABLE space_sources (
                    space_id TEXT NOT NULL REFERENCES reading_spaces(id) ON DELETE CASCADE,
                    source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    added_at DATETIME NOT NULL,
                    PRIMARY KEY (space_id, source_id)
                );

                CREATE TABLE adapter_plans (
                    id TEXT PRIMARY KEY NOT NULL,
                    source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    snapshot_id TEXT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
                    schema_version INTEGER NOT NULL,
                    payload_json BLOB NOT NULL,
                    confidence DOUBLE NOT NULL,
                    is_user_override INTEGER NOT NULL,
                    created_at DATETIME NOT NULL
                );

                CREATE TABLE observations (
                    id TEXT PRIMARY KEY NOT NULL,
                    source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    snapshot_id TEXT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
                    adapter_id TEXT NOT NULL,
                    locator_json BLOB NOT NULL,
                    media_type TEXT NOT NULL,
                    title TEXT,
                    body TEXT,
                    content_reference TEXT,
                    digest TEXT NOT NULL,
                    truncated INTEGER NOT NULL,
                    created_at DATETIME NOT NULL
                );
                CREATE INDEX observations_snapshot ON observations(snapshot_id, adapter_id);

                CREATE VIRTUAL TABLE observation_fts USING fts5(
                    observation_id UNINDEXED,
                    source_id UNINDEXED,
                    snapshot_id UNINDEXED,
                    title,
                    body,
                    tokenize='unicode61 remove_diacritics 2'
                );

                CREATE TABLE reading_graphs (
                    id TEXT PRIMARY KEY NOT NULL,
                    space_id TEXT NOT NULL REFERENCES reading_spaces(id) ON DELETE CASCADE,
                    version TEXT NOT NULL,
                    payload_json BLOB NOT NULL,
                    created_at DATETIME NOT NULL
                );

                CREATE TABLE reading_plans (
                    id TEXT PRIMARY KEY NOT NULL,
                    space_id TEXT NOT NULL REFERENCES reading_spaces(id) ON DELETE CASCADE,
                    graph_id TEXT NOT NULL REFERENCES reading_graphs(id) ON DELETE CASCADE,
                    graph_version TEXT NOT NULL,
                    goal TEXT NOT NULL,
                    payload_json BLOB NOT NULL,
                    is_frozen INTEGER NOT NULL DEFAULT 1,
                    created_at DATETIME NOT NULL
                );

                CREATE TABLE annotations (
                    id TEXT PRIMARY KEY NOT NULL,
                    space_id TEXT NOT NULL REFERENCES reading_spaces(id) ON DELETE CASCADE,
                    source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    snapshot_id TEXT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    locator_json BLOB NOT NULL,
                    anchor_state TEXT NOT NULL,
                    selected_text TEXT,
                    note TEXT,
                    color TEXT,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL
                );

                CREATE TABLE reading_progress (
                    space_id TEXT PRIMARY KEY NOT NULL REFERENCES reading_spaces(id) ON DELETE CASCADE,
                    schema_version INTEGER NOT NULL,
                    payload_json BLOB NOT NULL,
                    updated_at DATETIME NOT NULL
                );

                CREATE TABLE reading_history (
                    id TEXT PRIMARY KEY NOT NULL,
                    space_id TEXT NOT NULL REFERENCES reading_spaces(id) ON DELETE CASCADE,
                    source_id TEXT REFERENCES sources(id) ON DELETE SET NULL,
                    snapshot_id TEXT REFERENCES snapshots(id) ON DELETE SET NULL,
                    locator_json BLOB,
                    opened_at DATETIME NOT NULL,
                    duration_seconds DOUBLE NOT NULL DEFAULT 0
                );

                CREATE TABLE provider_profiles (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    provider_kind TEXT NOT NULL,
                    endpoint TEXT,
                    model_id TEXT NOT NULL,
                    keychain_reference TEXT,
                    is_default INTEGER NOT NULL DEFAULT 0,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL
                );

                CREATE TABLE agent_runs (
                    id TEXT PRIMARY KEY NOT NULL,
                    space_id TEXT NOT NULL REFERENCES reading_spaces(id) ON DELETE CASCADE,
                    task TEXT NOT NULL,
                    generation INTEGER NOT NULL,
                    state TEXT NOT NULL,
                    provider_profile_id TEXT REFERENCES provider_profiles(id) ON DELETE SET NULL,
                    created_at DATETIME NOT NULL,
                    started_at DATETIME,
                    finished_at DATETIME,
                    error_category TEXT
                );

                CREATE TABLE agent_events (
                    id TEXT PRIMARY KEY NOT NULL,
                    run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
                    sequence INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    phase TEXT NOT NULL,
                    message TEXT NOT NULL,
                    metadata_json BLOB NOT NULL,
                    created_at DATETIME NOT NULL,
                    UNIQUE(run_id, sequence)
                );

                CREATE TABLE agent_artifacts (
                    id TEXT PRIMARY KEY NOT NULL,
                    run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
                    digest TEXT NOT NULL,
                    media_type TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    byte_count INTEGER NOT NULL,
                    summary TEXT NOT NULL,
                    created_at DATETIME NOT NULL
                );

                CREATE TABLE migration_manifest (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    source_path TEXT NOT NULL,
                    destination_path TEXT,
                    detail_json BLOB NOT NULL,
                    migrated_at DATETIME NOT NULL
                );

                INSERT INTO library_metadata(key, value) VALUES
                    ('database_schema', '1'),
                    ('adapter_schema', '1'),
                    ('agent_runtime_schema', '1');
                """)
        }

        migrator.registerMigration("v2-agent-runtime") { db in
            try db.execute(sql: """
                ALTER TABLE provider_profiles ADD COLUMN context_window INTEGER;
                ALTER TABLE provider_profiles ADD COLUMN timeout_seconds DOUBLE NOT NULL DEFAULT 120;
                ALTER TABLE provider_profiles ADD COLUMN capabilities_json BLOB NOT NULL DEFAULT X'5B5D';
                ALTER TABLE provider_profiles ADD COLUMN last_tested_at DATETIME;
                ALTER TABLE provider_profiles ADD COLUMN last_test_succeeded INTEGER;

                ALTER TABLE agent_runs ADD COLUMN request_json BLOB;
                ALTER TABLE agent_runs ADD COLUMN resumed_from_run_id TEXT REFERENCES agent_runs(id) ON DELETE SET NULL;

                CREATE TABLE space_provider_overrides (
                    space_id TEXT PRIMARY KEY NOT NULL REFERENCES reading_spaces(id) ON DELETE CASCADE,
                    provider_profile_id TEXT NOT NULL REFERENCES provider_profiles(id) ON DELETE CASCADE,
                    updated_at DATETIME NOT NULL
                );

                CREATE TABLE remote_provider_disclosures (
                    space_id TEXT NOT NULL REFERENCES reading_spaces(id) ON DELETE CASCADE,
                    provider_profile_id TEXT NOT NULL REFERENCES provider_profiles(id) ON DELETE CASCADE,
                    acknowledged_at DATETIME NOT NULL,
                    PRIMARY KEY (space_id, provider_profile_id)
                );

                CREATE TABLE agent_transcript_entries (
                    id TEXT PRIMARY KEY NOT NULL,
                    run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
                    sequence INTEGER NOT NULL,
                    role TEXT NOT NULL,
                    content BLOB NOT NULL,
                    created_at DATETIME NOT NULL,
                    UNIQUE(run_id, sequence)
                );

                CREATE TABLE reading_agent_sessions (
                    space_id TEXT PRIMARY KEY NOT NULL REFERENCES reading_spaces(id) ON DELETE CASCADE,
                    provider_profile_id TEXT REFERENCES provider_profiles(id) ON DELETE SET NULL,
                    generation INTEGER NOT NULL DEFAULT 0,
                    transcript_json BLOB,
                    projection_json BLOB,
                    updated_at DATETIME NOT NULL
                );

                CREATE INDEX agent_runs_space_created
                    ON agent_runs(space_id, created_at DESC);
                CREATE INDEX agent_events_run_sequence
                    ON agent_events(run_id, sequence);

                UPDATE library_metadata SET value = '2' WHERE key = 'database_schema';
                UPDATE library_metadata SET value = '2' WHERE key = 'agent_runtime_schema';
                """)
        }

        migrator.registerMigration("v3-agent-output") { db in
            try db.execute(sql: """
                CREATE TABLE agent_outputs (
                    run_id TEXT PRIMARY KEY NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    payload_json BLOB NOT NULL,
                    disposition TEXT NOT NULL,
                    created_at DATETIME NOT NULL
                );

                UPDATE library_metadata SET value = '3' WHERE key = 'database_schema';
                UPDATE library_metadata SET value = '2' WHERE key = 'agent_runtime_schema';
                """)
        }

        migrator.registerMigration("v4-agent-runtime-cas") { db in
            try db.execute(sql: """
                ALTER TABLE remote_provider_disclosures
                    ADD COLUMN destination_identity TEXT NOT NULL DEFAULT '';

                CREATE UNIQUE INDEX agent_runs_one_resumed_child
                    ON agent_runs(resumed_from_run_id)
                    WHERE resumed_from_run_id IS NOT NULL;

                UPDATE library_metadata SET value = '4' WHERE key = 'database_schema';
                UPDATE library_metadata SET value = '3' WHERE key = 'agent_runtime_schema';
                """)
        }

        migrator.registerMigration("v5-agent-runtime-audit") { db in
            try db.execute(sql: """
                ALTER TABLE agent_runs ADD COLUMN provider_destination_identity TEXT;
                ALTER TABLE agent_runs ADD COLUMN provider_revision_identity TEXT;

                CREATE TABLE agent_context_snapshots (
                    id TEXT PRIMARY KEY NOT NULL,
                    run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
                    sequence INTEGER NOT NULL,
                    full_transcript_json BLOB NOT NULL,
                    projected_transcript_json BLOB NOT NULL,
                    projection_audit_json BLOB NOT NULL,
                    created_at DATETIME NOT NULL,
                    UNIQUE(run_id, sequence)
                );

                CREATE TABLE agent_model_call_metrics (
                    id TEXT PRIMARY KEY NOT NULL,
                    run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
                    round INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    input_bytes INTEGER NOT NULL,
                    output_bytes INTEGER NOT NULL,
                    input_token_upper_bound INTEGER NOT NULL,
                    output_token_upper_bound INTEGER NOT NULL,
                    duration_milliseconds INTEGER NOT NULL,
                    created_at DATETIME NOT NULL,
                    UNIQUE(run_id, round)
                );

                CREATE INDEX agent_context_snapshots_run_sequence
                    ON agent_context_snapshots(run_id, sequence);
                CREATE INDEX agent_model_call_metrics_run_round
                    ON agent_model_call_metrics(run_id, round);

                UPDATE library_metadata SET value = '5' WHERE key = 'database_schema';
                UPDATE library_metadata SET value = '4' WHERE key = 'agent_runtime_schema';
                """)
        }

        migrator.registerMigration("v6-agent-failure-audit") { db in
            try db.execute(sql: """
                ALTER TABLE agent_transcript_entries
                    ADD COLUMN disposition TEXT NOT NULL DEFAULT 'complete';
                ALTER TABLE agent_model_call_metrics
                    ADD COLUMN outcome TEXT NOT NULL DEFAULT 'succeeded';

                UPDATE library_metadata SET value = '6' WHERE key = 'database_schema';
                UPDATE library_metadata SET value = '5' WHERE key = 'agent_runtime_schema';
                """)
        }
    }

    private static func decodeSource(_ row: Row) throws -> Source {
        let originKindValue: String = row["origin_kind"]
        let stateValue: String = row["managed_state"]
        guard let originKind = SourceOriginKind(rawValue: originKindValue) else {
            throw LibraryDatabaseError.corruptValue(
                table: "sources",
                column: "origin_kind",
                value: originKindValue
            )
        }
        guard let state = SourceManagedState(rawValue: stateValue) else {
            throw LibraryDatabaseError.corruptValue(
                table: "sources",
                column: "managed_state",
                value: stateValue
            )
        }
        let originString: String? = row["origin_url"]
        return Source(
            id: row["id"],
            displayName: row["display_name"],
            originKind: originKind,
            originURL: originString.flatMap(URL.init(string:)),
            managedState: state,
            latestSnapshotID: row["latest_snapshot_id"],
            failureReason: row["failure_reason"],
            isFavorite: row["is_favorite"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private static func decodeSpace(_ row: Row) -> ReadingSpace {
        ReadingSpace(
            id: row["id"],
            title: row["title"],
            isFavorite: row["is_favorite"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            lastOpenedAt: row["last_opened_at"]
        )
    }

    private static func decodeSnapshot(_ row: Row) throws -> SourceSnapshot {
        let revisionKindValue: String = row["revision_kind"]
        guard let revisionKind = SourceRevisionKind(rawValue: revisionKindValue) else {
            throw LibraryDatabaseError.corruptValue(
                table: "snapshots",
                column: "revision_kind",
                value: revisionKindValue
            )
        }
        let originString: String? = row["origin_url"]
        return SourceSnapshot(
            id: row["id"],
            sourceID: row["source_id"],
            revision: row["revision"],
            revisionKind: revisionKind,
            digest: row["digest"],
            observedAt: row["created_at"],
            origin: originString.flatMap(URL.init(string:)),
            managedRelativePath: row["managed_relative_path"],
            byteCount: row["byte_count"]
        )
    }
}

struct ManagedRemovalPlan: Sendable, Equatable {
    let sourceID: String
    let exclusiveManagedRelativePaths: [String]
    let snapshotIDs: [String]
}

private extension JSONEncoder {
    static var databaseEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var databaseDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

protocol SourceRevisionCommitInterlock: Sendable {
    func beforeSnapshotCommit(sourceID: String) async
}

struct SourceRevisionCoordinator: Sendable {
    let database: LibraryDatabase
    let agentRuntime: ReadingAgentRuntime
    let commitInterlock: (any SourceRevisionCommitInterlock)?

    init(
        database: LibraryDatabase,
        agentRuntime: ReadingAgentRuntime,
        commitInterlock: (any SourceRevisionCommitInterlock)? = nil
    ) {
        self.database = database
        self.agentRuntime = agentRuntime
        self.commitInterlock = commitInterlock
    }

    func refresh(to snapshot: SourceSnapshot) async throws {
        // Install per-Space barriers before cancellation. Existing Session
        // references and new Runtime lookups cannot start a Run in the gap
        // between cancellation and the atomic Snapshot transaction.
        let lease = try await agentRuntime.beginSourceRevisionRefresh(
            sourceID: snapshot.sourceID
        )
        do {
            await commitInterlock?.beforeSnapshotCommit(sourceID: snapshot.sourceID)
            let generations = try database.commitSnapshotRefreshAndInvalidateRuns(snapshot)
            await agentRuntime.completeSourceRevisionRefresh(
                lease: lease,
                generations: generations
            )
        } catch {
            await agentRuntime.abortSourceRevisionRefresh(lease: lease)
            throw error
        }
    }
}

private enum LegacyProgressMigration {
    static let kind = "legacy-progress-v1"

    static func backUpIfNeeded(
        layout: ApplicationSupportLayout,
        pool: DatabasePool,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: layout.legacyProgressURL.path) else {
            return
        }

        let alreadyMigrated = try pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM migration_manifest WHERE kind = ?)",
                arguments: [kind]
            ) ?? false
        }
        guard !alreadyMigrated else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: .now)
        var destination = layout.legacyURL
            .appendingPathComponent("progress-v1-\(timestamp).json", isDirectory: false)
        if fileManager.fileExists(atPath: destination.path) {
            destination = layout.legacyURL.appendingPathComponent(
                "progress-v1-\(timestamp)-\(UUID().uuidString.lowercased()).json",
                isDirectory: false
            )
        }

        try fileManager.moveItem(at: layout.legacyProgressURL, to: destination)
        do {
            let detail = try JSONSerialization.data(
                withJSONObject: [
                    "boundToNewObjects": false,
                    "reason": "Legacy graph identity is not compatible with Library v2",
                ],
                options: [.sortedKeys]
            )
            try pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO migration_manifest
                            (id, kind, source_path, destination_path, detail_json, migrated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString.lowercased(),
                        kind,
                        "progress-v1.json",
                        try layout.relativePath(for: destination),
                        detail,
                        Date.now,
                    ]
                )
            }
        } catch {
            try? fileManager.moveItem(at: destination, to: layout.legacyProgressURL)
            throw error
        }
    }
}
