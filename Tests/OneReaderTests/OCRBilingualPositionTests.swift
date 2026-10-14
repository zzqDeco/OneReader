import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import OneReader

@MainActor
final class OCRBilingualPositionTests: XCTestCase {
    func testImageTranslatedRegionSurvivesSaveReopenAndNativeScrolling() async throws {
        try await exercisePositionRoundTrip(pdf: false)
    }

    func testPDFTranslatedRegionSurvivesSaveReopenAndNativeScrolling() async throws {
        try await exercisePositionRoundTrip(pdf: true)
    }

    private func exercisePositionRoundTrip(pdf: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OneReader-OCR-BilingualPosition-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(pdf ? "generated.pdf" : "generated.png")
        if pdf {
            var bounds = CGRect(x: 0, y: 0, width: 600, height: 1_200)
            let writer = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)), mediaBox: &bounds, nil))
            writer.beginPDFPage(nil); writer.endPDFPage(); writer.closePDF()
        } else {
            let canvas = try XCTUnwrap(CGContext(data: nil, width: 1_200, height: 900, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(canvas.makeImage())).representation(using: .png, properties: [:])).write(to: url)
        }
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: LibraryStoragePolicy(
            largeImportThreshold: .max, minimumFreeCapacity: 0, capacityProvider: { _ in .max }))
        let imported = try await library.importLocalSource(at: url)
        let context = AdapterContext(source: imported.source, snapshot: imported.snapshot,
            managedURL: imported.managedURL, derivedRootURL: database.layout.derivedURL)
        let recognized = try await OCRService(database: database, engine: PositionOCREngine(pdf: pdf))
            .run(context: context, pages: [0], settings: OCRSettings()) { _ in }
        let revision = try XCTUnwrap(recognized)
        let defaultsID = "OneReader.OCRBilingualPosition.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsID))
        defer { defaults.removePersistentDomain(forName: defaultsID) }
        let model = AppModel(libraryRootURL: database.layout.rootURL, defaults: defaults,
            secretStore: InMemoryProviderSecretStore(), automaticBootstrap: false)
        await model.bootstrap(); model.openSpace(imported.space.id)
        try await waitUntil { model.presentationDocument != nil }
        model.prepareBilingualReading(useSelection: false)
        try await waitUntil { !model.bilingualReading.isBusy }
        let segments = model.bilingualReading.rows.map(\.segment)
        XCTAssertEqual(segments.count, 2, model.bilingualReading.status)
        let first = try XCTUnwrap(segments.first)
        let target = try XCTUnwrap(segments.last)
        let rectangle = try XCTUnwrap(target.locator.payload["rect"], "Geometry must be verified before translated scrolling saves progress")
        XCTAssertNotEqual(first.locator.payload["rect"], rectangle)
        model.updateBilingualReadingPosition(target.locator)
        model.flushReadingPosition()
        let stored = try XCTUnwrap(database.fetchReadingProgress(spaceID: imported.space.id).sourcePositions[imported.source.id]?.locator)
        XCTAssertEqual(stored.adapterID, pdf ? PDFAdapter.id : ImageAdapter.id)
        XCTAssertEqual(stored.payload["rect"], rectangle)
        for key in ["ocrRevisionID", "ocrSpanID", "derivedText", "startUTF16", "endUTF16"] { XCTAssertNil(stored.payload[key]) }

        let reopened = AppModel(libraryRootURL: database.layout.rootURL, defaults: defaults,
            secretStore: InMemoryProviderSecretStore(), automaticBootstrap: false)
        await reopened.bootstrap(); reopened.openSpace(imported.space.id)
        try await waitUntil { reopened.presentationDocument != nil }
        let recovered = try XCTUnwrap(reopened.currentPositionLocator)
        XCTAssertEqual(recovered.payload["rect"], rectangle)
        reopened.prepareBilingualReading(useSelection: false)
        try await waitUntil { !reopened.bilingualReading.isBusy }
        let restoredSegments = reopened.bilingualReading.rows.map(\.segment)
        XCTAssertEqual(BilingualAnchorResolver.segmentID(for: recovered, among: restoredSegments), target.id)

        // Return to the FIRST translated fragment, then really scroll the original down
        // to the SECOND region. The old text offsets must not survive native capture.
        reopened.returnToBilingualOriginal(first)
        try await waitUntil { reopened.presentationDocument?.locator.stableID == first.locator.stableID }
        let document = try XCTUnwrap(reopened.presentationDocument)
        let movement = try await captureNativeMovement(document: document, revision: revision)
        for key in ["startUTF16", "endUTF16", "pageTextStartUTF16", "pageTextEndUTF16", "indexTextRange"] {
            XCTAssertNil(movement.locator.payload[key], "A native viewport must not inherit \(key)")
        }
        reopened.updateReadingPosition(movement); reopened.flushReadingPosition()
        let moved = try XCTUnwrap(database.fetchReadingProgress(spaceID: imported.space.id).sourcePositions[imported.source.id]?.locator)
        XCTAssertEqual(BilingualAnchorResolver.segmentID(for: moved, among: restoredSegments), target.id,
            "Follow original must use the moved viewport, not the first fragment's stale offsets")
        let afterScroll = try LibraryDatabase(rootURL: database.layout.rootURL)
        let afterRestart = try XCTUnwrap(afterScroll.fetchReadingProgress(spaceID: imported.space.id).sourcePositions[imported.source.id]?.locator)
        XCTAssertEqual(BilingualAnchorResolver.segmentID(for: afterRestart, among: restoredSegments), target.id)
        XCTAssertEqual(try database.fetchSnapshots(sourceID: imported.source.id).first?.digest, imported.snapshot.digest)
    }

    private func captureNativeMovement(document: PresentationDocument, revision: OCRRevision) async throws -> ReadingPositionUpdate {
        var published: ReadingPositionUpdate?
        let targetID = UUID()
        let root: AnyView
        if document.surface == .pdfKit {
            root = AnyView(AdapterPresentationView(document: document, captureTargetID: targetID,
                preferences: ReaderPreferences(), onSelectionChange: { _ in }, onPositionChange: { published = $0 }))
        } else {
            root = AnyView(OCRImagePresentation(document: document, revision: revision, selectable: false,
                onSelection: { _ in }, onPosition: { published = $0 }, captureTargetID: targetID))
        }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = CGRect(x: 0, y: 0, width: 500, height: 400); host.layoutSubtreeIfNeeded()
        if document.surface == .pdfKit {
            try await waitUntil { self.descendants(host, as: PDFView.self).first?.document != nil }
            let view = try XCTUnwrap(descendants(host, as: PDFView.self).first)
            view.autoScales = false; view.scaleFactor = 1; view.layoutDocumentView()
            let page = try XCTUnwrap(view.document?.page(at: 0))
            view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: 450)))
            return try XCTUnwrap(PDFViewportAnchor.capture(from: view, base: document.locator))
        }
        try await waitUntil { published != nil }
        let scroll = try XCTUnwrap(descendants(host, as: NSScrollView.self).first)
        let canvas = try XCTUnwrap(scroll.documentView)
        scroll.magnification = 1; canvas.scroll(CGPoint(x: 0, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
        published = nil
        NotificationCenter.default.post(name: ReadingPositionCaptureSignal.requested, object: nil)
        return try XCTUnwrap(published)
    }

    private func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { self.descendants($0, as: type) }
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ReadingAgentError.interrupted }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct PositionOCREngine: LocalOCREngine {
    let pdf: Bool
    let identity = "generated-position-fixture-v1"
    func recognize(context: AdapterContext, pageIndex: Int, settings: OCRSettings) async throws -> OCRPage {
        let width: Double = pdf ? 600 : 1
        let height: Double = pdf ? 1_200 : 1
        let texts = [String(repeating: "A", count: 3_999), "Second OCR paragraph with original evidence."]
        return OCRPage(pageIndex: 0, inputDigest: context.snapshot.digest,
            geometry: OCRGeometry(bounds: CGRect(x: 0, y: 0, width: width, height: height),
                pixelWidth: 1_200, pixelHeight: pdf ? 2_400 : 900,
                transform: CGAffineTransform(scaleX: 1_200 / width, y: (pdf ? 2_400 : 900) / height)),
            spans: texts.enumerated().map { index, text in
                OCRSpan(id: "position-span-\(index)", text: text, confidence: 1,
                    bounds: OCRRectangle(CGRect(x: width * 0.1, y: height * (index == 0 ? 0.8 : 0.2),
                        width: width * 0.8, height: height * 0.1)), order: index)
            }, usesNativeText: false)
    }
}
