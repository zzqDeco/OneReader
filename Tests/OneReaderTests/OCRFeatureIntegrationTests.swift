import AppKit
import CoreGraphics
import Foundation
import GRDB
import XCTest
@testable import OneReader

final class OCRFeatureIntegrationTests: XCTestCase {
    func testCapturedImageOCRTranslationsAndNotesKeepOriginalEvidenceAcrossRerun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OneReader-OCR-Integration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("generated.png")
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 900,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(canvas.makeImage()))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        let original = try Data(contentsOf: file)
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: LibraryStoragePolicy(
            largeImportThreshold: .max, minimumFreeCapacity: 0, capacityProvider: { _ in .max }))
        let adapters = try AdapterCoordinator.standard(database: database)
        let capture = CaptureCoordinator(database: database, library: library,
            remoteImporter: RemoteSourceImporter(library: library), adapters: adapters)
        let receipt = try await capture.receive(.local(file))
        let result = await capture.process(receipt.id)
        let imported = try XCTUnwrap(result?.imported)
        let managedURL = try database.layout.url(forRelativePath: XCTUnwrap(imported.snapshot.managedRelativePath))
        let context = AdapterContext(source: imported.source, snapshot: imported.snapshot,
            managedURL: managedURL, derivedRootURL: database.layout.derivedURL)
        let longText = String(repeating: "Original evidence phrase. ", count: 180)
        let texts = [longText, "Repeated line.", "Repeated line."]
        let firstResult = try await OCRService(database: database, engine: IntegrationOCREngine(texts: texts))
            .run(context: context, pages: [0], settings: OCRSettings()) { _ in }
        let revision = try XCTUnwrap(firstResult)
        let plan = try await adapters.prepareAndIndex(sourceID: imported.source.id, snapshotID: imported.snapshot.id)
        let document = try await adapters.render(plan: plan)
        XCTAssertEqual(document.surface, .nativeImage)
        let segments = try await TranslationSourceBuilder.prepare(document: document, locator: document.locator,
            nextLocator: nil, selection: nil, plan: plan, coordinator: adapters, database: database)
        XCTAssertGreaterThan(segments.count, 1, "Long OCR pages must retain exact sub-fragment coordinates")
        for segment in segments {
            XCTAssertNotNil(segment.locator.payload["rect"], "A prepared fragment must already carry verified native geometry")
            let observed = try await adapters.read(plan: plan, locator: segment.locator)
            XCTAssertEqual(observed.content, segment.originalText)
            let rendered = try await adapters.render(plan: plan, locator: segment.locator)
            XCTAssertNotNil(rendered.locator.payload["rect"])
            XCTAssertEqual(rendered.locator.payload["ocrRevisionID"], revision.id)
        }

        let page = try XCTUnwrap(revision.pages.first)
        let selectedSpan = page.spans[2]
        let selectedLocator = revision.locator(page: page, span: selectedSpan)
        let selection = ReaderSelection(text: selectedSpan.text, locator: selectedLocator)
        let selected = try await TranslationSourceBuilder.prepare(document: document, locator: selectedLocator,
            nextLocator: nil, selection: selection, plan: plan, coordinator: adapters, database: database)
        let selectedSegment = try XCTUnwrap(selected.first)
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selectedSegment.locator.payload["startUTF16"], String(longText.utf16.count + texts[1].utf16.count + 2))
        let selectedObservation = try await adapters.read(plan: plan, locator: selectedSegment.locator)
        XCTAssertEqual(selectedObservation.content, texts[2])
        let annotation = Annotation(id: "ocr-note", spaceID: imported.space.id,
            sourceID: imported.source.id, snapshotID: imported.snapshot.id, kind: .highlight,
            locator: selectedSegment.locator, anchorState: .current, selectedText: texts[2],
            note: "PRIVATE_OCR_NOTE", color: "yellow", createdAt: .now, updatedAt: .now)
        try database.saveAnnotation(annotation)
        var progress = ReadingProgress.empty
        progress.sourcePositions[imported.source.id] = SourcePosition(sourceID: imported.source.id,
            locator: ImageViewportAnchor.locator(base: document.locator, scale: 2, x: 0.25, y: 0.4),
            updatedAt: .now, progressFraction: nil, granularity: .document, displayLabel: "Original image")
        try database.saveReadingProgress(progress, spaceID: imported.space.id)
        let storedProgress = try database.fetchReadingProgress(spaceID: imported.space.id)

        _ = try await OCRService(database: database, engine: IntegrationOCREngine(texts: ["New recognition."]))
            .run(context: context, pages: [0], settings: OCRSettings()) { _ in }
        let newPlan = try await adapters.prepareAndIndex(sourceID: imported.source.id, snapshotID: imported.snapshot.id)
        XCTAssertNotEqual(newPlan.id, plan.id)
        let originalEvidence = try await adapters.read(plan: newPlan, locator: annotation.locator)
        XCTAssertEqual(originalEvidence.content, texts[2])
        let export = try await database.captureNotesExport(query: NotesQuery(sourceID: imported.source.id), options: NotesExportOptions())
        let markdown = NotesMarkdownExporter.renderSource(export.entries, snapshot: export)
        XCTAssertTrue(markdown.contains(NotesMarkdownExporter.escaped("Repeated line.")))
        XCTAssertTrue(markdown.contains("PRIVATE\\_OCR\\_NOTE"))
        XCTAssertFalse(markdown.contains("New recognition."))
        XCTAssertEqual(try database.fetchReadingProgress(spaceID: imported.space.id), storedProgress)
        XCTAssertEqual(try Data(contentsOf: managedURL), original)
        let migrations = try await database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        XCTAssertEqual(Array(migrations.suffix(4)), ["v11-capture-inbox", "v12-annotation-notes-center", "v13-bilingual-translation-cache", "v14-local-ocr"])
    }
}

private struct IntegrationOCREngine: LocalOCREngine {
    let texts: [String]
    func recognize(context: AdapterContext, pageIndex: Int, settings: OCRSettings) async throws -> OCRPage {
        OCRPage(pageIndex: pageIndex, inputDigest: context.snapshot.digest,
            geometry: OCRGeometry(bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                pixelWidth: 1200, pixelHeight: 900, transform: CGAffineTransform(scaleX: 1200, y: 900)),
            spans: texts.enumerated().map { index, text in
                OCRSpan(id: "span-\(index)", text: text, confidence: 0.95,
                    bounds: OCRRectangle(CGRect(x: 0.1, y: 0.8 - Double(index) * 0.2, width: 0.8, height: 0.1)),
                    order: index)
            }, usesNativeText: false)
    }
}
