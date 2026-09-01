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
    static let schemaVersion = 9
    static let adapterSchemaVersion = 1
    static let agentRuntimeSchemaVersion = 5

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
        try recoverInterruptedObservationIndexes()
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
        createsSpace: Bool,
        accessBookmark: Data? = nil
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

            if let accessBookmark {
                try db.execute(
                    sql: """
                        INSERT INTO source_access_bookmarks
                            (source_id, bookmark_data, updated_at)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [source.id, accessBookmark, Date.now]
                )
            }

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

    func sourceAccessBookmark(sourceID: String) throws -> Data? {
        try pool.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT bookmark_data FROM source_access_bookmarks WHERE source_id = ?",
                arguments: [sourceID]
            )
        }
    }

    func saveSourceAccessBookmark(_ data: Data, sourceID: String) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source_access_bookmarks
                        (source_id, bookmark_data, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(source_id) DO UPDATE SET
                        bookmark_data = excluded.bookmark_data,
                        updated_at = excluded.updated_at
                    """,
                arguments: [sourceID, data, Date.now]
            )
        }
    }

    func commitSnapshotRefreshAndInvalidateRuns(
        _ snapshot: SourceSnapshot,
        migrations: SourceRevisionMigrationBatch = .empty
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

            for migration in migrations.annotations {
                guard migration.state != .current else {
                    throw ReaderPersistenceError.invalidAnnotation(
                        "刷新迁移不能把旧 Snapshot 标记为 current"
                    )
                }
                try db.execute(
                    sql: """
                        UPDATE annotations
                        SET anchor_state = ?, updated_at = ?
                        WHERE id = ? AND source_id = ?
                        """,
                    arguments: [
                        migration.state.rawValue,
                        snapshot.observedAt,
                        migration.annotationID,
                        snapshot.sourceID,
                    ]
                )
                guard db.changesCount == 1 else {
                    throw ReaderPersistenceError.invalidAnnotation(
                        "待迁移标注不存在或不属于刷新来源"
                    )
                }
            }

            for migration in migrations.positions {
                guard migration.sourceID == snapshot.sourceID,
                      spaceIDs.contains(migration.spaceID) else {
                    throw ReaderPersistenceError.invalidProgress(
                        "刷新位置不属于当前来源或 Reading Space"
                    )
                }
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT schema_version, payload_json FROM reading_progress WHERE space_id = ?",
                    arguments: [migration.spaceID]
                ) else { continue }
                let schema: Int = row["schema_version"]
                guard schema == ReadingProgress.currentSchemaVersion else {
                    throw ReaderPersistenceError.unsupportedProgressSchema(schema)
                }
                let payload: Data = row["payload_json"]
                var progress = try JSONDecoder.databaseDecoder.decode(
                    ReadingProgress.self,
                    from: payload
                )
                if let resolved = migration.resolvedLocator {
                    guard resolved.sourceID == snapshot.sourceID,
                          resolved.snapshotID == snapshot.id else {
                        throw ReaderPersistenceError.invalidProgress(
                            "刷新后的阅读位置未绑定新 Snapshot"
                        )
                    }
                    progress.sourcePositions[snapshot.sourceID] = SourcePosition(
                        sourceID: snapshot.sourceID,
                        locator: resolved,
                        updatedAt: snapshot.observedAt
                    )
                } else {
                    progress.sourcePositions[snapshot.sourceID] = nil
                }
                progress.lastActiveAt = snapshot.observedAt
                try db.execute(
                    sql: """
                        UPDATE reading_progress
                        SET payload_json = ?, updated_at = ?
                        WHERE space_id = ?
                        """,
                    arguments: [
                        try JSONEncoder.databaseEncoder.encode(progress),
                        progress.lastActiveAt,
                        migration.spaceID,
                    ]
                )
            }
            let metadata = try JSONEncoder.databaseEncoder.encode([
                "category": "source-revision-changed",
                "sourceID": snapshot.sourceID,
                "snapshotID": snapshot.id,
            ])
            return try Self.invalidateAgentRuns(
                in: db,
                spaceIDs: spaceIDs,
                errorCategory: "source-revision-changed",
                phase: "revision",
                message: "来源版本已刷新；旧 Run 已取消。",
                metadata: metadata
            )
        }
    }

    #if DEBUG
    func commitSnapshotRefreshForTesting(
        _ snapshot: SourceSnapshot,
        migrations: SourceRevisionMigrationBatch = .empty
    ) throws {
        _ = try commitSnapshotRefreshAndInvalidateRuns(snapshot, migrations: migrations)
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

    func commitRemoval(sourceID: String) throws -> [String: Int] {
        try pool.write { db in
            let spaceIDs = try String.fetchAll(
                db,
                sql: "SELECT space_id FROM space_sources WHERE source_id = ? ORDER BY space_id",
                arguments: [sourceID]
            )
            let metadata = try JSONEncoder.databaseEncoder.encode([
                "category": "source-removed",
                "sourceID": sourceID,
            ])
            let generations = try Self.invalidateAgentRuns(
                in: db,
                spaceIDs: spaceIDs,
                errorCategory: "source-removed",
                phase: "source",
                message: "来源已移除；旧 Run 已取消。",
                metadata: metadata
            )

            try db.execute(
                sql: "DELETE FROM annotations WHERE source_id = ?",
                arguments: [sourceID]
            )
            try db.execute(
                sql: "DELETE FROM reading_history WHERE source_id = ?",
                arguments: [sourceID]
            )
            try db.execute(
                sql: "DELETE FROM source_access_bookmarks WHERE source_id = ?",
                arguments: [sourceID]
            )
            for spaceID in spaceIDs {
                if let row = try Row.fetchOne(
                    db,
                    sql: "SELECT schema_version, payload_json FROM reading_progress WHERE space_id = ?",
                    arguments: [spaceID]
                ) {
                    let schema: Int = row["schema_version"]
                    guard schema == ReadingProgress.currentSchemaVersion else {
                        throw ReaderPersistenceError.unsupportedProgressSchema(schema)
                    }
                    let payload: Data = row["payload_json"]
                    var progress = try JSONDecoder.databaseDecoder.decode(
                        ReadingProgress.self,
                        from: payload
                    )
                    progress.sourcePositions[sourceID] = nil
                    progress.graphVersion = nil
                    progress.currentUnitID = nil
                    progress.currentPlanStepID = nil
                    progress.units = [:]
                    progress.lastActiveAt = .now
                    try db.execute(
                        sql: "UPDATE reading_progress SET payload_json = ?, updated_at = ? WHERE space_id = ?",
                        arguments: [
                            try JSONEncoder.databaseEncoder.encode(progress),
                            progress.lastActiveAt,
                            spaceID,
                        ]
                    )
                }
                try db.execute(
                    sql: "DELETE FROM reading_plans WHERE space_id = ?",
                    arguments: [spaceID]
                )
                try db.execute(
                    sql: "DELETE FROM reading_graphs WHERE space_id = ?",
                    arguments: [spaceID]
                )
            }

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
            return generations
        }
    }

    private static func invalidateAgentRuns(
        in db: Database,
        spaceIDs: [String],
        errorCategory: String,
        phase: String,
        message: String,
        metadata: Data
    ) throws -> [String: Int] {
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
                        SET state = 'cancelled', finished_at = ?, error_category = ?
                        WHERE id = ? AND state IN ('queued', 'running', 'waitingForUser')
                        """,
                    arguments: [Date.now, errorCategory, runID]
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
                        VALUES (?, ?, ?, 'cancelled', ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString.lowercased(),
                        runID,
                        sequence,
                        phase,
                        message,
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
            try db.execute(
                sql: """
                    INSERT INTO active_adapter_plans (snapshot_id, plan_id, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(snapshot_id) DO UPDATE SET
                        plan_id = excluded.plan_id,
                        updated_at = excluded.updated_at
                    """,
                arguments: [plan.snapshotID, plan.id, Date.now]
            )
        }
    }

    func fetchAdapterPlan(snapshotID: String) throws -> AdapterPlan? {
        try pool.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: """
                    SELECT adapter_plans.payload_json
                    FROM active_adapter_plans
                    JOIN adapter_plans ON adapter_plans.id = active_adapter_plans.plan_id
                    WHERE active_adapter_plans.snapshot_id = ?
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
        }
    }

    func beginObservationIndex(snapshotID: String, planID: String) throws -> String {
        let generationID = UUID().uuidString.lowercased()
        try pool.write { db in
            guard try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM active_adapter_plans
                        JOIN adapter_plans ON adapter_plans.id = active_adapter_plans.plan_id
                        WHERE active_adapter_plans.plan_id = ?
                          AND active_adapter_plans.snapshot_id = ?
                    )
                    """,
                arguments: [planID, snapshotID]
            ) ?? false else {
                throw AdapterError.unsupportedContent("索引计划与 Snapshot 不匹配")
            }
            if let previousGeneration = try String.fetchOne(
                db,
                sql: """
                    SELECT generation_id FROM observation_index_runs
                    WHERE snapshot_id = ? AND plan_id = ?
                    """,
                arguments: [snapshotID, planID]
            ) {
                try db.execute(
                    sql: "DELETE FROM observation_index_staging WHERE generation_id = ?",
                    arguments: [previousGeneration]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO observation_index_runs
                        (snapshot_id, plan_id, generation_id, state,
                         observation_count, started_at, completed_at, error_category)
                    VALUES (?, ?, ?, 'running', 0, ?, NULL, NULL)
                    ON CONFLICT(snapshot_id, plan_id) DO UPDATE SET
                        generation_id = excluded.generation_id,
                        state = 'running',
                        observation_count = 0,
                        started_at = excluded.started_at,
                        completed_at = NULL,
                        error_category = NULL
                    """,
                arguments: [snapshotID, planID, generationID, Date.now]
            )
        }
        return generationID
    }

    func stageObservation(
        _ observation: Observation,
        title: String?,
        generationID: String
    ) throws {
        let locatorJSON = try JSONEncoder.databaseEncoder.encode(observation.locator)
        try pool.write { db in
            guard try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM observation_index_runs
                        WHERE snapshot_id = ? AND generation_id = ? AND state = 'running'
                    )
                    """,
                arguments: [observation.snapshotID, generationID]
            ) ?? false else {
                throw CancellationError()
            }
            try db.execute(
                sql: """
                    INSERT INTO observation_index_staging
                        (generation_id, observation_id, source_id, snapshot_id, adapter_id,
                         locator_json, media_type, title, body, content_reference,
                         digest, truncated, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(generation_id, observation_id) DO UPDATE SET
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
                    generationID,
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
        }
    }

    func completeObservationIndex(
        snapshotID: String,
        planID: String,
        generationID: String
    ) throws {
        try pool.write { db in
            guard try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM observation_index_runs
                        JOIN active_adapter_plans
                          ON active_adapter_plans.snapshot_id = observation_index_runs.snapshot_id
                         AND active_adapter_plans.plan_id = observation_index_runs.plan_id
                        WHERE observation_index_runs.snapshot_id = ?
                          AND observation_index_runs.plan_id = ?
                          AND observation_index_runs.generation_id = ?
                          AND observation_index_runs.state = 'running'
                    )
                    """,
                arguments: [snapshotID, planID, generationID]
            ) ?? false else { throw CancellationError() }
            try db.execute(
                sql: "DELETE FROM search_document_fts WHERE plan_id = ?",
                arguments: [planID]
            )
            try db.execute(
                sql: "DELETE FROM search_documents WHERE plan_id = ?",
                arguments: [planID]
            )
            try db.execute(
                sql: """
                    INSERT INTO search_documents
                        (document_key, plan_id, observation_id, source_id,
                         snapshot_id, adapter_id, locator_json,
                         media_type, title, body, content_reference, digest,
                         truncated, created_at)
                    SELECT ? || ':' || observation_id, ?, observation_id, source_id,
                           snapshot_id, adapter_id, locator_json,
                           media_type, title, body, content_reference, digest,
                           truncated, created_at
                    FROM observation_index_staging
                    WHERE generation_id = ? AND snapshot_id = ?
                    ORDER BY observation_id
                    """,
                arguments: [planID, planID, generationID, snapshotID]
            )
            try db.execute(
                sql: """
                    INSERT INTO search_document_fts
                        (document_key, plan_id, source_id, snapshot_id, title, body)
                    SELECT document_key, plan_id, source_id, snapshot_id,
                           COALESCE(title, ''), COALESCE(body, '')
                    FROM search_documents
                    WHERE plan_id = ?
                    ORDER BY created_at, document_key
                    """,
                arguments: [planID]
            )
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM search_documents WHERE plan_id = ?",
                arguments: [planID]
            ) ?? 0
            try db.execute(
                sql: """
                    UPDATE observation_index_runs
                    SET state = 'completed', observation_count = ?,
                        completed_at = ?, error_category = NULL
                    WHERE snapshot_id = ? AND plan_id = ?
                      AND generation_id = ? AND state = 'running'
                    """,
                arguments: [count, Date.now, snapshotID, planID, generationID]
            )
            guard db.changesCount == 1 else { throw CancellationError() }
            try db.execute(
                sql: "DELETE FROM observation_index_staging WHERE generation_id = ?",
                arguments: [generationID]
            )
        }
    }

    func failObservationIndex(
        snapshotID: String,
        planID: String,
        generationID: String,
        category: String
    ) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    UPDATE observation_index_runs
                    SET state = 'failed', completed_at = ?, error_category = ?
                    WHERE snapshot_id = ? AND plan_id = ?
                      AND generation_id = ? AND state = 'running'
                    """,
                arguments: [Date.now, category, snapshotID, planID, generationID]
            )
            try db.execute(
                sql: "DELETE FROM observation_index_staging WHERE generation_id = ?",
                arguments: [generationID]
            )
        }
    }

    func isObservationIndexComplete(snapshotID: String, planID: String) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM observation_index_runs
                        JOIN active_adapter_plans
                          ON active_adapter_plans.snapshot_id = observation_index_runs.snapshot_id
                         AND active_adapter_plans.plan_id = observation_index_runs.plan_id
                        WHERE observation_index_runs.snapshot_id = ?
                          AND observation_index_runs.plan_id = ?
                          AND observation_index_runs.state = 'completed'
                    )
                    """,
                arguments: [snapshotID, planID]
            ) ?? false
        }
    }

    private func recoverInterruptedObservationIndexes() throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    UPDATE observation_index_runs
                    SET state = 'failed', completed_at = ?, error_category = 'interrupted'
                    WHERE state = 'running'
                    """,
                arguments: [Date.now]
            )
            try db.execute(sql: "DELETE FROM observation_index_staging")
        }
    }

    func searchObservations(
        query: String,
        snapshotID: String? = nil,
        planID: String? = nil,
        limit: Int = 20
    ) throws -> [ContentSearchHit] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { term in
            "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        guard !terms.isEmpty else { return [] }
        let matchQuery = terms.joined(separator: " AND ")
        return try pool.read { db in
            var sql = """
                SELECT search_documents.locator_json,
                       search_documents.source_id,
                       search_documents.snapshot_id,
                       search_documents.adapter_id,
                       COALESCE(search_documents.title, '') AS title,
                       COALESCE(search_documents.body, '') AS body,
                       snippet(search_document_fts, 5, '[', ']', ' … ', 24) AS context,
                       bm25(search_document_fts) AS score
                FROM search_document_fts
                JOIN search_documents
                  ON search_documents.document_key = search_document_fts.document_key
                 AND search_documents.plan_id = search_document_fts.plan_id
                JOIN active_adapter_plans
                  ON active_adapter_plans.snapshot_id = search_documents.snapshot_id
                 AND active_adapter_plans.plan_id = search_documents.plan_id
                JOIN observation_index_runs
                  ON observation_index_runs.snapshot_id = search_documents.snapshot_id
                 AND observation_index_runs.plan_id = search_documents.plan_id
                 AND observation_index_runs.state = 'completed'
                JOIN sources
                  ON sources.id = search_documents.source_id
                 AND sources.latest_snapshot_id = search_documents.snapshot_id
                WHERE search_document_fts MATCH ?
                  AND sources.managed_state != 'removed'
                """
            var arguments: StatementArguments = [matchQuery]
            if let snapshotID {
                sql += " AND search_documents.snapshot_id = ?"
                arguments += [snapshotID]
            }
            if let planID {
                sql += " AND search_documents.plan_id = ?"
                arguments += [planID]
            }
            sql += " ORDER BY score LIMIT ?"
            arguments += [min(max(1, limit), 20)]
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            if !rows.isEmpty {
                return try rows.enumerated().map { index, row in
                    let locatorData: Data = row["locator_json"]
                    let rootLocator = try JSONDecoder.databaseDecoder.decode(
                        Locator.self,
                        from: locatorData
                    )
                    let sourceID: String = row["source_id"]
                    let rowSnapshotID: String = row["snapshot_id"]
                    let adapterID: String = row["adapter_id"]
                    let title: String = row["title"]
                    let body: String = row["body"]
                    let indexedContext: String = row["context"]
                    let score: Double = row["score"]
                    let anchored = Self.searchAnchor(
                        rootLocator: rootLocator,
                        body: body,
                        query: query
                    )
                    let locator = anchored?.locator ?? rootLocator
                    let context = anchored?.context ?? indexedContext
                    return ContentSearchHit(
                        id: "fts:\(locator.stableID):\(anchored?.utf16Offset ?? -1):\(index)",
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

            // unicode61 tokenizes long CJK runs as a single token. Keep FTS as the
            // fast path, then use a bounded exact-substring query so Chinese and
            // other unsegmented scripts remain searchable without rescanning the
            // complete managed directory tree.
            var fallbackSQL = """
                SELECT search_documents.locator_json,
                       search_documents.source_id,
                       search_documents.snapshot_id,
                       search_documents.adapter_id,
                       COALESCE(search_documents.title, '') AS title,
                       COALESCE(search_documents.body, '') AS body
                FROM search_documents
                JOIN active_adapter_plans
                  ON active_adapter_plans.snapshot_id = search_documents.snapshot_id
                 AND active_adapter_plans.plan_id = search_documents.plan_id
                JOIN observation_index_runs
                  ON observation_index_runs.snapshot_id = search_documents.snapshot_id
                 AND observation_index_runs.plan_id = search_documents.plan_id
                 AND observation_index_runs.state = 'completed'
                JOIN sources
                  ON sources.id = search_documents.source_id
                 AND sources.latest_snapshot_id = search_documents.snapshot_id
                WHERE sources.managed_state != 'removed'
                  AND (
                    instr(lower(COALESCE(search_documents.title, '')), lower(?)) > 0
                    OR instr(lower(COALESCE(search_documents.body, '')), lower(?)) > 0
                  )
                """
            var fallbackArguments: StatementArguments = [query, query]
            if let snapshotID {
                fallbackSQL += " AND search_documents.snapshot_id = ?"
                fallbackArguments += [snapshotID]
            }
            if let planID {
                fallbackSQL += " AND search_documents.plan_id = ?"
                fallbackArguments += [planID]
            }
            fallbackSQL += " ORDER BY search_documents.created_at DESC, search_documents.document_key LIMIT ?"
            fallbackArguments += [min(max(1, limit), 20)]
            let fallbackRows = try Row.fetchAll(
                db,
                sql: fallbackSQL,
                arguments: fallbackArguments
            )
            return try fallbackRows.enumerated().map { index, row in
                let locatorData: Data = row["locator_json"]
                let rootLocator = try JSONDecoder.databaseDecoder.decode(
                    Locator.self,
                    from: locatorData
                )
                let sourceID: String = row["source_id"]
                let rowSnapshotID: String = row["snapshot_id"]
                let adapterID: String = row["adapter_id"]
                let title: String = row["title"]
                let body: String = row["body"]
                let anchored = Self.searchAnchor(
                    rootLocator: rootLocator,
                    body: body,
                    query: query
                )
                let locator = anchored?.locator ?? rootLocator
                let context = anchored?.context ?? title
                return ContentSearchHit(
                    id: "substring:\(locator.stableID):\(anchored?.utf16Offset ?? -1):\(index)",
                    sourceID: sourceID,
                    snapshotID: rowSnapshotID,
                    adapterID: adapterID,
                    locator: locator,
                    title: title,
                    context: context,
                    rank: 0.5 / Double(index + 1)
                )
            }
        }
    }

    private static func searchAnchor(
        rootLocator: Locator,
        body: String,
        query: String
    ) -> (locator: Locator, context: String, utf16Offset: Int)? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !body.isEmpty else { return nil }
        let candidates = [normalized] + normalized
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
            .filter { $0 != normalized }
        guard let range = candidates.lazy.compactMap({ candidate in
            body.range(
                of: candidate,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
        }).first else { return nil }

        let exact = String(body[range])
        let prefixStart = body.index(
            range.lowerBound,
            offsetBy: -48,
            limitedBy: body.startIndex
        ) ?? body.startIndex
        let suffixEnd = body.index(
            range.upperBound,
            offsetBy: 48,
            limitedBy: body.endIndex
        ) ?? body.endIndex
        let prefix = String(body[prefixStart..<range.lowerBound])
        let suffix = String(body[range.upperBound..<suffixEnd])
        let utf16Range = NSRange(range, in: body)
        let startLine = body[..<range.lowerBound].reduce(1) { partial, character in
            character == "\n" ? partial + 1 : partial
        }
        let endLine = body[range].reduce(startLine) { partial, character in
            character == "\n" ? partial + 1 : partial
        }
        var payload = rootLocator.payload
        payload["startUTF16"] = String(utf16Range.location)
        payload["endUTF16"] = String(NSMaxRange(utf16Range))
        payload["startLine"] = String(startLine)
        payload["endLine"] = String(endLine)
        let locator = Locator(
            sourceID: rootLocator.sourceID,
            snapshotID: rootLocator.snapshotID,
            adapterID: rootLocator.adapterID,
            schemaVersion: rootLocator.schemaVersion,
            payload: payload,
            structuralPath: rootLocator.structuralPath,
            textQuote: TextQuote(
                prefix: prefix.isEmpty ? nil : prefix,
                exact: exact,
                suffix: suffix.isEmpty ? nil : suffix
            ),
            fingerprint: AdapterUtilities.sha256(exact)
        )
        return (
            locator,
            AdapterUtilities.excerpt(from: body, matching: range),
            utf16Range.location
        )
    }

    func rebuildObservationIndex() throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM search_document_fts")
            try db.execute(sql: """
                INSERT INTO search_document_fts
                    (document_key, plan_id, source_id, snapshot_id, title, body)
                SELECT document_key, plan_id, source_id, snapshot_id,
                       COALESCE(title, ''), COALESCE(body, '')
                FROM search_documents
                ORDER BY created_at, document_key
                """)
        }
    }

    func searchDocumentCount(
        planID: String? = nil,
        adapterID: String? = nil
    ) throws -> Int {
        try pool.read { db in
            var sql = "SELECT COUNT(*) FROM search_documents WHERE 1 = 1"
            var arguments = StatementArguments()
            if let planID {
                sql += " AND plan_id = ?"
                arguments += [planID]
            }
            if let adapterID {
                sql += " AND adapter_id = ?"
                arguments += [adapterID]
            }
            return try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
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

    func observationCount(snapshotID: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM observations WHERE snapshot_id = ?",
                arguments: [snapshotID]
            ) ?? 0
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

        migrator.registerMigration("v7-atomic-observation-index") { db in
            try db.execute(sql: """
                CREATE TABLE observation_index_runs (
                    snapshot_id TEXT PRIMARY KEY NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
                    plan_id TEXT NOT NULL REFERENCES adapter_plans(id) ON DELETE CASCADE,
                    generation_id TEXT NOT NULL,
                    state TEXT NOT NULL,
                    observation_count INTEGER NOT NULL DEFAULT 0,
                    started_at DATETIME NOT NULL,
                    completed_at DATETIME,
                    error_category TEXT
                );

                CREATE TABLE observation_index_staging (
                    generation_id TEXT NOT NULL,
                    observation_id TEXT NOT NULL,
                    source_id TEXT NOT NULL,
                    snapshot_id TEXT NOT NULL,
                    adapter_id TEXT NOT NULL,
                    locator_json BLOB NOT NULL,
                    media_type TEXT NOT NULL,
                    title TEXT,
                    body TEXT,
                    content_reference TEXT,
                    digest TEXT NOT NULL,
                    truncated INTEGER NOT NULL,
                    created_at DATETIME NOT NULL,
                    PRIMARY KEY (generation_id, observation_id)
                );
                CREATE INDEX observation_index_staging_snapshot
                    ON observation_index_staging(snapshot_id, generation_id);

                UPDATE library_metadata SET value = '7' WHERE key = 'database_schema';
                """)
        }

        migrator.registerMigration("v8-source-access-bookmarks") { db in
            try db.execute(sql: """
                CREATE TABLE source_access_bookmarks (
                    source_id TEXT PRIMARY KEY NOT NULL
                        REFERENCES sources(id) ON DELETE CASCADE,
                    bookmark_data BLOB NOT NULL,
                    updated_at DATETIME NOT NULL
                );

                UPDATE library_metadata SET value = '8' WHERE key = 'database_schema';
                """)
        }

        migrator.registerMigration("v9-plan-bound-search-projection") { db in
            try db.execute(sql: """
                CREATE TABLE active_adapter_plans (
                    snapshot_id TEXT PRIMARY KEY NOT NULL
                        REFERENCES snapshots(id) ON DELETE CASCADE,
                    plan_id TEXT NOT NULL UNIQUE
                        REFERENCES adapter_plans(id) ON DELETE CASCADE,
                    updated_at DATETIME NOT NULL
                );

                INSERT INTO active_adapter_plans (snapshot_id, plan_id, updated_at)
                SELECT snapshot_id, id, created_at
                FROM (
                    SELECT snapshot_id, id, created_at,
                           ROW_NUMBER() OVER (
                               PARTITION BY snapshot_id
                               ORDER BY is_user_override DESC, created_at DESC, id DESC
                           ) AS rank
                    FROM adapter_plans
                )
                WHERE rank = 1;

                ALTER TABLE observation_index_runs
                    RENAME TO observation_index_runs_v7;
                CREATE TABLE observation_index_runs (
                    snapshot_id TEXT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
                    plan_id TEXT NOT NULL REFERENCES adapter_plans(id) ON DELETE CASCADE,
                    generation_id TEXT NOT NULL UNIQUE,
                    state TEXT NOT NULL,
                    observation_count INTEGER NOT NULL DEFAULT 0,
                    started_at DATETIME NOT NULL,
                    completed_at DATETIME,
                    error_category TEXT,
                    PRIMARY KEY (snapshot_id, plan_id)
                );
                DROP TABLE observation_index_runs_v7;
                DELETE FROM observation_index_staging;

                CREATE TABLE search_documents (
                    document_key TEXT PRIMARY KEY NOT NULL,
                    plan_id TEXT NOT NULL REFERENCES adapter_plans(id) ON DELETE CASCADE,
                    observation_id TEXT NOT NULL,
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
                    created_at DATETIME NOT NULL,
                    UNIQUE (plan_id, observation_id)
                );
                CREATE INDEX search_documents_snapshot_plan
                    ON search_documents(snapshot_id, plan_id, adapter_id);
                CREATE VIRTUAL TABLE search_document_fts USING fts5(
                    document_key UNINDEXED,
                    plan_id UNINDEXED,
                    source_id UNINDEXED,
                    snapshot_id UNINDEXED,
                    title,
                    body,
                    tokenize = 'unicode61 remove_diacritics 2'
                );

                DROP TABLE observation_fts;

                UPDATE library_metadata SET value = '9' WHERE key = 'database_schema';
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

struct AnnotationRevisionMigration: Sendable, Equatable {
    let annotationID: String
    let state: AnnotationAnchorState
}

struct SourcePositionRevisionMigration: Sendable, Equatable {
    let spaceID: String
    let sourceID: String
    let resolvedLocator: Locator?
}

struct SourceRevisionMigrationBatch: Sendable, Equatable {
    let annotations: [AnnotationRevisionMigration]
    let positions: [SourcePositionRevisionMigration]

    static let empty = SourceRevisionMigrationBatch(annotations: [], positions: [])
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
