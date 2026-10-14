#if os(iOS)
import PDFKit
import SwiftUI
import UIKit
import XCTest
@testable import OneReader

@MainActor
final class NativePDFSelectionDeviceTests: XCTestCase {
    func testNativePDFSelectionOnSecondPageDoesNotInheritOCRLayer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OneReader-NativePDFSelection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mixed.pdf")
        let text = "Native page evidence"
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 300)).pdfData { renderer in
            renderer.beginPage(); renderer.beginPage()
            (text as NSString).draw(at: CGPoint(x: 30, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }
        try data.write(to: url)
        let base = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: OCRAdapter.id,
            payload: ["ocrRevisionID": "scan", "ocrSpanID": "line", "ocrSchema": "1", "derivedText": "ocr", "pageIndex": "0"])
        let document = PresentationDocument(id: "mixed", surface: .pdfKit, locator: base,
            title: "Generated mixed PDF", mediaType: "application/pdf", content: nil, contentURL: url, baseURL: nil, limitations: [])
        var result: ReaderSelection?
        let host = UIHostingController(rootView: AdapterPresentationView(document: document, captureTargetID: UUID(),
            preferences: ReaderPreferences(), onSelectionChange: { result = $0 }, onPositionChange: { _ in }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while findPDF(host.view)?.document?.pageCount != 2 {
            guard ContinuousClock.now < deadline else { XCTFail("PDF bridge not mounted"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let view = try XCTUnwrap(findPDF(host.view))
        let nativePage = try XCTUnwrap(view.document?.page(at: 1))
        view.go(to: nativePage)
        view.setCurrentSelection(try XCTUnwrap(nativePage.selection(for: NSRange(location: 0, length: text.utf16.count))), animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: view)
        let selected = try XCTUnwrap(result)
        XCTAssertEqual(selected.locator.adapterID, PDFAdapter.id)
        XCTAssertEqual(selected.locator.pdfPageIndex, 1)
        XCTAssertNil(selected.locator.payload["ocrRevisionID"])
        XCTAssertNil(selected.locator.payload["ocrSpanID"])
        XCTAssertTrue(selected.text.contains(text))
    }
    private func findPDF(_ view: UIView) -> PDFView? {
        if let pdf = view as? PDFView { return pdf }
        return view.subviews.lazy.compactMap { self.findPDF($0) }.first
    }
}
#endif
