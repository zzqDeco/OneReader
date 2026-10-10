import AppKit
import PDFKit
import XCTest
@testable import OneReader

@MainActor
final class PDFReadingPositionTests: XCTestCase {
    func testViewportPointRejectsMalformedOutOfPageAndSelectionLocators() {
        let bounds = CGRect(x: 0, y: 0, width: 420, height: 1_600)
        XCTAssertEqual(PDFViewportAnchor.point(in: locator(x: "20", y: "920"), pageBounds: bounds), CGPoint(x: 20, y: 920))
        XCTAssertNil(PDFViewportAnchor.point(in: locator(), pageBounds: .infinite))
        XCTAssertNil(PDFViewportAnchor.point(in: locator(), pageBounds: .zero))
        for (x, y) in [("nan", "20"), ("0", "inf"), ("-1", "10"), ("421", "10"), ("10", "1601")] {
            XCTAssertNil(PDFViewportAnchor.point(in: locator(x: x, y: y), pageBounds: bounds))
        }
        let selection = Locator(
            sourceID: "source", snapshotID: "snapshot", adapterID: PDFAdapter.id,
            payload: locator(x: "20", y: "920").payload,
            textQuote: TextQuote(prefix: nil, exact: "Selected quote", suffix: nil)
        )
        XCTAssertNil(PDFViewportAnchor.point(in: selection, pageBounds: bounds), "Selection geometry takes priority over leftover viewport metadata")
    }

    func testScreenPlacementRejectsInvalidPartialAndSelectionMetadata() {
        let base = locator()
        for (x, y) in [("nan", "0"), ("0", "inf"), ("-0.1", "0"), ("1.1", "0"), ("0", "-1"), ("0", "1.01"), ("", "0")] {
            var payload = base.payload
            payload["viewportScreenX"] = x
            payload["viewportScreenY"] = y
            let invalid = Locator(sourceID: base.sourceID, snapshotID: base.snapshotID, adapterID: base.adapterID, payload: payload)
            XCTAssertNil(PDFViewportAnchor.screenPosition(in: invalid))
        }
        var payload = base.payload
        payload["viewportScreenX"] = "0.3"
        XCTAssertNil(PDFViewportAnchor.screenPosition(in: Locator(sourceID: base.sourceID, snapshotID: base.snapshotID, adapterID: base.adapterID, payload: payload)))
        payload["viewportScreenY"] = "0.1"
        let viewport = Locator(sourceID: base.sourceID, snapshotID: base.snapshotID, adapterID: base.adapterID, payload: payload)
        XCTAssertEqual(PDFViewportAnchor.screenPosition(in: viewport), CGPoint(x: 0.3, y: 0.1))
        let selection = Locator(sourceID: base.sourceID, snapshotID: base.snapshotID, adapterID: base.adapterID, payload: payload,
                                textQuote: TextQuote(prefix: nil, exact: "Selected quote", suffix: nil))
        XCTAssertNil(PDFViewportAnchor.screenPosition(in: selection))
        PDFViewportAnchor.payloadKeys.forEach { payload[$0] = nil }
        XCTAssertFalse(payload.isEmpty, "Page identity survives selection metadata cleanup")
        XCTAssertEqual(payload["pageIndex"], "0")
        XCTAssertFalse(payload.keys.contains { $0.hasPrefix("viewport") || $0 == "positionKind" })
    }

