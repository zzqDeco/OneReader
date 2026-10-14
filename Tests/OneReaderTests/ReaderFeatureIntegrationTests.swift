import Foundation
import GRDB
import XCTest
@testable import OneReader

@MainActor
final class ReaderFeatureIntegrationTests: XCTestCase {
    func testMigrationOrderAndCapturedNotesSurviveOrganizationAndTranslationCache() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let database = fixture.database
        let imported = fixture.captured.imported
        try await fixture.adapters.index(plan: fixture.captured.plan)
        XCTAssertFalse(try database.searchObservations(query: "original").isEmpty)
        let migrationNames = try await database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        let captureIndex = try XCTUnwrap(migrationNames.firstIndex(of: "v11-capture-inbox"))
        let notesIndex = try XCTUnwrap(migrationNames.firstIndex(of: "v12-annotation-notes-center"))
        let translationIndex = try XCTUnwrap(migrationNames.firstIndex(of: "v13-bilingual-translation-cache"))
        XCTAssertLessThan(captureIndex, notesIndex)
        XCTAssertLessThan(notesIndex, translationIndex)
        XCTAssertEqual(try database.schemaMetadata()["database_schema"], String(LibraryDatabase.schemaVersion))
        XCTAssertEqual(try database.schemaMetadata()["agent_runtime_schema"], "6")

        let annotation = try await saveNote(fixture)
        let stored = try await requiredNote(database, id: annotation.id)
        let tagID = try await database.createNotesTag(name: "跨功能")
        try await database.editNote(id: stored.id, expectedUpdatedAt: stored.annotation.updatedAt,
                                    note: "PRIVATE_NOTE_ONLY", tagIDs: [tagID])
        let beforeOrganization = try await requiredNote(database, id: annotation.id)
        var progress = ReadingProgress.empty
        progress.lastActiveAt = Date(timeIntervalSince1970: 100)
        progress.sourcePositions[imported.source.id] = SourcePosition(
            sourceID: imported.source.id, locator: annotation.locator,
            updatedAt: Date(timeIntervalSince1970: 100), progressFraction: 0.4,
            granularity: .text, displayLabel: "原文进度"
        )
        try database.saveReadingProgress(progress, spaceID: imported.space.id)

        let otherFile = fixture.root.appendingPathComponent("other.md")
        try Data("# Other Space".utf8).write(to: otherFile)
        let target = try await fixture.library.importLocalSource(at: otherFile)
        try database.setSpaceOrganization(.archived, spaceIDs: [imported.space.id])
        try database.organizeCaptures([fixture.receipt.id], intoSpaceID: target.space.id)
        let afterOrganization = try await requiredNote(database, id: annotation.id)
        XCTAssertEqual(afterOrganization.annotation, beforeOrganization.annotation)
        XCTAssertEqual(afterOrganization.tags.map(\.id), [tagID])
        XCTAssertEqual(try database.fetchReadingProgress(spaceID: imported.space.id), progress)
        XCTAssertEqual(try database.spaceIDs(containing: imported.source.id).count, 2)
        let notesPage = try await database.notesPage(query: NotesQuery(sourceID: imported.source.id))
        XCTAssertEqual(notesPage.entries.map(\.id), [annotation.id], "Extra Space membership never duplicates the original Annotation")

        let segments = try TranslationSourceBuilder.textSegments(
            fixture.body, locator: annotation.locator, markdown: true
        )
        let segment = try XCTUnwrap(segments.first { $0.originalText.contains("original paragraph") })
        let profile = ProviderProfile(displayName: "Fixture only", kind: .ollama,
            endpoint: URL(string: "http://127.0.0.1:11434"), modelID: "never-called", isDefault: false)
        let settings = try TranslationSettings(sourceLanguage: .automatic, targetLanguage: .simplifiedChinese, profile: profile)
        let translation = CachedTranslation(key: try segment.cacheKey(settings: settings),
            schemaVersion: TranslationSettings.schemaVersion, promptVersion: TranslationSettings.promptVersion,
            segment: segment, settings: settings, translatedText: "MACHINE_TRANSLATION_ONLY", generatedAt: Date(timeIntervalSince1970: 100))
        // Seed the cache persistence seam with source-bound fixture data; no model call.
        try await database.pool.write { db in
            try LibraryDatabase.commitTranslations([translation], db: db,
                manifest: [imported.source.id: imported.snapshot.id])
        }
        XCTAssertEqual(try database.cachedTranslation(segment: segment, settings: settings), translation)
        let machineNotes = try await database.notesPage(query: NotesQuery(search: "MACHINE_TRANSLATION_ONLY"))
        XCTAssertEqual(machineNotes.totalCount, 0)
        XCTAssertTrue(try database.searchObservations(query: "PRIVATE_NOTE_ONLY").isEmpty)
        let export = try await database.captureNotesExport(query: NotesQuery(sourceID: imported.source.id), options: NotesExportOptions())
        let markdown = NotesMarkdownExporter.renderSource(export.entries, snapshot: export)
        XCTAssertTrue(markdown.contains("PRIVATE\\_NOTE\\_ONLY"))
        XCTAssertFalse(markdown.contains("MACHINE_TRANSLATION_ONLY"))

