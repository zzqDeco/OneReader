import Foundation
import GRDB

extension LibraryDatabase {
    /// Kept separate so integrated feature migrations can be registered in order.
    static func registerNotesMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v12-annotation-notes-center") { db in
            try db.execute(sql: """
                CREATE TABLE annotation_tags (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    normalized_name TEXT NOT NULL UNIQUE,
                    created_at DATETIME NOT NULL
                );
                CREATE TABLE annotation_tag_links (
                    annotation_id TEXT NOT NULL REFERENCES annotations(id) ON DELETE CASCADE,
                    tag_id TEXT NOT NULL REFERENCES annotation_tags(id) ON DELETE CASCADE,
                    PRIMARY KEY (annotation_id, tag_id)
                );
                CREATE INDEX annotation_tag_links_by_tag ON annotation_tag_links(tag_id, annotation_id);
                CREATE INDEX annotations_by_creation ON annotations(created_at, id);
                CREATE INDEX annotations_by_source ON annotations(source_id, created_at, id);
                CREATE INDEX annotations_by_space ON annotations(space_id, created_at, id);
                CREATE VIRTUAL TABLE annotation_note_search USING fts5(
                    annotation_id UNINDEXED, excerpt, note, tokenize = 'unicode61'
                );
                INSERT INTO annotation_note_search(annotation_id, excerpt, note)
                    SELECT id, coalesce(selected_text, ''), coalesce(note, '') FROM annotations;
                CREATE TRIGGER notes_annotation_insert AFTER INSERT ON annotations BEGIN
                    INSERT INTO annotation_note_search(annotation_id, excerpt, note)
                        VALUES (new.id, coalesce(new.selected_text, ''), coalesce(new.note, ''));
                END;
                CREATE TRIGGER notes_annotation_update AFTER UPDATE ON annotations BEGIN
                    DELETE FROM annotation_note_search WHERE annotation_id = old.id;
                    INSERT INTO annotation_note_search(annotation_id, excerpt, note)
                        VALUES (new.id, coalesce(new.selected_text, ''), coalesce(new.note, ''));
                END;
                CREATE TRIGGER notes_annotation_delete AFTER DELETE ON annotations BEGIN
                    DELETE FROM annotation_note_search WHERE annotation_id = old.id;
                END;
                UPDATE library_metadata SET value = '12' WHERE key = 'database_schema';
                """)
            try db.execute(
                sql: "INSERT INTO library_metadata(key, value) VALUES ('notes_library_id', ?)",
                arguments: [UUID().uuidString.lowercased()]
            )
        }
    }

    func notesPage(query: NotesQuery, after: NotesCursor? = nil, limit: Int = 80) async throws -> NotesPage {
        try await pool.read { db in
            try Task.checkCancellation()
            let size = min(max(1, limit), 200)
            let entries = try Self.notesEntries(db, query: query, after: after, limit: size + 1)
            let visible = Array(entries.prefix(size))
            let filter = Self.notesFilter(query: query)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM annotations a WHERE \(filter.sql)", arguments: filter.arguments) ?? 0
            let next = entries.count > size ? visible.last.map { NotesCursor(createdAt: $0.annotation.createdAt, id: $0.id) } : nil
            return NotesPage(entries: visible, nextCursor: next, totalCount: count)
        }
    }

    func notesEntry(id: String) async throws -> NotesEntry? {
        try await pool.read { db in
            try Self.notesEntries(db, query: NotesQuery(), onlyIDs: [id], limit: 1).first
        }
    }

    func notesEntry(route: NotesLocalRoute) async throws -> NotesEntry {
        try await pool.read { db in
            guard try Self.notesLibraryID(db) == route.libraryID else { throw NotesError.differentLibrary }
            guard let entry = try Self.notesEntries(db, query: NotesQuery(), onlyIDs: [route.annotationID], limit: 1).first,
                  entry.annotation.sourceID == route.sourceID,
                  entry.annotation.snapshotID == route.snapshotID else { throw NotesError.missingAnnotation }
            return entry
        }
    }

    func notesTags() async throws -> [AnnotationTag] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.*, count(l.annotation_id) AS annotation_count FROM annotation_tags t
                LEFT JOIN annotation_tag_links l ON l.tag_id = t.id
                GROUP BY t.id ORDER BY t.normalized_name, t.id
                """).map(Self.decodeNotesTag)
        }
    }

    @discardableResult
    func createNotesTag(name: String) async throws -> String {
        let normalized = try AnnotationTag.normalized(name)
        return try await pool.write { db in
            if let existing = try String.fetchOne(db, sql: "SELECT id FROM annotation_tags WHERE normalized_name = ?", arguments: [normalized.key]) {
                return existing
            }
            let id = UUID().uuidString.lowercased()
            try db.execute(sql: "INSERT INTO annotation_tags (id, name, normalized_name, created_at) VALUES (?, ?, ?, ?)", arguments: [id, normalized.name, normalized.key, Date.now])
            return id
        }
    }

    func renameNotesTag(id: String, name: String, confirmedMergeTargetID: String? = nil) async throws {
        let normalized = try AnnotationTag.normalized(name)
        try await pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM annotation_tags WHERE id = ?)", arguments: [id]) == true else { throw NotesError.invalidTag }
            if let target = try Row.fetchOne(db, sql: "SELECT id, name FROM annotation_tags WHERE normalized_name = ? AND id != ?", arguments: [normalized.key, id]) {
                let targetID: String = target["id"]
                guard confirmedMergeTargetID == targetID else { throw NotesError.duplicateTag(target["name"]) }
                try db.execute(sql: "INSERT OR IGNORE INTO annotation_tag_links(annotation_id, tag_id) SELECT annotation_id, ? FROM annotation_tag_links WHERE tag_id = ?", arguments: [targetID, id])
                try db.execute(sql: "DELETE FROM annotation_tags WHERE id = ?", arguments: [id])
            } else {
                // A stale merge confirmation must not silently rename a different target.
                guard confirmedMergeTargetID == nil else { throw NotesError.invalidTag }
                try db.execute(sql: "UPDATE annotation_tags SET name = ?, normalized_name = ? WHERE id = ?", arguments: [normalized.name, normalized.key, id])
            }
        }
    }

    func deleteNotesTag(id: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM annotation_tags WHERE id = ?", arguments: [id])
        }
    }

    func editNote(id: String, expectedUpdatedAt: Date, note: String, tagIDs: Set<String>) async throws {
        try await pool.write { db in
            let annotation = try Self.checkedNotesAnnotation(db, id: id, expected: expectedUpdatedAt)
            let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard annotation.kind != .note || !normalized.isEmpty else {
                throw ReaderPersistenceError.invalidAnnotation("笔记内容不能为空；如需移除请明确删除标注")
            }
            for tagID in tagIDs {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM annotation_tags WHERE id = ?)", arguments: [tagID]) == true else { throw NotesError.invalidTag }
            }
            let updatedAt = max(Date.now, annotation.updatedAt.addingTimeInterval(0.002))
            try db.execute(sql: "UPDATE annotations SET note = ?, updated_at = ? WHERE id = ?", arguments: [normalized.isEmpty ? nil : normalized, updatedAt, id])
            try db.execute(sql: "DELETE FROM annotation_tag_links WHERE annotation_id = ?", arguments: [id])
            for tagID in tagIDs.sorted() {
                try db.execute(sql: "INSERT INTO annotation_tag_links(annotation_id, tag_id) VALUES (?, ?)", arguments: [id, tagID])
            }
        }
    }

    func deleteNotes(_ expectedVersions: [String: Date]) async throws {
        try await pool.write { db in
            try Task.checkCancellation()
            for (id, version) in expectedVersions {
                _ = try Self.checkedNotesAnnotation(db, id: id, expected: version)
            }
            for id in expectedVersions.keys.sorted() {
                try db.execute(sql: "DELETE FROM annotations WHERE id = ?", arguments: [id])
            }
        }
    }

    /// Rebuilds derived note text only. Source search and Agent tools never read it.
    func rebuildNotesSearch() async throws {
        try await pool.write { db in
            try db.execute(sql: """
                DELETE FROM annotation_note_search;
                INSERT INTO annotation_note_search(annotation_id, excerpt, note)
                    SELECT id, coalesce(selected_text, ''), coalesce(note, '') FROM annotations;
                """)
        }
    }

    func captureNotesExport(query: NotesQuery, selectedIDs: Set<String>? = nil, options: NotesExportOptions) async throws -> NotesExportSnapshot {
        // One read transaction gives the entire export a consistent SQLite snapshot.
        try await pool.read { db in
            var entries: [NotesEntry] = []
            var cursor: NotesCursor?
            var bytes = 0
            while true {
                try Task.checkCancellation()
                let page = try Self.notesEntries(db, query: query, after: cursor, limit: 200)
                for entry in page where selectedIDs == nil || selectedIDs!.contains(entry.id) {
                    bytes += entry.annotation.selectedText?.utf8.count ?? 0
                    if options.includeNotes { bytes += entry.annotation.note?.utf8.count ?? 0 }
                    guard entries.count < 100_000, bytes <= 128 * 1024 * 1024 else { throw NotesError.exportTooLarge }
                    entries.append(entry)
                }
                guard let last = page.last else { break }
                cursor = NotesCursor(createdAt: last.annotation.createdAt, id: last.id)
                if page.count < 200 { break }
            }
            return NotesExportSnapshot(libraryID: try Self.notesLibraryID(db), entries: entries, options: options, capturedAt: .now)
        }
    }

    private static func notesLibraryID(_ db: Database) throws -> String {
        guard let id = try String.fetchOne(db, sql: "SELECT value FROM library_metadata WHERE key = 'notes_library_id'") else { throw NotesError.differentLibrary }
        return id
    }

    private static func checkedNotesAnnotation(_ db: Database, id: String, expected: Date) throws -> Annotation {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM annotations WHERE id = ?", arguments: [id]) else { throw NotesError.missingAnnotation }
        let annotation = try decodeAnnotation(row)
        // GRDB's SQLite date encoding stores milliseconds, so compare persisted precision.
        guard abs(annotation.updatedAt.timeIntervalSince(expected)) < 0.001 else { throw NotesError.changedAnnotation }
        return annotation
    }

    private static func notesFilter(query: NotesQuery, after: NotesCursor? = nil, onlyIDs: [String]? = nil) -> (sql: String, arguments: StatementArguments) {
        var predicates = ["1 = 1"]
        var args = StatementArguments()
        if let id = query.spaceID { predicates.append("a.space_id = ?"); args += [id] }
        if let id = query.sourceID { predicates.append("a.source_id = ?"); args += [id] }
        if let kind = query.kind { predicates.append("a.kind = ?"); args += [kind.rawValue] }
        if let date = query.createdAfter { predicates.append("a.created_at >= ?"); args += [date] }
        if let date = query.createdBefore { predicates.append("a.created_at < ?"); args += [date] }
        for id in query.tagIDs.sorted() {
            predicates.append("EXISTS(SELECT 1 FROM annotation_tag_links l WHERE l.annotation_id = a.id AND l.tag_id = ?)")
            args += [id]
        }
        let search = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            // Literal substring matching also covers Chinese, punctuation and 1–2
            // character searches which unicode61 token matching alone cannot do.
            predicates.append("a.id IN (SELECT annotation_id FROM annotation_note_search WHERE instr(lower(excerpt || char(10) || note), lower(?)) > 0)")
            args += [search]
        }
        if let onlyIDs {
            predicates.append("a.id IN (\(onlyIDs.map { _ in "?" }.joined(separator: ",")))")
            args += StatementArguments(onlyIDs)
        }
        if let after {
            let comparison = query.sort == .newest ? "<" : ">"
            predicates.append("(a.created_at \(comparison) ? OR (a.created_at = ? AND a.id \(comparison) ?))")
            args += [after.createdAt, after.createdAt, after.id]
        }
        return (predicates.joined(separator: " AND "), args)
    }

    private static func notesEntries(_ db: Database, query: NotesQuery, after: NotesCursor? = nil, onlyIDs: [String]? = nil, limit: Int) throws -> [NotesEntry] {
        try Task.checkCancellation()
        let filter = notesFilter(query: query, after: after, onlyIDs: onlyIDs)
        let order = query.sort == .newest ? "DESC" : "ASC"
        let rows = try Row.fetchAll(db, sql: """
            SELECT a.*, s.display_name AS source_title, sp.title AS space_title,
                (s.managed_state != 'removed' AND sn.id IS NOT NULL) AS source_available,
                (s.latest_snapshot_id = a.snapshot_id) AS is_latest_snapshot,
                s.origin_url AS source_origin_url
            FROM annotations a
            LEFT JOIN sources s ON s.id = a.source_id
            LEFT JOIN snapshots sn ON sn.id = a.snapshot_id AND sn.source_id = a.source_id
            LEFT JOIN reading_spaces sp ON sp.id = a.space_id
            WHERE \(filter.sql)
            ORDER BY a.created_at \(order), a.id \(order) LIMIT ?
            """, arguments: filter.arguments + [limit])
        guard !rows.isEmpty else { return [] }
        let ids: [String] = rows.map { $0["id"] }
        let tags = try Row.fetchAll(db, sql: """
            SELECT t.*, l.annotation_id, 0 AS annotation_count FROM annotation_tags t
            JOIN annotation_tag_links l ON l.tag_id = t.id
            WHERE l.annotation_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
            ORDER BY t.normalized_name, t.id
            """, arguments: StatementArguments(ids))
        var tagsByID: [String: [AnnotationTag]] = [:]
        for tag in tags {
            let id: String = tag["annotation_id"]
            tagsByID[id, default: []].append(decodeNotesTag(tag))
        }
        return try rows.map { row in
            let annotation = try decodeAnnotation(row)
            let origin: String? = row["source_origin_url"]
            return NotesEntry(annotation: annotation, sourceTitle: row["source_title"] ?? "已移除来源", spaceTitle: row["space_title"] ?? "已移除空间", sourceAvailable: row["source_available"] ?? false, isLatestSnapshot: row["is_latest_snapshot"] ?? false, originalWebURL: origin.flatMap(URL.init(string:)).flatMap(NotesMarkdownExporter.safeWebURL), tags: tagsByID[annotation.id] ?? [])
        }
    }

    private static func decodeNotesTag(_ row: Row) -> AnnotationTag {
        AnnotationTag(id: row["id"], name: row["name"], normalizedName: row["normalized_name"], annotationCount: row["annotation_count"])
    }
}
