import AppKit
import PDFKit
import XCTest
@testable import OneReader

@MainActor
final class PDFBookSourceTests: XCTestCase {
    func testInspectsLocalPDFDataWithStableRevisionAndFallbackSections() throws {
        let image = NSImage(size: NSSize(width: 320, height: 480))
        image.lockFocus()
        NSColor.textBackgroundColor.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        let page = try XCTUnwrap(PDFPage(image: image))
        let generated = PDFDocument()
        generated.insert(page, at: 0)
        let data = try XCTUnwrap(generated.dataRepresentation())
        let origin = URL(fileURLWithPath: "/tmp/onereader-fixture.pdf")

        let (_, inspection) = try PDFBookSource.inspect(
            data: data,
            title: "本地测试 PDF",
            sourceID: "pdf:test",
            origin: origin
        )

        XCTAssertEqual(inspection.pageCount, 1)
        XCTAssertEqual(inspection.source.kind, .pdf)
        let revision = try XCTUnwrap(inspection.source.revision)
        XCTAssertEqual(revision.count, 64)
        XCTAssertEqual(inspection.snapshot.revision, revision)
        XCTAssertEqual(inspection.snapshot.origin, origin)
        XCTAssertEqual(
            inspection.sections,
            [
                PDFSection(
                    id: "pages:0",
                    title: "第 1–1 页",
                    pageIndex: 0,
                    order: 0
                )
            ]
        )
    }
}
