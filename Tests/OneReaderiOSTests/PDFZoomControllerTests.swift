#if os(iOS)
import PDFKit
import UIKit
import XCTest
@testable import OneReader

@MainActor
final class PDFZoomControllerTests: XCTestCase {
    func testHostApplicationOptsIntoProMotion() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool, true)
    }

    func testInitialScaleFitsNativePageWidthAfterNonzeroLayout() throws {
        let view = try makeView()
        let controller = PDFZoomController()
        view.frame = .zero
        controller.update(view, defaultScale: 1, request: nil, pageIndex: 0)
        XCTAssertNil(controller.fitWidthScale)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        view.layoutIfNeeded()
        controller.update(view, defaultScale: 1, request: nil, pageIndex: 0)
        view.layoutDocumentView()
        let page = try XCTUnwrap(view.document?.page(at: 0))
        let displayed = view.convert(page.bounds(for: view.displayBox), from: page)
        XCTAssertLessThanOrEqual(displayed.width, 390)
        XCTAssertGreaterThan(displayed.width, 350)
    }

    func testUserScaleSurvivesRepeatedHostPositionUpdates() throws {
        let view = try makeView()
        let controller = PDFZoomController()
        controller.update(view, defaultScale: 1, request: nil, pageIndex: 0)
        let fit = try XCTUnwrap(controller.fitWidthScale)
        view.scaleFactor = fit * 1.8
        for _ in 0..<8 { controller.update(view, defaultScale: 1, request: nil, pageIndex: 0) }
        XCTAssertEqual(view.scaleFactor, fit * 1.8, accuracy: 0.001)
        controller.update(view, defaultScale: 1.4, request: nil, pageIndex: 0)
        XCTAssertEqual(view.scaleFactor, fit * 1.4, accuracy: 0.001)
    }

    func testCommandsUseLiveScaleAndAreConsumedOnlyOnce() throws {
        let view = try makeView()
        let controller = PDFZoomController()
        controller.update(view, defaultScale: 1, request: nil, pageIndex: 0)
        let fit = try XCTUnwrap(controller.fitWidthScale)
        view.scaleFactor = fit * 2
        let request = PDFZoomRequest(action: .zoomIn)
        controller.update(view, defaultScale: 1, request: request, pageIndex: 0)
        XCTAssertEqual(view.scaleFactor, fit * 2.5, accuracy: 0.001)
        view.scaleFactor = fit * 3
        controller.update(view, defaultScale: 1, request: request, pageIndex: 0)
        XCTAssertEqual(view.scaleFactor, fit * 3, accuracy: 0.001)
        controller.update(view, defaultScale: 1, request: PDFZoomRequest(action: .zoomOut), pageIndex: 0)
        XCTAssertEqual(view.scaleFactor, fit * 2.4, accuracy: 0.001)
        controller.update(view, defaultScale: 1, request: PDFZoomRequest(action: .fitWidth), pageIndex: 0)
        XCTAssertEqual(view.scaleFactor, fit, accuracy: 0.001)
    }

    func testWidthChangePreservesRelativeNativeZoom() throws {
        let view = try makeView()
        let controller = PDFZoomController()
        controller.update(view, defaultScale: 1, request: nil, pageIndex: 0)
        view.scaleFactor = try XCTUnwrap(controller.fitWidthScale) * 1.6
        view.frame.size.width = 700
        controller.update(view, defaultScale: 1, request: nil, pageIndex: 0)
        XCTAssertEqual(try XCTUnwrap(controller.relativeScale(in: view)), 1.6, accuracy: 0.001)
    }

    func testCommandsRespectNativeBoundsAndInvalidDefaultIsFinite() throws {
        let view = try makeView()
        let controller = PDFZoomController()
        controller.update(view, defaultScale: .nan, request: nil, pageIndex: 0)
        for _ in 0..<30 { controller.update(view, defaultScale: .nan, request: PDFZoomRequest(action: .zoomIn), pageIndex: 0) }
        XCTAssertEqual(view.scaleFactor, view.maxScaleFactor, accuracy: 0.001)
        for _ in 0..<40 { controller.update(view, defaultScale: .nan, request: PDFZoomRequest(action: .zoomOut), pageIndex: 0) }
        XCTAssertEqual(view.scaleFactor, view.minScaleFactor, accuracy: 0.001)
        XCTAssertTrue(view.scaleFactor.isFinite)
    }

    func testRotatedPageFitsItsDisplayedWidth() throws {
        let view = try makeView()
        let page = try XCTUnwrap(view.document?.page(at: 0))
        page.rotation = 90
        let controller = PDFZoomController()
        controller.update(view, defaultScale: 1, request: nil, pageIndex: 0)
        view.layoutDocumentView()
        let displayed = view.convert(page.bounds(for: view.displayBox), from: page)
        XCTAssertLessThanOrEqual(displayed.width, view.bounds.width + 1)
        XCTAssertGreaterThan(displayed.width, view.bounds.width * 0.9)
    }

    func testInitialFitUsesSavedPageRatherThanPDFKitInitialPage() throws {
        let view = try makeMixedWidthView()
        XCTAssertEqual(view.currentPage, view.document?.page(at: 0))
        let controller = PDFZoomController()
        controller.update(view, defaultScale: 1, request: nil, pageIndex: 1)
        let restoredPage = try XCTUnwrap(view.document?.page(at: 1))
        view.go(to: restoredPage)
        controller.refitAfterNavigation(to: restoredPage, in: view)
        view.layoutDocumentView()
        let displayed = view.convert(restoredPage.bounds(for: view.displayBox), from: restoredPage)
        XCTAssertLessThanOrEqual(displayed.width, view.bounds.width + 1)
        XCTAssertGreaterThan(displayed.width, view.bounds.width * 0.9)
        XCTAssertEqual(try XCTUnwrap(controller.relativeScale(in: view)), 1, accuracy: 0.001)
    }

    func testDeferredDifferentPageRefitPreservesLiveRelativeZoom() throws {
        let view = try makeMixedWidthView()
        let controller = PDFZoomController()
        controller.update(view, defaultScale: 1, request: nil, pageIndex: 0)
        view.scaleFactor = try XCTUnwrap(controller.fitWidthScale) * 1.6
        let nextPage = try XCTUnwrap(view.document?.page(at: 1))
        view.go(to: nextPage)
        controller.refitAfterNavigation(to: nextPage, in: view)
        XCTAssertEqual(try XCTUnwrap(controller.relativeScale(in: view)), 1.6, accuracy: 0.001)
        XCTAssertEqual(view.scaleFactor, try XCTUnwrap(controller.fitWidthScale) * 1.6, accuracy: 0.001)
    }

    private func makeMixedWidthView() throws -> PDFView {
        let view = try makeView()
        let wide = try makeView()
        let second = try XCTUnwrap(wide.document?.page(at: 0))
        second.setBounds(CGRect(x: 0, y: 0, width: 900, height: 1_600), for: .mediaBox)
        second.setBounds(CGRect(x: 0, y: 0, width: 900, height: 1_600), for: .cropBox)
        view.document?.insert(second, at: 1)
        view.layoutDocumentView()
        return view
    }

    private func makeView() throws -> PDFView {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 1_600))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("Native PDF zoom test" as NSString).draw(at: CGPoint(x: 20, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
        }
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.document = try XCTUnwrap(PDFDocument(data: data))
        view.layoutIfNeeded()
        return view
    }
}
#endif
