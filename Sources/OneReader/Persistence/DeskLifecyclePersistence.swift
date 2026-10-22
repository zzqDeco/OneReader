import Foundation
import GRDB

extension LibraryDatabase {
    func renameSpace(id: String, title: String) throws {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ReaderPersistenceError.invalidProgress("空间名称不能为空")
        }
        try pool.write { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM reading_spaces WHERE id = ?)",
                arguments: [id]
            ) ?? false else {
                throw LibraryStorageError.missingSpace(id)
            }
            try db.execute(
                sql: "UPDATE reading_spaces SET title = ?, updated_at = ? WHERE id = ?",
                arguments: [normalized, Date.now, id]
            )
        }
    }

    func renameSource(id: String, displayName: String) throws {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ReaderPersistenceError.invalidProgress("来源名称不能为空")
        }
        try pool.write { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sources WHERE id = ? AND managed_state != 'removed')",
                arguments: [id]
            ) ?? false else {
                throw LibraryStorageError.missingSource(id)
            }
            try db.execute(
                sql: "UPDATE sources SET display_name = ?, updated_at = ? WHERE id = ?",
                arguments: [normalized, Date.now, id]
            )
        }
    }

    func exclusivelyOwnedSourceIDs(inSpaceID spaceID: String) throws -> [String] {
        try pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT source_id
                    FROM space_sources
                    WHERE space_id = ?
                      AND source_id NOT IN (
                          SELECT source_id FROM space_sources WHERE space_id != ?
                      )
                    ORDER BY added_at ASC, source_id ASC
                    """,
                arguments: [spaceID, spaceID]
            )
        }
    }

    func attachSourceToSpace(sourceID: String, spaceID: String) throws {
        try pool.write { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM reading_spaces WHERE id = ?)",
                arguments: [spaceID]
            ) ?? false else {
                throw LibraryStorageError.missingSpace(spaceID)
            }
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sources WHERE id = ? AND managed_state != 'removed')",
                arguments: [sourceID]
            ) ?? false else {
                throw LibraryStorageError.missingSource(sourceID)
            }
            let position = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM space_sources WHERE space_id = ?",
                arguments: [spaceID]
            ) ?? 0
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO space_sources (space_id, source_id, position, added_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [spaceID, sourceID, position, Date.now]
            )
        }
    }

    func detachSourceFromSpace(sourceID: String, spaceID: String) throws -> Int? {
        try pool.write { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM reading_spaces WHERE id = ?)",
                arguments: [spaceID]
            ) ?? false else {
                throw LibraryStorageError.missingSpace(spaceID)
            }
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM space_sources WHERE space_id = ? AND source_id = ?)",
                arguments: [spaceID, sourceID]
            ) ?? false else {
                throw LibraryStorageError.missingSource(sourceID)
            }

            try db.execute(
                sql: "DELETE FROM space_sources WHERE space_id = ? AND source_id = ?",
                arguments: [spaceID, sourceID]
            )

            let destinationSpaceID: String
            let createdStandaloneSpace: Bool
            if let survivingSpaceID = try String.fetchOne(
                db,
                sql: """
                    SELECT space_id
                    FROM space_sources
                    WHERE source_id = ? AND space_id != ?
                    ORDER BY added_at ASC, space_id ASC
                    LIMIT 1
                    """,
                arguments: [sourceID, spaceID]
            ) {
                destinationSpaceID = survivingSpaceID
                createdStandaloneSpace = false
            } else {
                let standaloneSpaceID = try Self.createStandaloneSpaceForDetachedSource(
                    db: db,
                    sourceID: sourceID,
                    originSpaceID: spaceID
                )
                destinationSpaceID = standaloneSpaceID
                createdStandaloneSpace = true
            }

            try db.execute(
                sql: "UPDATE annotations SET space_id = ? WHERE space_id = ? AND source_id = ?",
                arguments: [destinationSpaceID, spaceID, sourceID]
            )

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
                var progress = try Self.deskLifecycleDecoder.decode(
                    ReadingProgress.self,
                    from: payload
                )
                let detachedPosition = progress.sourcePositions[sourceID]
                progress.sourcePositions[sourceID] = nil
                progress.sourceRoles[sourceID] = nil
                progress.graphVersion = nil
                progress.currentUnitID = nil
                progress.currentPlanStepID = nil
                progress.units = [:]
                progress.lastActiveAt = .now
                try db.execute(
                    sql: "UPDATE reading_progress SET payload_json = ?, updated_at = ? WHERE space_id = ?",
                    arguments: [
                        try Self.deskLifecycleEncoder.encode(progress),
                        progress.lastActiveAt,
                        spaceID,
                    ]
                )

                if createdStandaloneSpace, let detachedPosition {
                    let standaloneProgress = ReadingProgress(
                        sourcePositions: [sourceID: detachedPosition],
                        lastActiveAt: detachedPosition.updatedAt
                    )
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO reading_progress
                                (space_id, schema_version, payload_json, updated_at)
                            VALUES (?, ?, ?, ?)
                            """,
                        arguments: [
                            destinationSpaceID,
                            standaloneProgress.schemaVersion,
                            try Self.deskLifecycleEncoder.encode(standaloneProgress),
                            standaloneProgress.lastActiveAt,
                        ]
                    )
                }
            }

            try db.execute(
                sql: "DELETE FROM reading_plans WHERE space_id = ?",
                arguments: [spaceID]
            )
            try db.execute(
                sql: "DELETE FROM reading_graphs WHERE space_id = ?",
                arguments: [spaceID]
            )
            try db.execute(
                sql: "DELETE FROM reading_history WHERE space_id = ? AND source_id = ?",
                arguments: [spaceID, sourceID]
            )

            let metadata = try Self.deskLifecycleEncoder.encode([
                "category": "source-detached",
                "sourceID": sourceID,
            ])
            let runRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM agent_runs
                    WHERE space_id = ?
                      AND state IN ('queued', 'running', 'waitingForUser', 'interrupted')
                    ORDER BY created_at, id
                    """,
                arguments: [spaceID]
            )
            for runRow in runRows {
                let runID: String = runRow["id"]
                try db.execute(
                    sql: """
                        UPDATE agent_runs
                        SET state = 'cancelled', finished_at = ?, error_category = 'source-detached'
                        WHERE id = ?
                          AND state IN ('queued', 'running', 'waitingForUser', 'interrupted')
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
                        VALUES (?, ?, ?, 'cancelled', 'source', '来源已移出当前阅读空间；旧 Run 已取消。', ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString.lowercased(),
                        runID,
                        sequence,
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
            return try Int.fetchOne(
                db,
                sql: "SELECT generation FROM reading_agent_sessions WHERE space_id = ?",
                arguments: [spaceID]
            )
        }
    }

    func deleteSpaceRecord(id spaceID: String) throws {
        try pool.write { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM reading_spaces WHERE id = ?)",
                arguments: [spaceID]
            ) ?? false else {
                throw LibraryStorageError.missingSpace(spaceID)
            }

            try db.execute(
                sql: """
                    UPDATE annotations
                    SET space_id = (
                        SELECT space_id
                        FROM space_sources
                        WHERE space_sources.source_id = annotations.source_id
                          AND space_sources.space_id != ?
                        ORDER BY added_at ASC, space_id ASC
                        LIMIT 1
                    )
                    WHERE space_id = ?
                      AND EXISTS (
                          SELECT 1
                          FROM space_sources
                          WHERE space_sources.source_id = annotations.source_id
                            AND space_sources.space_id != ?
                      )
                    """,
                arguments: [spaceID, spaceID, spaceID]
            )

            // Defensive safeguard: if any surviving (non-removed) source still has
            // annotations bound to this space without another space_sources entry,
            // promote it into a standalone space so ON DELETE CASCADE never drops its notes.
            let unattachedAnnotationSourceIDs = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT annotations.source_id
                    FROM annotations
                    JOIN sources ON sources.id = annotations.source_id
                    WHERE annotations.space_id = ?
                      AND sources.managed_state != 'removed'
                      AND NOT EXISTS (
                          SELECT 1
                          FROM space_sources
                          WHERE space_sources.source_id = annotations.source_id
                            AND space_sources.space_id = ?
                      )
                    ORDER BY annotations.source_id ASC
                    """,
                arguments: [spaceID, spaceID]
            )
            for sourceID in unattachedAnnotationSourceIDs {
                let standaloneSpaceID = try Self.createStandaloneSpaceForDetachedSource(
                    db: db,
                    sourceID: sourceID,
                    originSpaceID: spaceID
                )
                try db.execute(
                    sql: "UPDATE annotations SET space_id = ? WHERE space_id = ? AND source_id = ?",
                    arguments: [standaloneSpaceID, spaceID, sourceID]
                )
            }

            try db.execute(
                sql: "DELETE FROM reading_spaces WHERE id = ?",
                arguments: [spaceID]
            )
        }
    }

    private static func createStandaloneSpaceForDetachedSource(
        db: Database,
        sourceID: String,
        originSpaceID: String
    ) throws -> String {
        let now = Date.now
        let sourceDisplayName = try String.fetchOne(
            db,
            sql: "SELECT display_name FROM sources WHERE id = ?",
            arguments: [sourceID]
        ) ?? sourceID
        let stem = (sourceDisplayName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let standaloneTitle = stem.isEmpty ? sourceDisplayName : stem
        let organizationState = try String.fetchOne(
            db,
            sql: "SELECT organization_state FROM reading_spaces WHERE id = ?",
            arguments: [originSpaceID]
        ) ?? SpaceOrganizationState.reading.rawValue
        let standaloneSpaceID = UUID().uuidString.lowercased()
        try db.execute(
            sql: """
                INSERT INTO reading_spaces
                    (id, title, is_favorite, created_at, updated_at, last_opened_at, organization_state)
                VALUES (?, ?, 0, ?, ?, NULL, ?)
                """,
            arguments: [standaloneSpaceID, standaloneTitle, now, now, organizationState]
        )
        try db.execute(
            sql: """
                INSERT INTO space_sources (space_id, source_id, position, added_at)
                VALUES (?, ?, 0, ?)
                """,
            arguments: [standaloneSpaceID, sourceID, now]
        )
        return standaloneSpaceID
    }

    private static var deskLifecycleEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var deskLifecycleDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
