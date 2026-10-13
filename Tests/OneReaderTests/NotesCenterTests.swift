import Foundation
import Darwin
import GRDB
import XCTest
@testable import OneReader

final class NotesCenterTests: XCTestCase {
    func testMigrationPreservesAnnotationsProgressSnapshotsAndEmptyTags() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let note = annotation(fixture, id: "legacy-note", note: "原始笔记", text: "原始摘录")
        try fixture.database.saveAnnotation(note)
        let saved = try fixture.database.fetchAnnotations(spaceID: note.spaceID)
        let snapshots = try fixture.database.fetchSnapshots()
        var progress = ReadingProgress.empty
        progress.lastActiveAt = Date(timeIntervalSince1970: 123)
        progress.sourcePositions[note.sourceID] = SourcePosition(sourceID: note.sourceID, locator: note.locator, updatedAt: Date(timeIntervalSince1970: 123), progressFraction: 0.4, granularity: .text, displayLabel: "测试位置")
        try fixture.database.saveReadingProgress(progress, spaceID: note.spaceID)
        try await fixture.database.pool.write { db in
            try db.execute(sql: """
                DROP TRIGGER notes_annotation_insert;
                DROP TRIGGER notes_annotation_update;
                DROP TRIGGER notes_annotation_delete;
                DROP TABLE annotation_note_search;
                DROP TABLE annotation_tag_links;
                DROP TABLE annotation_tags;
                DROP INDEX annotations_by_creation;
                DROP INDEX annotations_by_source;
                DROP INDEX annotations_by_space;
                DELETE FROM library_metadata WHERE key = 'notes_library_id';
                UPDATE library_metadata SET value = '10' WHERE key = 'database_schema';
                DELETE FROM grdb_migrations WHERE identifier = 'v12-annotation-notes-center';
                """)
        }
        let migrated = try LibraryDatabase(rootURL: fixture.libraryRoot)
        XCTAssertEqual(try migrated.fetchAnnotations(spaceID: note.spaceID), saved)
        XCTAssertEqual(try migrated.fetchSnapshots(), snapshots)
        XCTAssertEqual(try migrated.fetchReadingProgress(spaceID: note.spaceID), progress)
        let tags = try await migrated.notesTags()
        XCTAssertTrue(tags.isEmpty)
        let page = try await migrated.notesPage(query: NotesQuery(search: "原始"))
        XCTAssertEqual(page.entries.map(\.id), [note.id])
        let id = try XCTUnwrap(migrated.schemaMetadata()["notes_library_id"])
        let reopened = try LibraryDatabase(rootURL: fixture.libraryRoot)
        XCTAssertEqual(try reopened.schemaMetadata()["notes_library_id"], id)
    }

    func testTagNormalizationExplicitMergeAndDeletionOnlyRemoveRelationships() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let note = annotation(fixture, note: "笔记")
        try fixture.database.saveAnnotation(note)
        let tag = try await fixture.database.createNotesTag(name: "  Study　笔记  ")
        let same = try await fixture.database.createNotesTag(name: "study 笔记")
        XCTAssertEqual(tag, same)
        let second = try await fixture.database.createNotesTag(name: "待整理")
        let persisted = try await requireEntry(fixture.database, id: note.id)
        try await fixture.database.editNote(id: note.id, expectedUpdatedAt: persisted.annotation.updatedAt, note: "笔记", tagIDs: [tag, second])
        let page = try await fixture.database.notesPage(query: NotesQuery(tagIDs: [tag, second]))
        XCTAssertEqual(page.entries.count, 1)
        do { try await fixture.database.renameNotesTag(id: second, name: "STUDY 笔记"); XCTFail("Merge must require confirmation") }
        catch { XCTAssertEqual(error as? NotesError, .duplicateTag("Study 笔记")) }
        try await fixture.database.renameNotesTag(id: second, name: "STUDY 笔记", confirmedMergeTargetID: tag)
        let merged = try await requireEntry(fixture.database, id: note.id)
        XCTAssertEqual(merged.tags.map(\.id), [tag])
        try await fixture.database.deleteNotesTag(id: tag)
        let intact = try await requireEntry(fixture.database, id: note.id)
        XCTAssertEqual(intact.annotation.selectedText, note.selectedText)
        XCTAssertEqual(intact.annotation.note, "笔记")
        XCTAssertTrue(intact.tags.isEmpty)
    }

    func testPrivateLiteralSearchUpdateRebuildAndStaleEdits() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let note = annotation(fixture, note: "私有 中文 a_b% ' punctuation", text: nil)
        try fixture.database.saveAnnotation(note)
        let loaded = try await requireEntry(fixture.database, id: note.id)
        let query = NotesQuery(search: "a_b% '", spaceID: note.spaceID, sourceID: note.sourceID, kind: .note)
        let results = try await fixture.database.notesPage(query: query)
        XCTAssertEqual(results.entries.map(\.id), [note.id])
        let chinese = try await fixture.database.notesPage(query: NotesQuery(search: "中文"))
        XCTAssertEqual(chinese.totalCount, 1)
        let sourceSearch = try fixture.database.searchObservations(query: "私有", snapshotID: note.snapshotID)
        XCTAssertTrue(sourceSearch.isEmpty, "Private notes never enter source/Agent search")
        try await fixture.database.editNote(id: note.id, expectedUpdatedAt: loaded.annotation.updatedAt, note: "新的私有笔记", tagIDs: [])
        do { try await fixture.database.editNote(id: note.id, expectedUpdatedAt: loaded.annotation.updatedAt, note: "stale", tagIDs: []); XCTFail("Stale editor must not overwrite") }
        catch { XCTAssertEqual(error as? NotesError, .changedAnnotation) }
        let oldSearch = try await fixture.database.notesPage(query: query)
        XCTAssertEqual(oldSearch.totalCount, 0)
        try await fixture.database.pool.write { try $0.execute(sql: "DELETE FROM annotation_note_search") }
        let corrupted = try await fixture.database.notesPage(query: NotesQuery(search: "新的"))
        XCTAssertEqual(corrupted.totalCount, 0)
        try await fixture.database.rebuildNotesSearch()
        let repaired = try await fixture.database.notesPage(query: NotesQuery(search: "新的"))
        XCTAssertEqual(repaired.totalCount, 1)
        do { try await fixture.database.deleteNotes([note.id: loaded.annotation.updatedAt]); XCTFail("Stale delete must not remove changed annotation") }
        catch { XCTAssertEqual(error as? NotesError, .changedAnnotation) }
        let intact = try await fixture.database.notesEntry(id: note.id)
        XCTAssertNotNil(intact)
    }

    func testTenThousandStablePaginationAndNoDuplicationAcrossSpaces() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let note = annotation(fixture)
        let payload = try JSONEncoder().encode(note.locator)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await fixture.database.pool.write { db in
            try db.execute(sql: "INSERT INTO reading_spaces(id,title,is_favorite,created_at,updated_at) VALUES ('second-space','Second',0,?,?)", arguments: [date, date])
            try db.execute(sql: "INSERT INTO space_sources(space_id,source_id,position,added_at) VALUES ('second-space',?,0,?)", arguments: [note.sourceID, date])
            let statement = try db.makeStatement(sql: """
                INSERT INTO annotations(id,space_id,source_id,snapshot_id,kind,locator_json,anchor_state,selected_text,note,color,created_at,updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                """)
            for i in 0..<10_000 {
                try statement.execute(arguments: [String(format: "note-%05d", i), note.spaceID, note.sourceID, note.snapshotID, "bookmark", payload, "current", nil, "generated \(i)", nil, date, date])
            }
        }
        let started = Date.now
        var memoryBefore = rusage()
        getrusage(RUSAGE_SELF, &memoryBefore)
        var cursor: NotesCursor?
        var ids: [String] = []
        var pageCount = 0
        repeat {
            let page = try await fixture.database.notesPage(query: NotesQuery(), after: cursor, limit: 200)
            XCTAssertLessThanOrEqual(page.entries.count, 200)
            XCTAssertEqual(page.totalCount, 10_000)
            ids += page.entries.map(\.id)
            cursor = page.nextCursor
            pageCount += 1
            if pageCount == 1 {
                let changed = try XCTUnwrap(page.entries.first)
                try await fixture.database.editNote(id: changed.id, expectedUpdatedAt: changed.annotation.updatedAt, note: "updated during paging", tagIDs: [])
            }
        } while cursor != nil
        XCTAssertEqual(ids.count, 10_000)
        XCTAssertEqual(Set(ids).count, 10_000)
        XCTAssertEqual(ids, ids.sorted(by: >))
        XCTAssertEqual(pageCount, 50)
        var memoryAfter = rusage()
        getrusage(RUSAGE_SELF, &memoryAfter)
        print("NOTES_PAGINATION_FIXTURE count=10000 pages=50 pageSize=200 seconds=\(Date.now.timeIntervalSince(started)) processPeakRSSBeforeBytes=\(memoryBefore.ru_maxrss) processPeakRSSAfterBytes=\(memoryAfter.ru_maxrss) platform=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        let bookmarkPage = try await fixture.database.notesPage(query: NotesQuery(kind: .bookmark), limit: 1)
        XCTAssertFalse(try XCTUnwrap(bookmarkPage.entries.first).preview.isEmpty)
    }

    func testRouteValidatesExactLibraryAndAnnotationIdentity() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let note = annotation(fixture)
        try fixture.database.saveAnnotation(note)
        let libraryID = try XCTUnwrap(fixture.database.schemaMetadata()["notes_library_id"])
        let url = try XCTUnwrap(NotesLocalRoute(libraryID: libraryID, annotation: note).url)
        let route = try NotesLocalRoute(url: url)
        let entry = try await fixture.database.notesEntry(route: route)
        XCTAssertEqual(entry.annotation.id, note.id)
        for invalid in [
            url.absoluteString + "&path=/etc/passwd", url.absoluteString + "#fragment",
            url.absoluteString.replacingOccurrences(of: "/v1?", with: "/v2?"),
            url.absoluteString.replacingOccurrences(of: "//notes/", with: "//user@notes/"),
            "onereader://notes/v1?library=x&annotation=..%2Fsecret&source=x&snapshot=x",
            "onereader://notes/v1?library=x&annotation=x&annotation=y&source=x&snapshot=x",
            "onereader://notes/v1?library=\(String(repeating: "a", count: 2100))&annotation=x&source=x&snapshot=x"
        ] { XCTAssertThrowsError(try NotesLocalRoute(url: XCTUnwrap(URL(string: invalid)))) }
        let foreign = try NotesLocalRoute(url: XCTUnwrap(URL(string: url.absoluteString.replacingOccurrences(of: libraryID, with: "different-library"))))
        do { _ = try await fixture.database.notesEntry(route: foreign); XCTFail("Foreign library must not resolve") }
        catch { XCTAssertEqual(error as? NotesError, .differentLibrary) }
    }

    func testExportSnapshotKeepsIntentionalDuplicatesAndCapturedVersions() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = annotation(fixture, id: "first")
        let duplicate = annotation(fixture, id: "duplicate")
        try fixture.database.saveAnnotation(first)
        try fixture.database.saveAnnotation(duplicate)
        let all = try await fixture.database.captureNotesExport(query: NotesQuery(), options: NotesExportOptions())
        XCTAssertEqual(Set(all.entries.map(\.id)), ["first", "duplicate"])
        let selected = try await fixture.database.captureNotesExport(query: NotesQuery(), selectedIDs: ["first"], options: NotesExportOptions())
        XCTAssertEqual(selected.entries.map(\.id), ["first"])
        let original = try await requireEntry(fixture.database, id: "first")
        try await fixture.database.editNote(id: "first", expectedUpdatedAt: original.annotation.updatedAt, note: "后来编辑", tagIDs: [])
        let exported = NotesMarkdownExporter.renderSource(selected.entries, snapshot: selected)
        XCTAssertTrue(exported.contains("原始笔记"))
        XCTAssertFalse(exported.contains("后来编辑"))
    }

    func testBatchDeleteRefusesAllWhenAnyEntryHasChanged() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = annotation(fixture, id: "a")
        let second = annotation(fixture, id: "b")
        try fixture.database.saveAnnotation(first)
        try fixture.database.saveAnnotation(second)
        let a = try await requireEntry(fixture.database, id: "a")
        let b = try await requireEntry(fixture.database, id: "b")
        try await fixture.database.editNote(id: "b", expectedUpdatedAt: b.annotation.updatedAt, note: "并发编辑", tagIDs: [])
        do { try await fixture.database.deleteNotes(["a": a.annotation.updatedAt, "b": b.annotation.updatedAt]); XCTFail("Must reject the whole batch") }
        catch { XCTAssertEqual(error as? NotesError, .changedAnnotation) }
        let remaining = try await fixture.database.notesPage(query: NotesQuery())
        XCTAssertEqual(remaining.totalCount, 2)
        let currentB = try await requireEntry(fixture.database, id: "b")
        try await fixture.database.deleteNotes(["a": a.annotation.updatedAt, "b": currentB.annotation.updatedAt])
        let deleted = try await fixture.database.notesPage(query: NotesQuery())
        XCTAssertEqual(deleted.totalCount, 0)
    }

    func testCancelledQueryAndInvalidTagNamesFailSafely() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let task = Task { try await fixture.database.notesPage(query: NotesQuery()) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") } catch is CancellationError {}
        for name in ["", "  \n", "bad\u{0}name", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try AnnotationTag.normalized(name))
        }
    }

    private struct Fixture: Sendable {
        let root: URL
        let libraryRoot: URL
        let database: LibraryDatabase
        let imported: ManagedImportResult
    }

    private func requireEntry(_ database: LibraryDatabase, id: String) async throws -> NotesEntry {
        let entry = try await database.notesEntry(id: id)
        return try XCTUnwrap(entry)
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("测试来源.md")
        try Data("# 本地生成材料\n\n原始摘录。\n".utf8).write(to: source)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        let database = try LibraryDatabase(rootURL: libraryRoot)
        let library = try ManagedLibrary(database: database, storagePolicy: LibraryStoragePolicy(largeImportThreshold: .max, minimumFreeCapacity: 0, capacityProvider: { _ in .max }))
        return Fixture(root: root, libraryRoot: libraryRoot, database: database, imported: try await library.importLocalSource(at: source))
    }

    private func annotation(_ fixture: Fixture, id: String = "note-test", note: String? = "原始笔记", text: String? = "原始摘录") -> Annotation {
        let source = fixture.imported.source
        let snapshot = fixture.imported.snapshot
        return Annotation(id: id, spaceID: fixture.imported.space.id, sourceID: source.id, snapshotID: snapshot.id, kind: .note, locator: Locator(sourceID: source.id, snapshotID: snapshot.id, adapterID: MarkdownAdapter.id, payload: ["startLine": "3", "endLine": "3"], textQuote: TextQuote(prefix: nil, exact: "原始摘录。", suffix: nil)), anchorState: .current, selectedText: text, note: note, color: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
