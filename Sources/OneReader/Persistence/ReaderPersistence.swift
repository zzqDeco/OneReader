import Foundation
import GRDB

enum ReaderPersistenceError: LocalizedError, Equatable {
    case invalidAnnotation(String)
    case invalidProgress(String)
    case unsupportedProgressSchema(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAnnotation(let reason):
            "标注无法保存：\(reason)"
        case .invalidProgress(let reason):
            "阅读进度无法保存：\(reason)"
        case .unsupportedProgressSchema(let schema):
            "阅读进度来自不受支持的 schema \(schema)。"
        }
    }
}

extension LibraryDatabase {
    func updateSpace(
        id: String,
        title: String? = nil,
        isFavorite: Bool? = nil,
        openedAt: Date? = nil
    ) throws {
        try pool.write { db in
            guard try Self.rowExists(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM reading_spaces WHERE id = ?)",
                arguments: [id]
            ) else {
                throw LibraryStorageError.missingSpace(id)
            }
            if let title {
                let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else {
                    throw ReaderPersistenceError.invalidProgress("空间标题不能为空")
                }
                try db.execute(
                    sql: "UPDATE reading_spaces SET title = ?, updated_at = ? WHERE id = ?",
                    arguments: [normalized, Date.now, id]
                )
            }
            if let isFavorite {
                try db.execute(
                    sql: "UPDATE reading_spaces SET is_favorite = ?, updated_at = ? WHERE id = ?",
                    arguments: [isFavorite, Date.now, id]
                )
            }
            if let openedAt {
                try db.execute(
                    sql: "UPDATE reading_spaces SET last_opened_at = ?, updated_at = ? WHERE id = ?",
                    arguments: [openedAt, openedAt, id]
                )
            }
        }
    }

    func updateSourceFavorite(id: String, isFavorite: Bool) throws {
        try pool.write { db in
            guard try Self.rowExists(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sources WHERE id = ? AND managed_state != 'removed')",
                arguments: [id]
            ) else {
                throw LibraryStorageError.missingSource(id)
            }
            try db.execute(
                sql: "UPDATE sources SET is_favorite = ?, updated_at = ? WHERE id = ?",
                arguments: [isFavorite, Date.now, id]
            )
        }
    }

    func saveAnnotation(_ annotation: Annotation) throws {
        let locatorData = try Self.readerEncoder.encode(annotation.locator)
        try pool.write { db in
            try Self.validate(annotation: annotation, in: db)
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT space_id, source_id, snapshot_id FROM annotations WHERE id = ?",
                arguments: [annotation.id]
            ) {
                let existingSpaceID: String = existing["space_id"]
                let existingSourceID: String = existing["source_id"]
                let existingSnapshotID: String = existing["snapshot_id"]
                guard existingSpaceID == annotation.spaceID,
                      existingSourceID == annotation.sourceID,
                      existingSnapshotID == annotation.snapshotID else {
                    throw ReaderPersistenceError.invalidAnnotation(
                        "既有标注的来源身份不可改写"
                    )
                }
            }
            try db.execute(
                sql: """
                    INSERT INTO annotations
                        (id, space_id, source_id, snapshot_id, kind, locator_json,
                         anchor_state, selected_text, note, color, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        kind = excluded.kind,
                        locator_json = excluded.locator_json,
                        anchor_state = excluded.anchor_state,
                        selected_text = excluded.selected_text,
                        note = excluded.note,
                        color = excluded.color,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    annotation.id,
                    annotation.spaceID,
                    annotation.sourceID,
                    annotation.snapshotID,
                    annotation.kind.rawValue,
                    locatorData,
                    annotation.anchorState.rawValue,
                    annotation.selectedText,
                    annotation.note,
                    annotation.color,
                    annotation.createdAt,
                    annotation.updatedAt,
                ]
            )
        }
    }

    func fetchAnnotations(
        spaceID: String,
        sourceID: String? = nil
    ) throws -> [Annotation] {
        try pool.read { db in
            let rows: [Row]
            if let sourceID {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM annotations
                        WHERE space_id = ? AND source_id = ?
                        ORDER BY updated_at DESC, id
                        """,
                    arguments: [spaceID, sourceID]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM annotations
                        WHERE space_id = ?
                        ORDER BY updated_at DESC, id
                        """,
                    arguments: [spaceID]
                )
            }
            return try rows.map(Self.decodeAnnotation)
        }
    }

    func deleteAnnotation(id: String, spaceID: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM annotations WHERE id = ? AND space_id = ?",
                arguments: [id, spaceID]
            )
        }
    }

    func saveReadingProgress(_ progress: ReadingProgress, spaceID: String) throws {
        guard progress.schemaVersion == ReadingProgress.currentSchemaVersion else {
            throw ReaderPersistenceError.unsupportedProgressSchema(progress.schemaVersion)
        }
        let payload = try Self.readerEncoder.encode(progress)
        try pool.write { db in
            guard try Self.rowExists(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM reading_spaces WHERE id = ?)",
                arguments: [spaceID]
            ) else {
                throw LibraryStorageError.missingSpace(spaceID)
            }
            let sourceIDs = Set(try String.fetchAll(
                db,
                sql: "SELECT source_id FROM space_sources WHERE space_id = ?",
                arguments: [spaceID]
            ))
            for position in progress.sourcePositions.values {
                if let fraction = position.progressFraction,
                   !fraction.isFinite || !(0 ... 1).contains(fraction) {
                    throw ReaderPersistenceError.invalidProgress(
                        "来源位置的阅读百分比必须位于 0...1"
                    )
                }
                if let label = position.displayLabel, label.count > 512 {
                    throw ReaderPersistenceError.invalidProgress(
                        "来源位置的显示标签过长"
                    )
                }
                guard sourceIDs.contains(position.sourceID),
                      position.locator.sourceID == position.sourceID else {
                    throw ReaderPersistenceError.invalidProgress(
                        "来源位置不属于当前 Reading Space"
                    )
                }
                guard try Self.rowExists(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM snapshots WHERE id = ? AND source_id = ?)",
                    arguments: [position.locator.snapshotID, position.sourceID]
                ) else {
                    throw ReaderPersistenceError.invalidProgress("来源位置引用了不存在的 Snapshot")
                }
            }
            try db.execute(
                sql: """
                    INSERT INTO reading_progress
                        (space_id, schema_version, payload_json, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(space_id) DO UPDATE SET
                        schema_version = excluded.schema_version,
                        payload_json = excluded.payload_json,
                        updated_at = excluded.updated_at
                    """,
                arguments: [spaceID, progress.schemaVersion, payload, progress.lastActiveAt]
            )
        }
    }

    func fetchReadingProgress(spaceID: String) throws -> ReadingProgress {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT schema_version, payload_json FROM reading_progress WHERE space_id = ?",
                arguments: [spaceID]
            ) else { return .empty }
            let schema: Int = row["schema_version"]
            guard schema == ReadingProgress.currentSchemaVersion else {
                throw ReaderPersistenceError.unsupportedProgressSchema(schema)
            }
            let payload: Data = row["payload_json"]
            let progress = try Self.readerDecoder.decode(ReadingProgress.self, from: payload)
            guard progress.schemaVersion == schema else {
                throw ReaderPersistenceError.invalidProgress("行 schema 与 payload 不一致")
            }
            return progress
        }
    }

    func recordReadingHistory(_ entry: ReadingHistoryEntry) throws {
        let locatorData = try entry.locator.map { locator in
            try Self.readerEncoder.encode(locator)
        }
        try pool.write { db in
            guard try Self.rowExists(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM reading_spaces WHERE id = ?)",
                arguments: [entry.spaceID]
            ) else {
                throw LibraryStorageError.missingSpace(entry.spaceID)
            }
            if let sourceID = entry.sourceID {
                guard try Self.rowExists(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM space_sources WHERE space_id = ? AND source_id = ?)",
                    arguments: [entry.spaceID, sourceID]
                ) else {
                    throw ReaderPersistenceError.invalidProgress("历史来源不属于当前 Reading Space")
                }
            }
            if let locator = entry.locator {
                guard locator.sourceID == entry.sourceID,
                      locator.snapshotID == entry.snapshotID else {
                    throw ReaderPersistenceError.invalidProgress("历史 Locator 身份不一致")
                }
            }
            try db.execute(
                sql: """
                    INSERT INTO reading_history
                        (id, space_id, source_id, snapshot_id, locator_json,
                         opened_at, duration_seconds)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    entry.id,
                    entry.spaceID,
                    entry.sourceID,
                    entry.snapshotID,
                    locatorData,
                    entry.openedAt,
                    max(0, entry.durationSeconds),
                ]
            )
            try db.execute(
                sql: """
                    DELETE FROM reading_history
                    WHERE space_id = ? AND id NOT IN (
                        SELECT id FROM reading_history
                        WHERE space_id = ?
                        ORDER BY opened_at DESC, id DESC
                        LIMIT 1000
                    )
                    """,
                arguments: [entry.spaceID, entry.spaceID]
            )
        }
    }

    func fetchReadingHistory(
        spaceID: String? = nil,
        limit: Int = 100
    ) throws -> [ReadingHistoryEntry] {
        try pool.read { db in
            var sql = "SELECT * FROM reading_history"
            var arguments = StatementArguments()
            if let spaceID {
                sql += " WHERE space_id = ?"
                arguments += [spaceID]
            }
            sql += " ORDER BY opened_at DESC, id DESC LIMIT ?"
            arguments += [min(max(1, limit), 500)]
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                let locatorData: Data? = row["locator_json"]
                return ReadingHistoryEntry(
                    id: row["id"],
                    spaceID: row["space_id"],
                    sourceID: row["source_id"],
                    snapshotID: row["snapshot_id"],
                    locator: try locatorData.map {
                        try Self.readerDecoder.decode(Locator.self, from: $0)
                    },
                    openedAt: row["opened_at"],
                    durationSeconds: row["duration_seconds"]
                )
            }
        }
    }

    func latestReadingPlan(spaceID: String) throws -> ReadingPlanDraft? {
        try pool.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: """
                    SELECT payload_json FROM reading_plans
                    WHERE space_id = ? AND is_frozen = 1
                    ORDER BY created_at DESC, id DESC LIMIT 1
                    """,
                arguments: [spaceID]
            ) else { return nil }
            return try Self.readerDecoder.decode(ReadingPlanDraft.self, from: data)
        }
    }

    func readingPlan(spaceID: String, graphVersion: String) throws -> ReadingPlanDraft? {
        try pool.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: """
                    SELECT payload_json FROM reading_plans
                    WHERE space_id = ? AND graph_version = ? AND is_frozen = 1
                    ORDER BY created_at DESC, id DESC LIMIT 1
                    """,
                arguments: [spaceID, graphVersion]
            ) else { return nil }
            return try Self.readerDecoder.decode(ReadingPlanDraft.self, from: data)
        }
    }

    #if DEBUG
    func saveReadingStructureForTesting(
        graph: ReadingGraph,
        plan: ReadingPlanDraft,
        spaceID: String
    ) throws {
        let graphPayload = try Self.readerEncoder.encode(graph)
        let planPayload = try Self.readerEncoder.encode(plan)
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reading_graphs (id, space_id, version, payload_json, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [graph.id, spaceID, graph.version, graphPayload, graph.generatedAt]
            )
            try db.execute(
                sql: """
                    INSERT INTO reading_plans
                        (id, space_id, graph_id, graph_version, goal,
                         payload_json, is_frozen, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, 1, ?)
                    """,
                arguments: [
                    plan.id,
                    spaceID,
                    graph.id,
                    graph.version,
                    plan.goal,
                    planPayload,
                    plan.createdAt,
                ]
            )
        }
    }
    #endif

    private static func validate(annotation: Annotation, in db: Database) throws {
        guard annotation.locator.sourceID == annotation.sourceID,
              annotation.locator.snapshotID == annotation.snapshotID else {
            throw ReaderPersistenceError.invalidAnnotation("Locator 身份与标注不一致")
        }
        guard try rowExists(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM space_sources WHERE space_id = ? AND source_id = ?)",
            arguments: [annotation.spaceID, annotation.sourceID]
        ) else {
            throw ReaderPersistenceError.invalidAnnotation("来源不属于当前 Reading Space")
        }
        guard try rowExists(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM snapshots WHERE id = ? AND source_id = ?)",
            arguments: [annotation.snapshotID, annotation.sourceID]
        ) else {
            throw ReaderPersistenceError.invalidAnnotation("Snapshot 不存在")
        }
        if annotation.kind == .highlight {
            guard let selected = annotation.selectedText?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !selected.isEmpty else {
                throw ReaderPersistenceError.invalidAnnotation("高亮必须包含选中文本")
            }
        }
        if annotation.locator.adapterID == QuickLookAdapter.id,
           annotation.kind == .highlight {
            throw ReaderPersistenceError.invalidAnnotation("Quick Look 不支持结构化高亮")
        }
    }

    private static func decodeAnnotation(_ row: Row) throws -> Annotation {
        let kindValue: String = row["kind"]
        let stateValue: String = row["anchor_state"]
        guard let kind = AnnotationKind(rawValue: kindValue) else {
            throw LibraryDatabaseError.corruptValue(
                table: "annotations",
                column: "kind",
                value: kindValue
            )
        }
        guard let state = AnnotationAnchorState(rawValue: stateValue) else {
            throw LibraryDatabaseError.corruptValue(
                table: "annotations",
                column: "anchor_state",
                value: stateValue
            )
        }
        let locatorData: Data = row["locator_json"]
        return Annotation(
            id: row["id"],
            spaceID: row["space_id"],
            sourceID: row["source_id"],
            snapshotID: row["snapshot_id"],
            kind: kind,
            locator: try readerDecoder.decode(Locator.self, from: locatorData),
            anchorState: state,
            selectedText: row["selected_text"],
            note: row["note"],
            color: row["color"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private static func rowExists(
        _ db: Database,
        sql: String,
        arguments: StatementArguments
    ) throws -> Bool {
        try Bool.fetchOne(db, sql: sql, arguments: arguments) ?? false
    }

    private static var readerEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var readerDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
