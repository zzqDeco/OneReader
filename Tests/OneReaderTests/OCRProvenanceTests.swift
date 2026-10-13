import CoreGraphics
import Foundation
import GRDB
import XCTest
@testable import OneReader

final class OCRProvenanceTests: XCTestCase {
    func testPartialRerecognitionKeepsOtherPagesOriginalEngineAndSettings() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let english = OCRSettings(languages: ["en-US"], replaceNativeText: false)
        let bilingual = OCRSettings(languages: ["zh-Hans", "en-US"], replaceNativeText: true)
        let firstJob = makeJob(fixture.context, pages: [0, 1], settings: english, engine: "fixture-english-v1")
        try fixture.database.startOCRJob(firstJob)
        _ = try fixture.database.saveOCRPage(page(0, text: "Keep this original page"), jobID: firstJob.id)
        _ = try fixture.database.saveOCRPage(page(1, text: "Replace this page"), jobID: firstJob.id)
        let first = try XCTUnwrap(fixture.database.finishOCRJob(firstJob.id, state: .completed))
        let original = try XCTUnwrap(first.pages.first { $0.pageIndex == 0 })
        let originalRecord = try XCTUnwrap(original.provenance.record)
        XCTAssertEqual(originalRecord.engineVersion, firstJob.engineVersion)
        XCTAssertEqual(originalRecord.settings, english)
        XCTAssertEqual(originalRecord.jobID, firstJob.id)