        let reopened = try LibraryDatabase(rootURL: database.layout.rootURL)
        let reopenedNote = try await requiredNote(reopened, id: annotation.id)
        XCTAssertEqual(reopenedNote.annotation, beforeOrganization.annotation)
        XCTAssertEqual(reopenedNote.tags.map(\.id), [tagID])
        XCTAssertEqual(try reopened.cachedTranslation(segment: segment, settings: settings), translation)
        try reopened.deleteTranslations(segments: [segment], settings: settings)
        XCTAssertEqual(try reopened.fetchReadingProgress(spaceID: imported.space.id), progress)
        let preserved = try await reopened.notesPage(query: NotesQuery(search: "PRIVATE_NOTE_ONLY"))
        XCTAssertEqual(preserved.entries.map(\.id), [annotation.id])
    }

    func testColdNotesLinkWaitsForCaptureBootstrapAndNeverBecomesCapture() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let annotation = try await saveNote(fixture)
        let libraryID = try XCTUnwrap(fixture.database.schemaMetadata()["notes_library_id"])
        let url = try XCTUnwrap(NotesLocalRoute(libraryID: libraryID, annotation: annotation).url)
        let suite = "ReaderFeatureIntegration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(libraryRootURL: fixture.database.layout.rootURL,
            defaults: defaults, secretStore: InMemoryProviderSecretStore(), automaticBootstrap: false)

        model.handleOpenURL(url)
        XCTAssertFalse(model.isBootstrapComplete)
        XCTAssertNil(model.captureCoordinator)
        await model.bootstrap()
        try await waitUntil { model.presentationDocument != nil && model.isAnnotationPreview }
        XCTAssertNotNil(model.notesCenter)
        XCTAssertNotNil(model.captureCoordinator)
        XCTAssertEqual(model.captureJobs.map(\.id), [fixture.receipt.id])
        XCTAssertEqual(model.presentationDocument?.locator.snapshotID, annotation.snapshotID)
        XCTAssertEqual(model.bilingualReading.status, "当前来源尚未加载对照片段；不会自动发送原文。")
        XCTAssertTrue(model.bilingualReading.rows.isEmpty)
        XCTAssertNil(model.activeProvider)
        XCTAssertTrue(model.agentRuns.isEmpty)

        model.handleOpenURL(try XCTUnwrap(URL(string: url.absoluteString + "&path=/etc/passwd")))
        XCTAssertEqual(model.notice?.title, "无法打开笔记回链")
        XCTAssertEqual(model.captureJobs.map(\.id), [fixture.receipt.id])
        XCTAssertEqual(try fixture.database.fetchSources().count, 1)
        model.closeReadingWorkspace()
    }

    private func requiredNote(_ database: LibraryDatabase, id: String) async throws -> NotesEntry {
        let result = try await database.notesEntry(id: id)
        return try XCTUnwrap(result)
    }

    private func saveNote(_ fixture: Fixture) async throws -> Annotation {
        let document = try await fixture.adapters.render(plan: fixture.captured.plan)
        let imported = fixture.captured.imported
        let annotation = Annotation(id: "integration-note", spaceID: imported.space.id,
            sourceID: imported.source.id, snapshotID: imported.snapshot.id, kind: .note,
            locator: document.locator, anchorState: .current, selectedText: "An original paragraph.",
            note: "PRIVATE_NOTE_ONLY", color: nil, createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100))
        try fixture.database.saveAnnotation(annotation)
        return annotation
    }

    private struct Fixture {
        let root: URL
        let body: String
        let database: LibraryDatabase
        let library: ManagedLibrary
        let adapters: AdapterCoordinator
        let receipt: CaptureReceipt
        let captured: CapturePreparedResult
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderFeatureIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let body = "# Captured\n\nAn original paragraph.\n"
        let file = root.appendingPathComponent("captured.md")
        try Data(body.utf8).write(to: file)
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: LibraryStoragePolicy(
            largeImportThreshold: .max, minimumFreeCapacity: 0, capacityProvider: { _ in .max }))
        let adapters = try AdapterCoordinator.standard(database: database)
        let capture = CaptureCoordinator(database: database, library: library,
            remoteImporter: RemoteSourceImporter(library: library), adapters: adapters)
        let receipt = try await capture.receive(.local(file))
        let processed = await capture.process(receipt.id)
        let captured = try XCTUnwrap(processed)
        return Fixture(root: root, body: body, database: database, library: library,
            adapters: adapters, receipt: receipt, captured: captured)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(10)
        while !predicate() {
            if Date.now > deadline { XCTFail("Timed out waiting for integrated local state"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
