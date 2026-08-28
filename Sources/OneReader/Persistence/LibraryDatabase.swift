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
    static let schemaVersion = 1

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

        var migrator = DatabaseMigrator()
        Self.registerMigrations(&migrator)
        try migrator.migrate(pool)
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
                exclusiveManagedRelativePaths: exclusivePaths
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