        let secondJob = makeJob(fixture.context, pages: [1], settings: bilingual, engine: "fixture-bilingual-v2")
        try fixture.database.startOCRJob(secondJob)
        _ = try fixture.database.saveOCRPage(page(1, text: "重新识别的页面"), jobID: secondJob.id)
        let second = try XCTUnwrap(fixture.database.finishOCRJob(secondJob.id, state: .completed))
        XCTAssertEqual(second.pages.first { $0.pageIndex == 0 }, original)
        let replacement = try XCTUnwrap(second.pages.first { $0.pageIndex == 1 }?.provenance.record)
        XCTAssertEqual(replacement.settings, bilingual)
        XCTAssertEqual(replacement.engineVersion, secondJob.engineVersion)
        XCTAssertEqual(replacement.jobID, secondJob.id)
        XCTAssertEqual(second.engineVersion, secondJob.engineVersion)
        XCTAssertEqual(second.settings, bilingual) // Publishing-job parameters, not every page's.
        XCTAssertEqual(try fixture.database.ocrRevision(id: first.id, sourceID: first.sourceID,
            snapshotID: first.snapshotID), first)
        let reopened = try LibraryDatabase(rootURL: fixture.database.layout.rootURL)
        XCTAssertEqual(try reopened.activeOCRRevision(snapshotID: first.snapshotID), second)
    }

    func testLegacyPageAndJobDecodeAsUnknownWithoutCurrentDefaults() throws {
        let legacyPage = try JSONDecoder().decode(OCRPage.self,
            from: removingKey("provenance", from: page(0)))
        XCTAssertEqual(legacyPage.provenance, .unknown)
        XCTAssertNil(legacyPage.provenance.record)
        XCTAssertEqual(legacyPage.text, "Fixture text")
        let job = OCRJob(id: "legacy-job", sourceID: "source", snapshotID: "snapshot", pageIndices: [0],
            settings: OCRSettings(languages: ["legacy-language"], replaceNativeText: true),
            engineVersion: "legacy-engine", completedPages: [0], failedPages: [],
            state: .completed, createdAt: .distantPast, updatedAt: .distantPast)
        let legacyJob = try JSONDecoder().decode(OCRJob.self, from: removingKey("engineVersion", from: job))
        XCTAssertEqual(legacyJob.engineVersion, OCRPageProvenance.unknownEngineVersion)
        XCTAssertNotEqual(legacyJob.engineVersion, OCRSettings.engineVersion)
    }

    func testLegacyCarriedPageIsNotBackfilledFromPublishingJob() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldJob = makeJob(fixture.context, pages: [0], engine: "old-engine")
        try fixture.database.startOCRJob(oldJob)
        _ = try fixture.database.saveOCRPage(page(0), jobID: oldJob.id)
        let old = try XCTUnwrap(fixture.database.finishOCRJob(oldJob.id, state: .completed))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        var pages = try XCTUnwrap(object["pages"] as? [[String: Any]])
        pages[0].removeValue(forKey: "provenance")
        object["pages"] = pages
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        try fixture.database.pool.write { db in
            try db.execute(sql: "UPDATE ocr_revisions SET payload = ? WHERE id = ?", arguments: [legacyData, old.id])
        }
        XCTAssertEqual(try fixture.database.activeOCRRevision(snapshotID: old.snapshotID)?.pages[0].provenance, .unknown)

        let job = makeJob(fixture.context, pages: [1],
            settings: OCRSettings(languages: ["zh-Hans"], replaceNativeText: true), engine: "new-engine")
        try fixture.database.startOCRJob(job)
        _ = try fixture.database.saveOCRPage(page(1), jobID: job.id)
        let revision = try XCTUnwrap(fixture.database.finishOCRJob(job.id, state: .completed))
        XCTAssertEqual(revision.pages.first { $0.pageIndex == 0 }?.provenance, .unknown)
        XCTAssertEqual(revision.pages.first { $0.pageIndex == 1 }?.provenance.record?.engineVersion, "new-engine")
        let reopened = try LibraryDatabase(rootURL: fixture.database.layout.rootURL)
        XCTAssertEqual(try reopened.activeOCRRevision(snapshotID: old.snapshotID)?.pages[0].provenance, .unknown)
    }

    func testHostBindsActualSelectedEngineAndIgnoresEngineSuppliedProvenance() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = OCRSettings(languages: ["zh-Hans", "en-US"], replaceNativeText: true)
        let forged = OCRPageProvenanceRecord(engineVersion: "forged-engine",
            settings: OCRSettings(languages: ["forged-language"], replaceNativeText: false),
            jobID: "forged-job", recognizedAt: .distantFuture)
        let engine = ProvenanceFixtureEngine(identity: "host-selected-fixture-v4", claim: .nativeText(forged))
        let before = Date()
        let result = try await OCRService(database: fixture.database, engine: engine)
            .run(context: fixture.context, pages: [0], settings: settings) { _ in }
        let after = Date()
        let revision = try XCTUnwrap(result)
        let record = try XCTUnwrap(revision.pages.first?.provenance.record)
        XCTAssertEqual(revision.pages.first?.provenance, .recognized(record))
        XCTAssertEqual(record.engineVersion, engine.identity)
        XCTAssertEqual(record.settings, settings)
        XCTAssertEqual(record.jobID, revision.jobID)
        XCTAssertNotEqual(record.jobID, forged.jobID)
        XCTAssertGreaterThanOrEqual(record.recognizedAt, before)
        XCTAssertLessThanOrEqual(record.recognizedAt, after)
        XCTAssertEqual(revision.engineVersion, engine.identity)
        let job = try XCTUnwrap(fixture.database.ocrJobs(snapshotID: revision.snapshotID).first)
        XCTAssertEqual(job.engineVersion, engine.identity)
        XCTAssertEqual(try fixture.database.ocrDraftPages(jobID: job.id).first?.provenance, .recognized(record))
    }

    func testNativeTextHasExplicitNonOCRProvenance() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let job = makeJob(fixture.context, pages: [0], engine: "recognizer-not-used")
        try fixture.database.startOCRJob(job)
        _ = try fixture.database.saveOCRPage(page(0, nativeText: true), jobID: job.id)
        let revision = try XCTUnwrap(fixture.database.finishOCRJob(job.id, state: .completed))
        let result = try XCTUnwrap(revision.pages.first)
        let record = try XCTUnwrap(result.provenance.record)
        XCTAssertEqual(result.provenance, .nativeText(record))
        XCTAssertEqual(record.engineVersion, OCRPageProvenance.nativeTextEngineVersion)
        XCTAssertNotEqual(record.engineVersion, job.engineVersion)
        XCTAssertEqual(record.jobID, job.id)
        XCTAssertTrue(result.usesNativeText)
        XCTAssertTrue(result.spans.isEmpty)
    }

    func testResumePreservesOriginalDraftStampEvenWhenSelectedEngineChanges() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = OCRSettings(languages: ["en-US"], replaceNativeText: true)
        let oldJob = makeJob(fixture.context, pages: [0, 1], settings: settings, engine: "first-engine")
        try fixture.database.startOCRJob(oldJob)
        _ = try fixture.database.saveOCRPage(page(0), jobID: oldJob.id)
        let old = try XCTUnwrap(fixture.database.finishOCRJob(oldJob.id, state: .cancelled))
        let original = try XCTUnwrap(old.pages.first)
        let result = try await OCRService(database: fixture.database,
            engine: ProvenanceFixtureEngine(identity: "second-engine", claim: .unknown))
            .run(context: fixture.context, pages: [0, 1], settings: settings, resuming: oldJob) { _ in }
        let revision = try XCTUnwrap(result)
        let drafts = try fixture.database.ocrDraftPages(jobID: revision.jobID)
        XCTAssertEqual(drafts.first { $0.pageIndex == 0 }, original)
        XCTAssertEqual(revision.pages.first { $0.pageIndex == 0 }, original)
        XCTAssertEqual(revision.pages.first { $0.pageIndex == 0 }?.provenance.record?.jobID, oldJob.id)
        XCTAssertEqual(revision.pages.first { $0.pageIndex == 1 }?.provenance.record?.jobID, revision.jobID)
        XCTAssertEqual(revision.pages.first { $0.pageIndex == 1 }?.provenance.record?.engineVersion, "second-engine")
        XCTAssertEqual(revision.engineVersion, "second-engine")
    }

    func testLegacyDraftResumePreservesUnknownProvenance() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = makeJob(fixture.context, pages: [0, 1], engine: "old-engine")
        try fixture.database.startOCRJob(old)
        _ = try fixture.database.saveOCRPage(page(0), jobID: old.id)
        try fixture.database.abandonOCRJob(old.id)
        let draft = try XCTUnwrap(fixture.database.ocrDraftPages(jobID: old.id).first)
        let legacyData = try removingKey("provenance", from: draft)
        try fixture.database.pool.write { db in
            try db.execute(sql: "UPDATE ocr_job_pages SET payload = ? WHERE job_id = ? AND page_index = 0",
                           arguments: [legacyData, old.id])
        }
        let current = makeJob(fixture.context, pages: [0, 1], engine: "new-engine")
        try fixture.database.startOCRJob(current)
        _ = try fixture.database.resumeOCRDraftPages(fromJobID: old.id, intoJobID: current.id)
        XCTAssertEqual(try fixture.database.ocrDraftPages(jobID: current.id).first?.provenance, .unknown)
        _ = try fixture.database.saveOCRPage(page(1), jobID: current.id)
        let revision = try XCTUnwrap(fixture.database.finishOCRJob(current.id, state: .completed))
        XCTAssertEqual(revision.pages.first { $0.pageIndex == 0 }?.provenance, .unknown)
        XCTAssertEqual(revision.pages.first { $0.pageIndex == 1 }?.provenance.record?.engineVersion, "new-engine")
    }

    func testResumeAuthenticatesStoredJobSourceAndSettings() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let otherContext = try makeContext(database: fixture.database)
        let foreign = makeJob(otherContext, pages: [0], engine: "foreign-engine")
        try fixture.database.startOCRJob(foreign)
        _ = try fixture.database.saveOCRPage(page(0), jobID: foreign.id)
        _ = try fixture.database.finishOCRJob(foreign.id, state: .cancelled)
        let old = makeJob(fixture.context, pages: [0, 1], engine: "old-engine")
        try fixture.database.startOCRJob(old)
        _ = try fixture.database.saveOCRPage(page(0), jobID: old.id)
        _ = try fixture.database.finishOCRJob(old.id, state: .cancelled)
        let current = makeJob(fixture.context, pages: [0, 1],
            settings: OCRSettings(languages: ["zh-Hans"], replaceNativeText: true), engine: "current-engine")
        try fixture.database.startOCRJob(current)
        for oldID in ["missing-job", foreign.id, old.id] {
            XCTAssertThrowsError(try fixture.database.resumeOCRDraftPages(fromJobID: oldID, intoJobID: current.id)) {
                XCTAssertEqual($0 as? OCRError, .staleJob)
            }
            XCTAssertTrue(try fixture.database.ocrDraftPages(jobID: current.id).isEmpty)
        }
    }

    private struct Fixture {
        let root: URL
        let database: LibraryDatabase
        let context: AdapterContext
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OneReader-OCR-Provenance-\(UUID())")
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        return Fixture(root: root, database: database, context: try makeContext(database: database))
    }

    private func makeContext(database: LibraryDatabase) throws -> AdapterContext {
        let file = database.layout.sourcesURL.appendingPathComponent("fixture-\(UUID()).pdf")
        let consumer = try XCTUnwrap(CGDataConsumer(url: file as CFURL))
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let writer = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<2 {
            writer.beginPDFPage(nil)
            writer.setFillColor(CGColor(gray: 1, alpha: 1)); writer.fill(box)
            writer.endPDFPage()
        }
        writer.closePDF()
        let digest = AdapterUtilities.sha256(try Data(contentsOf: file))
        let source = Source(displayName: file.lastPathComponent, originKind: .localFile, originURL: file, managedState: .ready)
        let snapshot = SourceSnapshot(sourceID: source.id, revision: digest, observedAt: .now, origin: file)
        try database.pool.write { db in
            try db.execute(sql: "INSERT INTO sources (id, display_name, origin_kind, origin_url, managed_state, latest_snapshot_id, is_favorite, created_at, updated_at) VALUES (?, ?, 'localFile', ?, 'ready', ?, 0, ?, ?)",
                arguments: [source.id, source.displayName, file.absoluteString, snapshot.id, Date(), Date()])
            try db.execute(sql: "INSERT INTO snapshots (id, source_id, revision, revision_kind, digest, origin_url, managed_relative_path, byte_count, created_at) VALUES (?, ?, ?, 'contentDigest', ?, ?, ?, ?, ?)",
                arguments: [snapshot.id, source.id, digest, digest, file.absoluteString,
                    try database.layout.relativePath(for: file), try Data(contentsOf: file).count, Date()])
        }
        return AdapterContext(source: source, snapshot: snapshot, managedURL: file, derivedRootURL: database.layout.derivedURL)
    }

    private func makeJob(_ context: AdapterContext, pages: [Int], settings: OCRSettings = OCRSettings(), engine: String) -> OCRJob {
        OCRJob(id: UUID().uuidString.lowercased(), sourceID: context.source.id, snapshotID: context.snapshot.id,
            pageIndices: pages, settings: settings, engineVersion: engine, completedPages: [], failedPages: [],
            state: .running, createdAt: .now, updatedAt: .now)
    }

    private func page(_ index: Int, text: String = "Fixture text", nativeText: Bool = false) -> OCRPage {
        OCRPage(pageIndex: index, inputDigest: "fixture-page-\(index)",
            geometry: OCRGeometry(bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                pixelWidth: 100, pixelHeight: 100, transform: .identity),
            spans: nativeText ? [] : [OCRSpan(id: "span-\(index)", text: text, confidence: 0.98,
                bounds: OCRRectangle(CGRect(x: 5, y: 50, width: 90, height: 10)), order: 0)],
            usesNativeText: nativeText)
    }

    private func removingKey<T: Encodable>(_ key: String, from value: T) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object.removeValue(forKey: key)
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private struct ProvenanceFixtureEngine: LocalOCREngine {
    let identity: String
    let claim: OCRPageProvenance

    func recognize(context: AdapterContext, pageIndex: Int, settings: OCRSettings) async throws -> OCRPage {
        OCRPage(pageIndex: pageIndex, inputDigest: "fake-raster",
            geometry: OCRGeometry(bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                pixelWidth: 100, pixelHeight: 100, transform: .identity),
            spans: [OCRSpan(id: "fake-span", text: "Fixture text", confidence: 0.95,
                bounds: OCRRectangle(CGRect(x: 5, y: 50, width: 90, height: 10)), order: 0)],
            usesNativeText: false, provenance: claim)
    }
}
