#if os(iOS)
import PDFKit
import SwiftUI
import UIKit
import XCTest
@testable import OneReader

@MainActor
final class OCRPresentationTests: XCTestCase {
    func testPDFOverlayMapsOriginalCropCoordinatesForEveryPageRotation() throws {
        let crop = CGRect(x: 36, y: 54, width: 480, height: 640)
        let normalized = CGRect(x: 0.17, y: 0.23, width: 0.29, height: 0.11)
        let original = CGRect(x: crop.minX + normalized.minX * crop.width,
            y: crop.minY + normalized.minY * crop.height,
            width: normalized.width * crop.width, height: normalized.height * crop.height)

        for rotation in [0, 90, 180, 270] {
            let view = try makePDFView(rotation: rotation, crop: crop)
            let page = try XCTUnwrap(view.document?.page(at: 0))
            let revision = makeRevision(bounds: crop, rectangles: [original])
            let provider = OCRPDFOverlayProvider()
            provider.install(in: view, revision: revision, selectable: true,
                locator: revision.locator(page: revision.pages[0]), onSelection: { _ in })
            let overlay = try XCTUnwrap(provider.pdfView(view, overlayViewFor: page))
            // A nonzero overlay origin detects mixing page, PDFView and overlay coordinates.
            overlay.frame = view.bounds.insetBy(dx: 13, dy: 19)
            view.addSubview(overlay)
            defer { overlay.removeFromSuperview() }
            let button = try XCTUnwrap(descendants(of: overlay, as: UIButton.self).first)

            for scale in [CGFloat(0.6), CGFloat(0.85)] {
                view.scaleFactor = scale
                view.layoutDocumentView()
                overlay.setNeedsLayout()
                overlay.layoutIfNeeded()
                let displayedPage = view.convert(crop, from: page).standardized
                XCTAssertGreaterThan(displayedPage.width, 100)
                XCTAssertGreaterThan(displayedPage.height, 100)
                // Expected top-left UIKit coordinates are derived independently from PDF /Rotate.
                let expectedUnitRect = rotatedUIKitRect(normalized, clockwiseDegrees: rotation)
                let expected = CGRect(x: displayedPage.minX + expectedUnitRect.minX * displayedPage.width,
                    y: displayedPage.minY + expectedUnitRect.minY * displayedPage.height,
                    width: expectedUnitRect.width * displayedPage.width,
                    height: expectedUnitRect.height * displayedPage.height)
                let actual = overlay.convert(button.frame, to: view).standardized
                assertRect(actual, equals: expected, accuracy: 1,
                    message: "rotation=\(rotation), scale=\(scale)")
                XCTAssertTrue(displayedPage.insetBy(dx: -1, dy: -1).contains(actual),
                    "OCR span must remain inside the cropped page, not the media-box origin")
            }
        }
    }

