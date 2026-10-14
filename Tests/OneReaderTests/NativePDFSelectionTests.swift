import AppKit
import CoreText
import PDFKit
import SwiftUI
import XCTest
@testable import OneReader

@MainActor
final class NativePDFSelectionTests: XCTestCase {
    func testNativeSelectionNeverInheritsDerivedOCRIdentityOrOffsets() throws {
        let base = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: OCRAdapter.id,
            payload: ["path": "book.pdf", "ocrRevisionID": "old", "ocrSpanID": "span", "ocrSchema": "1",
                "derivedText": "ocr", "startUTF16": "30", "endUTF16": "60", "indexTextRange": "utf16",
                "pageTextStartUTF16": "5", "pageTextEndUTF16": "15", "positionKind": "viewport", "viewportX": "0"])
        let result = try XCTUnwrap(NativePDFSelectionAnchor.selection(base: base, pageIndex: 1,
            rectangle: CGRect(x: 20, y: 130, width: 200, height: 25), text: "Native text"))
        XCTAssertEqual(result.locator.adapterID, PDFAdapter.id)
        XCTAssertEqual(result.locator.payload["pageIndex"], "1")
        XCTAssertEqual(result.locator.relativePath, "book.pdf")
        XCTAssertEqual(result.locator.textQuote?.exact, "Native text")
        for key in ["ocrRevisionID", "ocrSpanID", "ocrSchema", "derivedText", "startUTF16", "endUTF16",
            "indexTextRange", "pageTextStartUTF16", "pageTextEndUTF16", "positionKind", "viewportX"] {
            XCTAssertNil(result.locator.payload[key], key)
        }
        XCTAssertNil(NativePDFSelectionAnchor.selection(base: base, pageIndex: -1, rectangle: .zero, text: "invalid"))
    }

    func testProductionPDFBridgeSelectsNativePageWhileDocumentWasOpenedFromOCR() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OneReader-NativePDFSelection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mixed.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let writer = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)), mediaBox: &bounds, nil))
        writer.beginPDFPage(nil); writer.endPDFPage()
        writer.beginPDFPage(nil)
        let text = "Native page evidence"
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black]))
        writer.textPosition = CGPoint(x: 30, y: 200); CTLineDraw(line, writer)
        writer.endPDFPage(); writer.closePDF()
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: LibraryStoragePolicy(
            largeImportThreshold: .max, minimumFreeCapacity: 0, capacityProvider: { _ in .max }))
        let imported = try await library.importLocalSource(at: url)
        let coordinator = try AdapterCoordinator.standard(database: database)
        let plan = try await coordinator.prepare(sourceID: imported.source.id, snapshotID: imported.snapshot.id)
        let base = Locator(sourceID: imported.source.id, snapshotID: imported.snapshot.id, adapterID: OCRAdapter.id,
            payload: ["ocrRevisionID": "displayed-scan", "ocrSpanID": "scan-line", "ocrSchema": "1", "derivedText": "ocr", "pageIndex": "0"])
        let document = PresentationDocument(id: "mixed", surface: .pdfKit, locator: base,
            title: "Generated mixed PDF", mediaType: "application/pdf", content: nil,
            contentURL: imported.managedURL, baseURL: nil, limitations: [])
        var published: ReaderSelection?
        let host = NSHostingView(rootView: AdapterPresentationView(document: document, captureTargetID: UUID(),
            preferences: ReaderPreferences(), onSelectionChange: { published = $0 }, onPositionChange: { _ in }))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = CGRect(x: 0, y: 0, width: 500, height: 400); host.layoutSubtreeIfNeeded()
        try await waitUntil { self.findPDF(host)?.document?.pageCount == 2 }
        let view = try XCTUnwrap(findPDF(host))
        let nativePage = try XCTUnwrap(view.document?.page(at: 1))
        view.go(to: nativePage)
        view.setCurrentSelection(try XCTUnwrap(nativePage.selection(for: NSRange(location: 0, length: text.utf16.count))), animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: view)
        let selected = try XCTUnwrap(published)
        XCTAssertEqual(selected.locator.adapterID, PDFAdapter.id)
        XCTAssertEqual(selected.locator.pdfPageIndex, 1)
        XCTAssertNil(selected.locator.payload["ocrRevisionID"])
        let observation = try await coordinator.read(plan: plan, locator: selected.locator)
        XCTAssertTrue(observation.content.contains(text))
        let resolution = try await coordinator.resolve(selected.locator, against: imported.snapshot.id)
        XCTAssertEqual(resolution.state, .current)
        let annotation = Annotation(id: "native-after-ocr", spaceID: imported.space.id, sourceID: imported.source.id,
            snapshotID: imported.snapshot.id, kind: .highlight, locator: selected.locator, anchorState: .current,
            selectedText: selected.text, note: nil, color: "yellow", createdAt: .now, updatedAt: .now)
        try database.saveAnnotation(annotation)
        XCTAssertEqual(try database.fetchAnnotations(spaceID: imported.space.id).first?.locator.adapterID, PDFAdapter.id)
    }

    private func findPDF(_ view: NSView) -> PDFView? {
        if let pdf = view as? PDFView { return pdf }
        return view.subviews.lazy.compactMap { self.findPDF($0) }.first
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "NativePDFSelection", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
