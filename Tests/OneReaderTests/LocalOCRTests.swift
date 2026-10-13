import AppKit
import CoreText
import Foundation
import GRDB
import PDFKit
import XCTest
@testable import OneReader

final class LocalOCRTests: XCTestCase {
    @MainActor
    func testChangingSourceDiscardsLateOCRPanelCallbacks() async throws {
        let fixture = try makeFixture()
        let other = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: other.root)
        }
        let engine = SuspendedOCREngine()
        let controller = OCRReaderController(engine: engine)
        controller.configure(database: fixture.database)
        controller.load(context: fixture.context)
        let staleCompletion = expectation(description: "Old source must not update new source UI")
        staleCompletion.isInverted = true
        controller.start(pages: [0], settings: OCRSettings()) { _ in staleCompletion.fulfill() }
        await engine.waitUntilStarted()
        controller.load(context: other.context)
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.job)
        await engine.complete()
        await fulfillment(of: [staleCompletion], timeout: 0.2)
        XCTAssertNil(controller.job)
        XCTAssertTrue(controller.revisions.isEmpty)
        XCTAssertNil(controller.errorMessage)
    }

    func testOldJobWithoutFailureReasonsStillDecodes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let encoded = try JSONEncoder().encode(makeJob(fixture.context))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "failureReasons")
        let decoded = try JSONDecoder().decode(OCRJob.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.failureReasons.isEmpty)
    }

    func testTimeoutAndLateRecognitionCompleteOnlyOnce() async throws {
        let cancellation = OCRCancellation()
        do {
            let _: OCRPage = try await withCheckedThrowingContinuation { continuation in
                cancellation.begin(continuation)
                cancellation.expire()
                cancellation.finish(.success(samplePage()))
            }
            XCTFail("Timed out recognition must fail")
        } catch let error as OCRError {
            XCTAssertTrue(error.localizedDescription.contains("超时"))
        }
    }

    func testCancellationBeforeWorkerStartsIsImmediate() async throws {
        let cancellation = OCRCancellation()
        cancellation.cancel()
        do {
            let _: OCRPage = try await withCheckedThrowingContinuation { continuation in
                cancellation.begin(continuation)
                cancellation.finish(.success(samplePage()))
            }
            XCTFail("Cancelled recognition must fail")
        } catch is CancellationError { }
    }

    func testGeometryRoundTripAcrossRotationsAndCropOffset() throws {
        let bounds = CGRect(x: 33, y: 71, width: 400, height: 600)
        let original = CGRect(x: 85, y: 115, width: 140, height: 35)
        for rotation in [0, 90, 180, 270] {
            let angle = Double(rotation) * .pi / 180
            let rotationTransform = CGAffineTransform(rotationAngle: angle)
            let rotatedBounds = bounds.applying(rotationTransform)
            let transform = rotationTransform.concatenating(CGAffineTransform(translationX: -rotatedBounds.minX, y: -rotatedBounds.minY))
                .concatenating(CGAffineTransform(scaleX: 2, y: 2))
            let geometry = OCRGeometry(bounds: bounds, pixelWidth: Int(rotatedBounds.width * 2),
                pixelHeight: Int(rotatedBounds.height * 2), transform: transform)
            let raster = original.applying(transform)
            let normalized = CGRect(x: raster.minX / Double(geometry.pixelWidth), y: raster.minY / Double(geometry.pixelHeight),
                width: raster.width / Double(geometry.pixelWidth), height: raster.height / Double(geometry.pixelHeight))
            let recovered = try geometry.sourceRectangle(normalized: normalized).rect
            XCTAssertEqual(recovered.minX, original.minX, accuracy: 0.001)
            XCTAssertEqual(recovered.minY, original.minY, accuracy: 0.001)
            XCTAssertEqual(recovered.width, original.width, accuracy: 0.001)
            XCTAssertEqual(recovered.height, original.height, accuracy: 0.001)
        }
    }

    func testGeometryRejectsNonfiniteAndOutOfBounds() throws {
        let geometry = samplePage().geometry
        XCTAssertThrowsError(try geometry.sourceRectangle(normalized: CGRect(x: 4, y: 4, width: 1, height: 1)))
        XCTAssertThrowsError(try geometry.sourceRectangle(normalized: CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1)))
    }

    func testRevisionPublicationIsImmutableAndKeepsOldEvidence() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = try publish(fixture, text: "Original evidence")
        let oldLocator = old.locator(page: old.pages[0], span: old.pages[0].spans[0])
        let firstPlan = try await fixture.coordinator.prepareAndIndex(sourceID: fixture.context.source.id, snapshotID: fixture.context.snapshot.id)
        XCTAssertEqual(firstPlan.primaryAdapterID, OCRAdapter.id)
        let new = try publish(fixture, text: "Revised recognition")
        XCTAssertNil(try fixture.database.fetchAdapterPlan(snapshotID: fixture.context.snapshot.id))
        let secondPlan = try await fixture.coordinator.prepareAndIndex(sourceID: fixture.context.source.id, snapshotID: fixture.context.snapshot.id)
        XCTAssertNotEqual(firstPlan.id, secondPlan.id)
        let oldObservation = try await fixture.coordinator.read(plan: secondPlan, locator: oldLocator)
        XCTAssertEqual(oldObservation.content, "Original evidence")
        XCTAssertEqual(try fixture.database.activeOCRRevision(snapshotID: new.snapshotID)?.id, new.id)
        XCTAssertEqual(try fixture.database.ocrRevisions(snapshotID: new.snapshotID).count, 2)
        XCTAssertEqual(try fixture.database.searchObservations(query: "Original evidence").count, 0)
        XCTAssertEqual(try fixture.database.searchObservations(query: "Revised recognition").count, 1)
        let substring = try XCTUnwrap(fixture.database.searchObservations(query: "recognition").first)
        let selected = try await fixture.coordinator.read(plan: secondPlan, locator: substring.locator)
        XCTAssertEqual(selected.content, "recognition")
        let presentation = try await fixture.coordinator.render(plan: secondPlan, locator: substring.locator)
        XCTAssertEqual(presentation.locator.payload["rect"], new.pages[0].spans[0].bounds.locatorValue)
    }

    func testForgedSpanAndRevisionAreRejected() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let revision = try publish(fixture, text: "Evidence")
        let anchor = revision.locator(page: revision.pages[0], span: revision.pages[0].spans[0])
        for key in ["ocrRevisionID", "ocrSpanID", "rect", "ocrSchema"] {
            var payload = anchor.payload; payload[key] = "forged"
            let forged = Locator(sourceID: anchor.sourceID, snapshotID: anchor.snapshotID, adapterID: anchor.adapterID,
                payload: payload, textQuote: anchor.textQuote, fingerprint: anchor.fingerprint)
            let resolution = try await OCRAdapter(database: fixture.database).resolve(forged, in: fixture.context)
            XCTAssertEqual(resolution.state, .orphaned, key)
        }
    }

    func testSupersededJobCannotPublishAndRestartIsExplicit() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = makeJob(fixture.context)
        try fixture.database.startOCRJob(old)
        _ = try fixture.database.saveOCRPage(samplePage(), jobID: old.id)
        let replacement = makeJob(fixture.context)
        try fixture.database.startOCRJob(replacement)
        XCTAssertThrowsError(try fixture.database.finishOCRJob(old.id, state: .completed))
        let reopened = try LibraryDatabase(rootURL: fixture.database.layout.rootURL)
        XCTAssertEqual(try reopened.ocrJobs(snapshotID: old.snapshotID).first?.state, .interrupted)
        XCTAssertNil(try reopened.activeOCRRevision(snapshotID: old.snapshotID))
        XCTAssertEqual(try reopened.ocrDraftPages(jobID: old.id).count, 1)
    }

    func testNativeImageIsReadableWithoutProviderOrOCR() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = try await fixture.coordinator.prepare(sourceID: fixture.context.source.id, snapshotID: fixture.context.snapshot.id)
        XCTAssertEqual(plan.primaryAdapterID, ImageAdapter.id)
        XCTAssertNil(plan.capabilityRoutes[.read])
        let nodes = try await fixture.coordinator.list(plan: plan)
        XCTAssertEqual(ReaderContentNavigation.readableNodes(from: nodes).count, 1)
        let presentation = try await fixture.coordinator.render(plan: plan, locator: nodes[0].locator)
        XCTAssertEqual(presentation.surface, .nativeImage)
    }

    func testCancelledJobKeepsValidatedPagesAndIncompleteCannotClaimSuccess() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var job = makeJob(fixture.context, pages: [0, 1])
        try fixture.database.startOCRJob(job)
        _ = try fixture.database.saveOCRPage(samplePage(), jobID: job.id)
        XCTAssertThrowsError(try fixture.database.finishOCRJob(job.id, state: .completed))
        let revision = try fixture.database.finishOCRJob(job.id, state: .cancelled)
        XCTAssertEqual(revision?.pages.count, 1)
        job = try XCTUnwrap(fixture.database.ocrJobs(snapshotID: job.snapshotID).first)
        XCTAssertEqual(job.state, .cancelled)
    }

    func testVisionRecognizesLocalBilingualPrintedFixture() async throws {
        let fixture = try makeFixture(printedText: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let page = try await VisionOCREngine().recognize(context: fixture.context, pageIndex: 0, settings: OCRSettings())
        try page.validate()
        XCTAssertTrue(page.text.localizedCaseInsensitiveContains("OneReader local OCR"), page.text)
        XCTAssertTrue(page.text.contains("离线识别"), page.text)
        XCTAssertTrue(page.spans.allSatisfy { $0.bounds.rect.minX >= 0 && $0.bounds.rect.maxX <= 1.001 })
        XCTAssertEqual(AdapterUtilities.sha256(try Data(contentsOf: fixture.context.managedURL)), fixture.context.snapshot.digest)
    }

    func testFakeEnginePublishesAndCanBeReadOffline() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let revision = try await OCRService(database: fixture.database, engine: FixtureOCREngine())
            .run(context: fixture.context, pages: [0], settings: OCRSettings()) { _ in }
        XCTAssertEqual(revision?.pages.first?.text, "Local fixture evidence")
        let reopened = try LibraryDatabase(rootURL: fixture.database.layout.rootURL)
        XCTAssertEqual(try reopened.activeOCRRevision(snapshotID: fixture.context.snapshot.id)?.pages.first?.text, "Local fixture evidence")
    }

    func testMixedPDFUsesNativeTextAndKeepsOriginalBytes() async throws {
        let fixture = try makeFixture(printedText: true, pdf: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try Data(contentsOf: fixture.context.managedURL)
        let result = try await OCRService(database: fixture.database)
            .run(context: fixture.context, pages: [0, 1], settings: OCRSettings()) { _ in }
        let revision = try XCTUnwrap(result)
        let scan = try XCTUnwrap(revision.pages.first { $0.pageIndex == 0 }, "Scanned page did not complete")
        let nativePage = try XCTUnwrap(revision.pages.first { $0.pageIndex == 1 })
        XCTAssertFalse(scan.usesNativeText)
        XCTAssertTrue(nativePage.usesNativeText)
        XCTAssertEqual(try Data(contentsOf: fixture.context.managedURL), before)
        let plan = try await fixture.coordinator.prepareAndIndex(sourceID: fixture.context.source.id, snapshotID: fixture.context.snapshot.id)
        let recognized = try await fixture.coordinator.search(plan: plan, query: "离线识别")
        XCTAssertEqual(recognized.count, 1)
        XCTAssertEqual(recognized.first?.locator.pdfPageIndex, 0)
        let native = try await fixture.coordinator.search(plan: plan, query: "Native page evidence")
        XCTAssertEqual(native.count, 1)
        XCTAssertEqual(native.first?.adapterID, PDFAdapter.id)
    }

    func testImagePositionRemainsOriginalWhenOCRChanges() {
        let base = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: OCRAdapter.id,
            payload: ["ocrRevisionID": "old", "ocrSpanID": "span", "rect": "0,0,1,1"])
        let position = ImageViewportAnchor.locator(base: base, scale: 2.5, x: 0.35, y: 0.6)
        XCTAssertEqual(position.adapterID, ImageAdapter.id)
        XCTAssertNil(position.payload["ocrRevisionID"])
        XCTAssertEqual(ImageViewportAnchor.value("imageScale", in: position, fallback: 1), 2.5)
        XCTAssertEqual(ImageViewportAnchor.value("imageY", in: position, fallback: 0), 0.6)
        let bounded = ImageViewportAnchor.locator(base: base, scale: .infinity, x: -.infinity, y: 15)
        XCTAssertEqual(bounded.payload["imageScale"], "1.0")
        XCTAssertEqual(bounded.payload["imageY"], "1.0")
    }

    private struct Fixture {
        let root: URL
        let database: LibraryDatabase
        let coordinator: AdapterCoordinator
        let context: AdapterContext
    }

    private func makeFixture(printedText: Bool = false, pdf: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OneReader-OCR-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        if printedText {
            for (text, y) in [("OneReader local OCR", 680.0), ("离线识别与阅读", 500.0)] {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 70), .foregroundColor: NSColor.black
                ]))
                bitmap.textPosition = CGPoint(x: 100, y: y); CTLineDraw(line, bitmap)
            }
        }
        let image = try XCTUnwrap(bitmap.makeImage())
        let filename = pdf ? "fixture.pdf" : "fixture.png"
        let file = database.layout.sourcesURL.appendingPathComponent(filename)
        if pdf {
            let consumer = try XCTUnwrap(CGDataConsumer(url: file as CFURL))
            var box = CGRect(x: 0, y: 0, width: 800, height: 450)
            let writer = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
            writer.beginPDFPage(nil); writer.draw(image, in: box); writer.endPDFPage()
            writer.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Native page evidence", attributes: [
                .font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black
            ]))
            writer.textPosition = CGPoint(x: 50, y: 350); CTLineDraw(line, writer)
            writer.endPDFPage(); writer.closePDF()
        } else {
            let representation = NSBitmapImageRep(cgImage: image)
            try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(to: file)
        }
        let digest = AdapterUtilities.sha256(try Data(contentsOf: file))
        let source = Source(displayName: filename, originKind: .localFile, originURL: file, managedState: .ready)
        let snapshot = SourceSnapshot(sourceID: source.id, revision: digest, observedAt: .now, origin: file)
        // Isolated source rows let persistence/adapter tests avoid unrelated import UI work.
        try database.pool.write { db in
            try db.execute(sql: "INSERT INTO sources (id, display_name, origin_kind, origin_url, managed_state, latest_snapshot_id, is_favorite, created_at, updated_at) VALUES (?, ?, 'localFile', ?, 'ready', ?, 0, ?, ?)",
                arguments: [source.id, source.displayName, file.absoluteString, snapshot.id, Date(), Date()])
            try db.execute(sql: "INSERT INTO snapshots (id, source_id, revision, revision_kind, digest, origin_url, managed_relative_path, byte_count, created_at) VALUES (?, ?, ?, 'contentDigest', ?, ?, ?, 0, ?)",
                arguments: [snapshot.id, source.id, digest, digest, file.absoluteString,
                    try database.layout.relativePath(for: file), Date()])
        }
        return Fixture(root: root, database: database, coordinator: try AdapterCoordinator.standard(database: database),
            context: AdapterContext(source: source, snapshot: snapshot, managedURL: file, derivedRootURL: database.layout.derivedURL))
    }

    private func makeJob(_ context: AdapterContext, pages: [Int] = [0]) -> OCRJob {
        OCRJob(id: UUID().uuidString, sourceID: context.source.id, snapshotID: context.snapshot.id,
            pageIndices: pages, settings: OCRSettings(), completedPages: [], failedPages: [], state: .running, createdAt: .now, updatedAt: .now)
    }
    private func publish(_ fixture: Fixture, text: String) throws -> OCRRevision {
        let job = makeJob(fixture.context)
        try fixture.database.startOCRJob(job)
        _ = try fixture.database.saveOCRPage(samplePage(text: text), jobID: job.id)
        return try XCTUnwrap(fixture.database.finishOCRJob(job.id, state: .completed))
    }
}

private func samplePage(text: String = "Local fixture evidence") -> OCRPage {
    OCRPage(pageIndex: 0, inputDigest: "input-digest",
        geometry: OCRGeometry(bounds: CGRect(x: 0, y: 0, width: 1, height: 1), pixelWidth: 100, pixelHeight: 100, transform: CGAffineTransform(scaleX: 100, y: 100)),
        spans: [OCRSpan(id: UUID().uuidString, text: text, confidence: 0.98,
            bounds: OCRRectangle(CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1)), order: 0)], usesNativeText: false)
}

private struct FixtureOCREngine: LocalOCREngine {
    func recognize(context: AdapterContext, pageIndex: Int, settings: OCRSettings) async throws -> OCRPage { samplePage() }
}

private actor SuspendedOCREngine: LocalOCREngine {
    private var continuation: CheckedContinuation<OCRPage, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func recognize(context: AdapterContext, pageIndex: Int, settings: OCRSettings) async throws -> OCRPage {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiters.forEach { $0.resume() }; waiters.removeAll()
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func complete() { continuation?.resume(returning: samplePage()); continuation = nil }
}