    func testNativePDFViewportRoundTripPreservesWithinPagePosition() async throws {
        let view = makeView()
        let page = try XCTUnwrap(view.document?.page(at: 0))
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: 950)))
        try await Task.sleep(for: .milliseconds(80))
        let update = try XCTUnwrap(PDFViewportAnchor.capture(from: view, base: locator()))
        XCTAssertEqual(update.locator.payload["pageIndex"], "0")
        XCTAssertNotNil(PDFPageRectAnchor.parse(update.locator.payload["rect"]))
        let point = try XCTUnwrap(PDFViewportAnchor.point(in: update.locator, pageBounds: page.bounds(for: .cropBox)))
        XCTAssertLessThan(point.y, 1_200)
        XCTAssertGreaterThan(point.y, 500)

        let restored = makeView()
        let restoredPage = try XCTUnwrap(restored.document?.page(at: 0))
        restored.go(to: PDFDestination(page: restoredPage, at: point))
        try await Task.sleep(for: .milliseconds(80))
        let reread = try XCTUnwrap(PDFViewportAnchor.capture(from: restored, base: locator()))
        XCTAssertEqual(Double(reread.locator.payload["viewportY"] ?? "") ?? -1, Double(point.y), accuracy: 2)
    }

    func testLifecycleCaptureRequiresMatchingTargetAndStopsAfterDismantle() throws {
        let view = makeView()
        let target = UUID()
        var update: ReadingPositionUpdate?
        let observer = PDFReadingPositionObserver(base: { self.locator() }, targetID: { target }, isApplyingAnchor: { false }, publish: { update = $0 })
        observer.observe(view)
        let wrong = ReadingPositionCaptureRequest(targetID: UUID(), sourceID: "source", snapshotID: "snapshot") { update = $0 }
        NotificationCenter.default.post(name: ReadingPositionCaptureSignal.requested, object: wrong)
        XCTAssertFalse(wrong.isClaimed)
        XCTAssertNil(update)
        let request = ReadingPositionCaptureRequest(targetID: target, sourceID: "source", snapshotID: "snapshot") { update = $0 }
        NotificationCenter.default.post(name: ReadingPositionCaptureSignal.requested, object: request)
        XCTAssertTrue(request.isClaimed)
        XCTAssertEqual(update?.locator.sourceID, "source")
        XCTAssertEqual(update?.locator.payload["positionKind"], "viewport")
        observer.stop()
        update = nil
        let stopped = ReadingPositionCaptureRequest(targetID: target, sourceID: "source", snapshotID: "snapshot") { update = $0 }
        NotificationCenter.default.post(name: ReadingPositionCaptureSignal.requested, object: stopped)
        XCTAssertFalse(stopped.isClaimed)
        XCTAssertNil(update)
    }

    func testZoomedMixedWidthPDFRestoresActualHorizontalAndVerticalPlacement() async throws {
        try await assertMixedWidthRecovery(rotation: 0)
    }

    func testZoomedMixedWidthPDFRestoresScreenPlacementAcrossPageRotations() async throws {
        for rotation in [90, 180, 270] { try await assertMixedWidthRecovery(rotation: rotation) }
    }

    func testZoomedMixedWidthPDFRestoresPlacementAfterDocumentSwitch() async throws {
        try await assertMixedWidthRecovery(rotation: 0, switchDocument: true)
    }

    func testDeferredZoomedPDFRestoresBothAxesOnlyOnceAfterViewportLayout() async throws {
        try await assertMixedWidthRecovery(rotation: 0, deferredLayout: true)
    }

    func testViewportRestoreKeepsLegacyBehaviorAndRejectsInvalidPageOrQuote() async throws {
        let view = makeView()
        let page = try XCTUnwrap(view.document?.page(at: 0))
        XCTAssertTrue(PDFViewportAnchor.restore(in: view, page: page, locator: locator(x: "0", y: "900")))
        try await Task.sleep(for: .milliseconds(80))
        let point = try XCTUnwrap(PDFViewportAnchor.capture(from: view, base: locator()))
        XCTAssertEqual(try XCTUnwrap(Double(point.locator.payload["viewportY"] ?? "")), 900, accuracy: 2)
        XCTAssertFalse(PDFViewportAnchor.restore(in: view, page: page, locator: locator(x: "-1", y: "900")))
        let selection = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: PDFAdapter.id,
                                payload: locator(x: "0", y: "900").payload, textQuote: TextQuote(prefix: nil, exact: "Quote", suffix: nil))
        XCTAssertFalse(PDFViewportAnchor.restore(in: view, page: page, locator: selection))
    }

    private func assertMixedWidthRecovery(rotation: Int, switchDocument: Bool = false, deferredLayout: Bool = false) async throws {
        let view = makeMixedWidthView(rotation: rotation)
        let page = try XCTUnwrap(view.document?.page(at: 0))
        let displayed = view.convert(page.bounds(for: view.displayBox), from: page)
        let target = view.convert(CGPoint(x: displayed.minX, y: displayed.maxY - 750), to: page)
        view.go(to: PDFDestination(page: page, at: target))
        try await Task.sleep(for: .milliseconds(80))
        let scroll = try XCTUnwrap(view.documentView?.enclosingScrollView)
        let clip = scroll.contentView
        let minimum = clip.constrainBoundsRect(CGRect(origin: .zero, size: clip.bounds.size)).minX
        let maximum = clip.constrainBoundsRect(CGRect(x: 100_000, y: clip.bounds.minY, width: clip.bounds.width, height: clip.bounds.height)).minX
        XCTAssertGreaterThan(maximum - minimum, 200, "Wide poster must enable horizontal scrolling")
        clip.scroll(to: CGPoint(x: minimum + (maximum - minimum) * 0.3, y: clip.bounds.minY))
        scroll.reflectScrolledClipView(clip)
        try await Task.sleep(for: .milliseconds(80))

        let update = try XCTUnwrap(PDFViewportAnchor.capture(from: view, base: locator()))
        let point = try XCTUnwrap(PDFViewportAnchor.point(in: update.locator, pageBounds: page.bounds(for: view.displayBox)))
        let before = view.convert(point, from: page)
        let beforeClip = clip.bounds.origin
        XCTAssertNotNil(PDFViewportAnchor.screenPosition(in: update.locator))
        if rotation == 0 { XCTAssertEqual(point.x, 0, accuracy: 1) }
        XCTAssertGreaterThan(before.x - view.bounds.minX, 20, "The bounded page anchor must include a visible side margin")

        let restored: ReadingPDFView
        if switchDocument {
            let document = view.document
            view.document = makeView().document
            view.layoutDocumentView()
            view.document = document
            view.scaleFactor = 1.5
            view.layoutDocumentView()
            restored = view
        } else {
            restored = makeMixedWidthView(rotation: rotation, frame: deferredLayout ? .zero : NSRect(x: 0, y: 0, width: 900, height: 650))
        }
        let restoredPage = try XCTUnwrap(restored.document?.page(at: 0))
        var applications = 0
        if deferredLayout {
            XCTAssertFalse(PDFViewportAnchor.restore(in: restored, page: restoredPage, locator: update.locator))
            restored.pendingAnchor = { mounted in
                applications += 1
                XCTAssertNotNil(mounted.documentView?.enclosingScrollView)
                XCTAssertTrue(PDFViewportAnchor.restore(in: mounted, page: restoredPage, locator: update.locator))
            }
            restored.schedulePendingAnchor()
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(applications, 0)
            XCTAssertNotNil(restored.pendingAnchor)
            restored.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
            restored.layoutSubtreeIfNeeded()
            restored.schedulePendingAnchor()
        } else {
            XCTAssertTrue(PDFViewportAnchor.restore(in: restored, page: restoredPage, locator: update.locator))
        }
        try await Task.sleep(for: .milliseconds(80))
        let after = restored.convert(point, from: restoredPage)
        let afterClip = try XCTUnwrap(restored.documentView?.enclosingScrollView?.contentView).bounds.origin
        XCTAssertEqual(after.x, before.x, accuracy: 2, "Compare real screen placement, not twice-clamped viewportX")
        XCTAssertEqual(after.y, before.y, accuracy: 2)
        XCTAssertEqual(afterClip.x, beforeClip.x, accuracy: 2)
        XCTAssertEqual(afterClip.y, beforeClip.y, accuracy: 2)
        XCTAssertEqual(restored.scaleFactor, 1.5, accuracy: 0.001)
        if deferredLayout {
            XCTAssertEqual(applications, 1)
            XCTAssertNil(restored.pendingAnchor)
            restored.layoutSubtreeIfNeeded()
            restored.schedulePendingAnchor()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(applications, 1)
            let final = restored.convert(point, from: restoredPage)
            XCTAssertEqual(final.x, before.x, accuracy: 2)
            XCTAssertEqual(final.y, before.y, accuracy: 2)
            let finalClip = try XCTUnwrap(restored.documentView?.enclosingScrollView?.contentView).bounds.origin
            XCTAssertEqual(finalClip.x, beforeClip.x, accuracy: 2)
            XCTAssertEqual(finalClip.y, beforeClip.y, accuracy: 2)
        }
    }

    func testNativeScrollObserverRecordsMovementWithinTheSamePage() async throws {
        let view = makeView()
        let page = try XCTUnwrap(view.document?.page(at: 0))
        var updates: [ReadingPositionUpdate] = []
        let observer = PDFReadingPositionObserver(base: { self.locator() }, targetID: { nil }, isApplyingAnchor: { false }, publish: { updates.append($0) })
        observer.observe(view)
        defer { observer.stop() }
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: 950)))
        try await Task.sleep(for: .milliseconds(350))
        let update = try XCTUnwrap(updates.last)
        XCTAssertEqual(update.locator.payload["pageIndex"], "0")
        XCTAssertLessThan(try XCTUnwrap(Double(update.locator.payload["viewportY"] ?? "")), 1_200)
        XCTAssertNotNil(update.locator.payload["rect"])
    }

    func testEveryPageRotationHasMonotonicProgressAndTwoCoordinateRecovery() async throws {
        for rotation in [0, 90, 180, 270] {
            let view = makeView(rotation: rotation)
            let page = try XCTUnwrap(view.document?.page(at: 0))
            let initial = try XCTUnwrap(PDFViewportAnchor.capture(from: view, base: locator()))
            let displayed = view.convert(page.bounds(for: view.displayBox), from: page)
            let point = view.convert(CGPoint(x: displayed.minX, y: displayed.maxY - 550), to: page)
            view.go(to: PDFDestination(page: page, at: point))
            try await Task.sleep(for: .milliseconds(80))
            let captured = try XCTUnwrap(PDFViewportAnchor.capture(from: view, base: locator()))
            XCTAssertGreaterThan(try XCTUnwrap(captured.progressFraction), try XCTUnwrap(initial.progressFraction), "rotation \(rotation)")
            let anchor = try XCTUnwrap(PDFViewportAnchor.point(in: captured.locator, pageBounds: page.bounds(for: view.displayBox)))
            let restored = makeView(rotation: rotation)
            restored.go(to: PDFDestination(page: try XCTUnwrap(restored.document?.page(at: 0)), at: anchor))
            try await Task.sleep(for: .milliseconds(80))
            let reread = try XCTUnwrap(PDFViewportAnchor.capture(from: restored, base: locator()))
            XCTAssertEqual(try XCTUnwrap(Double(reread.locator.payload["viewportX"] ?? "")), anchor.x, accuracy: 2, "rotation \(rotation)")
            XCTAssertEqual(try XCTUnwrap(Double(reread.locator.payload["viewportY"] ?? "")), anchor.y, accuracy: 2, "rotation \(rotation)")
        }
    }

    func testDestinationWaitsForNonzeroViewportAndAppliesOnlyOnce() async throws {
        let view = makeView()
        let page = try XCTUnwrap(view.document?.page(at: 1))
        view.frame = .zero
        var applications = 0
        view.pendingAnchor = { view in
            applications += 1
            view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: 900)))
        }
        view.schedulePendingAnchor()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(applications, 0)
        view.frame = CGRect(x: 0, y: 0, width: 420, height: 600)
        view.layoutSubtreeIfNeeded()
        view.schedulePendingAnchor()
        try await Task.sleep(for: .milliseconds(100))
        let update = try XCTUnwrap(PDFViewportAnchor.capture(from: view, base: locator()))
        XCTAssertEqual(applications, 1)
        XCTAssertEqual(update.locator.pdfPageIndex, 1)
        XCTAssertEqual(try XCTUnwrap(Double(update.locator.payload["viewportY"] ?? "")), 900, accuracy: 2)
        view.layoutSubtreeIfNeeded()
        view.schedulePendingAnchor()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(applications, 1)
    }

    private func locator(x: String = "0", y: String = "1600") -> Locator {
        Locator(sourceID: "source", snapshotID: "snapshot", adapterID: PDFAdapter.id,
                payload: ["pageIndex": "0", "positionKind": "viewport", "viewportX": x, "viewportY": y])
    }

    private func makeView(rotation: Int = 0) -> ReadingPDFView {
        let document = PDFDocument()
        let size = rotation == 90 || rotation == 270 ? NSSize(width: 1_600, height: 420) : NSSize(width: 420, height: 1_600)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        document.insert(PDFPage(image: image)!, at: 0)
        document.insert(PDFPage(image: image)!, at: 1)
        document.page(at: 0)?.rotation = rotation
        document.page(at: 1)?.rotation = rotation
        let view = ReadingPDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = false
        view.document = document
        view.scaleFactor = 1
        view.layoutDocumentView()
        return view
    }

    private func makeMixedWidthView(rotation: Int = 0, frame: NSRect = NSRect(x: 0, y: 0, width: 900, height: 650)) -> ReadingPDFView {
        let document = PDFDocument()
        for width in [400.0, 400.0, 1000.0] {
            let size = rotation == 90 || rotation == 270 ? NSSize(width: 1600, height: width) : NSSize(width: width, height: 1600)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                NSColor.black.setFill()
                NSRect(x: 40, y: 900, width: 80, height: 80).fill()
                return true
            }
            document.insert(PDFPage(image: image)!, at: document.pageCount)
            document.page(at: document.pageCount - 1)?.rotation = rotation
        }
        let view = ReadingPDFView(frame: frame)
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = false
        view.document = document
        view.scaleFactor = 1.5
        view.layoutDocumentView()
        return view
    }
}