    func testPDFOverlayDoesNotInterceptTouchesWithoutExplicitSelectionMode() throws {
        let crop = CGRect(x: 36, y: 54, width: 480, height: 640)
        let view = try makePDFView(rotation: 0, crop: crop)
        let page = try XCTUnwrap(view.document?.page(at: 0))
        let revision = makeRevision(bounds: crop,
            rectangles: [CGRect(x: 150, y: 290, width: 140, height: 50)])
        let result = revision.pages[0], span = result.spans[0]
        let provider = OCRPDFOverlayProvider()
        var selections: [ReaderSelection] = []
        let selected = revision.locator(page: result, span: span)

        provider.install(in: view, revision: revision, selectable: false, locator: selected) {
            if let value = $0 { selections.append(value) }
        }
        let passive = try XCTUnwrap(provider.pdfView(view, overlayViewFor: page))
        passive.frame = view.bounds
        view.addSubview(passive)
        passive.setNeedsLayout(); passive.layoutIfNeeded()
        let passiveButton = try XCTUnwrap(descendants(of: passive, as: UIButton.self).first)
        XCTAssertGreaterThan(passiveButton.bounds.width, 1)
        XCTAssertNil(passive.hitTest(passiveButton.center, with: nil),
            "A highlighted OCR result must not swallow ordinary PDF scrolling or selection")
        XCTAssertTrue(selections.isEmpty)
        passive.removeFromSuperview()

        provider.install(in: view, revision: revision, selectable: true, locator: selected) {
            if let value = $0 { selections.append(value) }
        }
        let active = try XCTUnwrap(provider.pdfView(view, overlayViewFor: page))
        active.frame = view.bounds
        view.addSubview(active)
        defer { active.removeFromSuperview() }
        active.setNeedsLayout(); active.layoutIfNeeded()
        let button = try XCTUnwrap(descendants(of: active, as: UIButton.self).first)
        let hit = active.hitTest(button.center, with: nil)
        XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true)
        XCTAssertNil(active.hitTest(CGPoint(x: 2, y: 2), with: nil),
            "Empty overlay area must leave PDFKit gestures available even in OCR selection mode")
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections.first?.text, span.text)
        XCTAssertEqual(selections.first?.locator, selected)
        XCTAssertEqual(selections.first?.locator.payload["rect"], span.bounds.locatorValue)
    }

    func testPDFOverlayLeavesNativeTextAndUnrecognizedPagesUntouched() throws {
        let crop = CGRect(x: 36, y: 54, width: 480, height: 640)
        let view = try makePDFView(rotation: 0, crop: crop, pageCount: 2)
        let first = try XCTUnwrap(view.document?.page(at: 0))
        let second = try XCTUnwrap(view.document?.page(at: 1))
        let revision = makeRevision(bounds: crop,
            rectangles: [CGRect(x: 100, y: 200, width: 120, height: 40)], usesNativeText: true)
        let provider = OCRPDFOverlayProvider()
        provider.install(in: view, revision: revision, selectable: true,
            locator: revision.locator(page: revision.pages[0]), onSelection: { _ in })
        XCTAssertNil(provider.pdfView(view, overlayViewFor: first))
        XCTAssertNil(provider.pdfView(view, overlayViewFor: second))
        provider.install(in: view, revision: nil, selectable: false,
            locator: Locator(sourceID: "fixture-source", snapshotID: "fixture-snapshot", adapterID: PDFAdapter.id),
            onSelection: { _ in })
        XCTAssertNil(view.pageOverlayViewProvider)
        XCTAssertEqual(view.document?.pageCount, 2)
        XCTAssertTrue(first.string?.contains("Original PDF fixture") == true)
    }

    func testImageOverlayConvertsBottomLeftBoundsAndRequiresSelectionMode() async throws {
        let revision = makeRevision(bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            rectangles: [CGRect(x: 0.2, y: 0.6, width: 0.3, height: 0.15)])
        let log = ImageLog()
        let fixture = try await makeHostedImage(size: CGSize(width: 1200, height: 900),
            revision: revision, selectable: true, log: log)
        defer { fixture.close() }
        let (scroll, canvas) = try nativeImage(in: fixture.host.view)
        let button = try XCTUnwrap(descendants(of: canvas, as: UIButton.self).first)
        assertRect(button.frame, equals: CGRect(x: 240, y: 225, width: 360, height: 135), accuracy: 0.5)
        XCTAssertGreaterThan(scroll.zoomScale, 0)
        let hit = canvas.hitTest(button.center, with: nil)
        XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(log.selections.first?.locator,
            revision.locator(page: revision.pages[0], span: revision.pages[0].spans[0]))

        let beforeScale = scroll.zoomScale
        fixture.host.rootView = AnyView(OCRImagePresentation(
            document: fixture.document, revision: revision, selectable: false,
            onSelection: { if let value = $0 { log.selections.append(value) } },
            onPosition: { log.positions.append($0) }, captureTargetID: fixture.targetID))
        fixture.host.view.setNeedsLayout(); fixture.host.view.layoutIfNeeded()
        try await waitUntil {
            guard let native = try? self.nativeImage(in: fixture.host.view),
                  let only = self.descendants(of: native.1, as: UIButton.self).first else { return false }
            return !only.isUserInteractionEnabled
        }
        let (passiveScroll, passiveCanvas) = try nativeImage(in: fixture.host.view)
        let passiveButton = try XCTUnwrap(descendants(of: passiveCanvas, as: UIButton.self).first)
        let passiveHit = passiveCanvas.hitTest(passiveButton.center, with: nil)
        XCTAssertFalse(passiveHit === passiveButton || passiveHit?.isDescendant(of: passiveButton) == true)
        XCTAssertEqual(passiveScroll.zoomScale, beforeScale, accuracy: 0.0001,
            "Changing OCR selection mode must preserve the native image viewport")
    }

    func testImageCaptureUsesNativeZoomAndRestoresOriginalSourcePosition() async throws {
        let revision = makeRevision(bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            rectangles: [CGRect(x: 0.1, y: 0.6, width: 0.25, height: 0.1)])
        let log = ImageLog()
        let fixture = try await makeHostedImage(size: CGSize(width: 1200, height: 900),
            revision: revision, selectable: false, log: log)
        defer { fixture.close() }
        let (scroll, _) = try nativeImage(in: fixture.host.view)
        scroll.setZoomScale(2, animated: false)
        // At 2x these offsets represent the same 25% / 20% point of the ORIGINAL image.
        scroll.setContentOffset(CGPoint(x: 600, y: 360), animated: false)
        scroll.layoutIfNeeded()
        let before = log.positions.count
        let wrongTarget = ReadingPositionCaptureRequest(targetID: UUID(),
            sourceID: fixture.document.locator.sourceID, snapshotID: fixture.document.locator.snapshotID) { _ in
            XCTFail("An unrelated reader window must not receive this capture")
        }
        NotificationCenter.default.post(name: ReadingPositionCaptureSignal.requested, object: wrongTarget)
        XCTAssertFalse(wrongTarget.isClaimed)
        XCTAssertEqual(log.positions.count, before)

        var captured: ReadingPositionUpdate?
        let request = ReadingPositionCaptureRequest(targetID: fixture.targetID,
            sourceID: fixture.document.locator.sourceID, snapshotID: fixture.document.locator.snapshotID) { captured = $0 }
        NotificationCenter.default.post(name: ReadingPositionCaptureSignal.requested, object: request)
        XCTAssertTrue(request.isClaimed)
        let position = try XCTUnwrap(captured)
        XCTAssertEqual(position.locator.sourceID, fixture.document.locator.sourceID)
        XCTAssertEqual(position.locator.snapshotID, fixture.document.locator.snapshotID)
        XCTAssertEqual(position.locator.adapterID, ImageAdapter.id)
        for key in ["ocrRevisionID", "ocrSpanID", "ocrSchema", "derivedText", "rect"] {
            XCTAssertNil(position.locator.payload[key])
        }
        XCTAssertNil(position.locator.textQuote)
        XCTAssertNil(position.locator.fingerprint)
        XCTAssertEqual(try XCTUnwrap(Double(position.locator.payload["imageScale"] ?? "")), 2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(Double(position.locator.payload["imageX"] ?? "")), 0.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(Double(position.locator.payload["imageY"] ?? "")), 0.20, accuracy: 0.001)

        let restoredLog = ImageLog()
        let restored = try await makeHostedImage(size: CGSize(width: 1200, height: 900),
            revision: revision, selectable: false, log: restoredLog, locator: position.locator)
        defer { restored.close() }
        let (restoredScroll, _) = try nativeImage(in: restored.host.view)
        XCTAssertEqual(restoredScroll.zoomScale, 2, accuracy: 0.001)
        XCTAssertEqual(restoredScroll.contentOffset.x, 600, accuracy: 1)
        XCTAssertEqual(restoredScroll.contentOffset.y, 360, accuracy: 1)
    }

    func testImageDecodeAndNativeZoomRespectLimitsAndCaptureObserverIsRemoved() async throws {
        let log = ImageLog()
        let fixture = try await makeHostedImage(size: CGSize(width: 5000, height: 250),
            revision: nil, selectable: false, log: log)
        defer { fixture.close() }
        let (scroll, canvas) = try nativeImage(in: fixture.host.view)
        let decoded = try XCTUnwrap(canvas.image?.cgImage)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 4096)
        XCTAssertGreaterThan(decoded.width, 4000, "Fixture must exercise real ImageIO downsampling")
        XCTAssertEqual(Double(decoded.width) / Double(decoded.height), 20, accuracy: 0.1)
        scroll.setZoomScale(20, animated: false)
        XCTAssertEqual(scroll.zoomScale, 6, accuracy: 0.001)
        scroll.setZoomScale(0.001, animated: false)
        XCTAssertEqual(scroll.zoomScale, 0.1, accuracy: 0.001)

        fixture.host.rootView = AnyView(EmptyView())
        fixture.host.view.setNeedsLayout(); fixture.host.view.layoutIfNeeded()
        try await waitUntil { self.descendants(of: fixture.host.view, as: UIImageView.self).allSatisfy { $0.image == nil } }
        let request = ReadingPositionCaptureRequest(targetID: fixture.targetID,
            sourceID: fixture.document.locator.sourceID, snapshotID: fixture.document.locator.snapshotID) { _ in
            XCTFail("A dismantled image reader must not claim lifecycle capture requests")
        }
        NotificationCenter.default.post(name: ReadingPositionCaptureSignal.requested, object: request)
        XCTAssertFalse(request.isClaimed)
    }

    func testSameImageOCRNavigationMovesToNewRegionWithoutReloadOrZoomReset() async throws {
        let revision = makeRevision(bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            rectangles: [CGRect(x: 0.05, y: 0.85, width: 0.08, height: 0.05),
                         CGRect(x: 0.78, y: 0.12, width: 0.08, height: 0.08)])
        let log = ImageLog()
        let fixture = try await makeHostedImage(size: CGSize(width: 1200, height: 900),
            revision: revision, selectable: false, log: log)
        defer { fixture.close() }
        let (scroll, canvas) = try nativeImage(in: fixture.host.view)
        let image = try XCTUnwrap(canvas.image)
        scroll.setZoomScale(1.8, animated: false)
        scroll.setContentOffset(.zero, animated: false)
        let target = CGRect(x: 936, y: 720, width: 96, height: 72)
        XCTAssertFalse(canvas.convert(scroll.bounds, from: scroll).contains(target))
        let locator = revision.locator(page: revision.pages[0], span: revision.pages[0].spans[1])

        updateHostedImage(fixture, locator: locator, revision: revision, selectable: false, log: log)
        try await waitUntil {
            guard let (current, imageView) = try? self.nativeImage(in: fixture.host.view) else { return false }
            return imageView.convert(current.bounds, from: current).insetBy(dx: -1, dy: -1).contains(target)
        }
        let (navigated, navigatedCanvas) = try nativeImage(in: fixture.host.view)
        XCTAssertTrue(navigatedCanvas.image === image, "Same-URL navigation must reuse the decoded image")
        XCTAssertEqual(navigated.zoomScale, 1.8, accuracy: 0.001)

        // Once the anchor was consumed, the reader can pan away without a mode change replaying it.
        navigated.setContentOffset(CGPoint(x: 60, y: 45), animated: false)
        let userOffset = navigated.contentOffset
        updateHostedImage(fixture, locator: locator, revision: revision, selectable: true, log: log)
        try await waitUntil {
            guard let (_, imageView) = try? self.nativeImage(in: fixture.host.view) else { return false }
            return self.descendants(of: imageView, as: UIButton.self).count == 2
        }
        try await Task.sleep(for: .milliseconds(60))
        let (afterMode, afterCanvas) = try nativeImage(in: fixture.host.view)
        XCTAssertTrue(afterCanvas.image === image)
        XCTAssertEqual(afterMode.contentOffset.x, userOffset.x, accuracy: 0.5)
        XCTAssertEqual(afterMode.contentOffset.y, userOffset.y, accuracy: 0.5)
        XCTAssertEqual(afterMode.zoomScale, 1.8, accuracy: 0.001)
    }

    func testSameImageExplicitViewportNavigatesOnceAndLatestQueuedAnchorWins() async throws {
        let log = ImageLog()
        let fixture = try await makeHostedImage(size: CGSize(width: 1200, height: 900),
            revision: nil, selectable: false, log: log)
        defer { fixture.close() }
        let (_, canvas) = try nativeImage(in: fixture.host.view)
        let image = try XCTUnwrap(canvas.image)
        let first = ImageViewportAnchor.locator(base: fixture.document.locator, scale: 2, x: 0.1, y: 0.1)
        let latest = ImageViewportAnchor.locator(base: fixture.document.locator, scale: 2, x: 0.25, y: 0.20)
        updateHostedImage(fixture, locator: first, revision: nil, selectable: false, log: log)
        updateHostedImage(fixture, locator: latest, revision: nil, selectable: false, log: log)
        try await waitUntil {
            guard let (current, _) = try? self.nativeImage(in: fixture.host.view) else { return false }
            return abs(current.zoomScale - 2) < 0.001
                && abs(current.contentOffset.x - 600) < 1 && abs(current.contentOffset.y - 360) < 1
        }
        try await Task.sleep(for: .milliseconds(60))
        let (scroll, currentCanvas) = try nativeImage(in: fixture.host.view)
        XCTAssertTrue(currentCanvas.image === image)
        XCTAssertEqual(scroll.contentOffset.x, 600, accuracy: 1)
        XCTAssertEqual(scroll.contentOffset.y, 360, accuracy: 1)
        scroll.setContentOffset(CGPoint(x: 700, y: 420), animated: false)
        updateHostedImage(fixture, locator: latest, revision: nil, selectable: true, log: log)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(scroll.contentOffset.x, 700, accuracy: 1)
        XCTAssertEqual(scroll.contentOffset.y, 420, accuracy: 1)
        XCTAssertEqual(scroll.zoomScale, 2, accuracy: 0.001)
    }

    private func updateHostedImage(_ fixture: HostedImage, locator: Locator, revision: OCRRevision?,
                                   selectable: Bool, log: ImageLog) {
        let previous = fixture.document
        let document = PresentationDocument(id: previous.id, surface: previous.surface, locator: locator,
            title: previous.title, mediaType: previous.mediaType, content: previous.content,
            contentURL: previous.contentURL, baseURL: previous.baseURL, limitations: previous.limitations)
        fixture.host.rootView = AnyView(OCRImagePresentation(document: document, revision: revision,
            selectable: selectable, onSelection: { if let value = $0 { log.selections.append(value) } },
            onPosition: { log.positions.append($0) }, captureTargetID: fixture.targetID))
        fixture.host.view.setNeedsLayout(); fixture.host.view.layoutIfNeeded()
    }

    private func makePDFView(rotation: Int, crop: CGRect, pageCount: Int = 1) throws -> PDFView {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            for index in 0..<pageCount {
                context.beginPage()
                ("Original PDF fixture \(index)" as NSString).draw(at: CGPoint(x: 80, y: 120),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        for index in 0..<pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            page.setBounds(crop, for: .cropBox)
            page.rotation = rotation
        }
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 900))
        view.displayBox = .cropBox; view.displayMode = .singlePage
        view.displaysPageBreaks = false; view.autoScales = false
        view.minScaleFactor = 0.1; view.maxScaleFactor = 6
        view.document = document; view.scaleFactor = 0.7
        view.layoutIfNeeded(); view.layoutDocumentView()
        return view
    }

    private func makeRevision(bounds: CGRect, rectangles: [CGRect], usesNativeText: Bool = false) -> OCRRevision {
        let transform = CGAffineTransform(a: 2 / bounds.width, b: 0, c: 0, d: 2 / bounds.height,
            tx: -bounds.minX * 2 / bounds.width, ty: -bounds.minY * 2 / bounds.height)
        let page = OCRPage(pageIndex: 0, inputDigest: "generated-fixture",
            geometry: OCRGeometry(bounds: bounds, pixelWidth: 2, pixelHeight: 2, transform: transform),
            spans: rectangles.enumerated().map { index, rectangle in
                OCRSpan(id: "fixture-span-\(index)", text: "识别段落 \(index) / generated span",
                    confidence: 0.95, bounds: OCRRectangle(rectangle), order: index)
            }, usesNativeText: usesNativeText)
        return OCRRevision(id: "fixture-revision", sourceID: "fixture-source", snapshotID: "fixture-snapshot",
            jobID: "fixture-job", engineVersion: OCRSettings.engineVersion,
            settings: OCRSettings(), pages: [page], createdAt: .now)
    }

    private func rotatedUIKitRect(_ rect: CGRect, clockwiseDegrees: Int) -> CGRect {
        switch clockwiseDegrees {
        case 0: CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        case 90: CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
        case 180: CGRect(x: 1 - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
        case 270: CGRect(x: 1 - rect.maxY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        default: .null
        }
    }

    private func assertRect(_ actual: CGRect, equals expected: CGRect, accuracy: CGFloat,
                            message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, message, file: file, line: line)
    }

    private func descendants<T: UIView>(of view: UIView, as type: T.Type) -> [T] {
        let current = (view as? T).map { [$0] } ?? []
        return current + view.subviews.flatMap { descendants(of: $0, as: type) }
    }

    private func nativeImage(in view: UIView) throws -> (UIScrollView, UIImageView) {
        for scroll in descendants(of: view, as: UIScrollView.self) {
            if let canvas = scroll.delegate?.viewForZooming?(in: scroll) as? UIImageView,
               canvas.image != nil { return (scroll, canvas) }
        }
        throw NSError(domain: "OCRPresentationTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Native image scroll view was not mounted"])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "OCRPresentationTests", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Native image presentation did not finish mounting"])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private final class ImageLog {
        var positions: [ReadingPositionUpdate] = []
        var selections: [ReaderSelection] = []
    }

    @MainActor
    private struct HostedImage {
        let root: URL
        let host: UIHostingController<AnyView>
        let window: UIWindow
        let document: PresentationDocument
        let targetID: UUID
        func close() {
            window.isHidden = true
            window.rootViewController = nil
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeHostedImage(size: CGSize, revision: OCRRevision?, selectable: Bool,
                                 log: ImageLog, locator: Locator? = nil) async throws -> HostedImage {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OneReader-OCRPresentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var mountedWindow: UIWindow?
        do {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: size.width * 0.2, y: size.height * 0.25,
                    width: size.width * 0.3, height: size.height * 0.15))
            }
            let url = root.appendingPathComponent("generated.png")
            try XCTUnwrap(image.pngData()).write(to: url)
            let base = locator ?? revision.map { $0.locator(page: $0.pages[0], span: $0.pages[0].spans.first) }
                ?? Locator(sourceID: "fixture-source", snapshotID: "fixture-snapshot", adapterID: ImageAdapter.id)
            let document = PresentationDocument(id: "fixture-image", surface: .nativeImage,
                locator: base, title: "Generated test image", mediaType: "image/png", content: nil,
                contentURL: url, baseURL: nil, limitations: [])
            let targetID = UUID()
            let host = UIHostingController(rootView: AnyView(OCRImagePresentation(document: document,
                revision: revision, selectable: selectable,
                onSelection: { if let value = $0 { log.selections.append(value) } },
                onPosition: { log.positions.append($0) }, captureTargetID: targetID)))
            let frame = CGRect(x: 0, y: 0, width: 390, height: 700)
            let window: UIWindow
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window = UIWindow(windowScene: scene); window.frame = frame
            } else { window = UIWindow(frame: frame) }
            mountedWindow = window
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await waitUntil {
                (try? self.nativeImage(in: host.view)) != nil && !log.positions.isEmpty
            }
            return HostedImage(root: root, host: host, window: window, document: document, targetID: targetID)
        } catch {
            mountedWindow?.isHidden = true
            mountedWindow?.rootViewController = nil
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
#endif
