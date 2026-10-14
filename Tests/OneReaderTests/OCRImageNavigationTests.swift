#if os(macOS)
import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import OneReader

@MainActor
final class OCRImageNavigationTests: XCTestCase {
    func testNativeViewportDropsTextOffsetsAndDoesNotReuseOldReadingPoint() throws {
        for adapterID in [ImageAdapter.id, OCRAdapter.id] {
            let base = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: adapterID,
                payload: ["ocrRevisionID": "revision", "ocrSpanID": "span", "ocrSchema": "1", "derivedText": "ocr",
                    "startUTF16": "0", "endUTF16": "27", "pageTextStartUTF16": "0", "pageTextEndUTF16": "27",
                    "indexTextRange": "utf16", "rect": "0.75,0.15,0.1,0.08", "imageAnchorX": "0.75", "imageAnchorY": "0.23"],
                textQuote: TextQuote(prefix: nil, exact: "Old paragraph", suffix: nil), fingerprint: "old-digest")
            let native = ImageViewportAnchor.locator(base: base, scale: 1.5, x: 0.2, y: 0.25)
            for key in ["startUTF16", "endUTF16", "pageTextStartUTF16", "pageTextEndUTF16", "indexTextRange",
                        "ocrRevisionID", "ocrSpanID", "ocrSchema", "derivedText", "rect", "imageAnchorX", "imageAnchorY"] {
                XCTAssertNil(native.payload[key], "\(adapterID): \(key)")
            }
            XCTAssertEqual(native.sourceID, base.sourceID)
            XCTAssertEqual(native.snapshotID, base.snapshotID)
            XCTAssertEqual(native.adapterID, ImageAdapter.id)
            XCTAssertNil(native.textQuote)
            XCTAssertNil(native.fingerprint)
            XCTAssertEqual(native.payload["imageScale"], "1.5")
            XCTAssertEqual(native.payload["imageX"], "0.2")
            XCTAssertEqual(native.payload["imageY"], "0.25")
            let clamped = ImageViewportAnchor.locator(base: base, scale: 1.5, x: 0.2, y: 0.25,
                readingPoint: CGPoint(x: -0.1, y: 1.2))
            XCTAssertEqual(clamped.payload["imageAnchorX"], "0.0")
            XCTAssertEqual(clamped.payload["imageAnchorY"], "1.0")
            XCTAssertEqual(clamped.payload["imageX"], native.payload["imageX"])
            XCTAssertEqual(clamped.payload["imageY"], native.payload["imageY"])
            for point in [CGPoint(x: CGFloat.nan, y: 0.3), CGPoint(x: 0.2, y: CGFloat.infinity)] {
                let invalid = ImageViewportAnchor.locator(base: base, scale: 1.5, x: 0.2, y: 0.25, readingPoint: point)
                XCTAssertNil(invalid.payload["imageAnchorX"])
                XCTAssertNil(invalid.payload["imageAnchorY"])
            }
        }
    }

    func testTranslatedFragmentThenNativeScrollCapturesCurrentOriginalImageGeometry() async throws {
        for adapterID in [ImageAdapter.id, OCRAdapter.id] {
            let log = PositionLog()
            let fixture = try await makeImage(log: log)
            defer { fixture.close() }
            let (scroll, canvas) = try nativeImage(in: fixture.host)
            scroll.magnification = 1.5
            canvas.scroll(CGPoint(x: 0, y: 600))
            let revision = makeRevision(rect: CGRect(x: 0.75, y: 0.15, width: 0.1, height: 0.08))
            let original = revision.locator(page: revision.pages[0], span: revision.pages[0].spans[0])
            var payload = original.payload
            payload.merge(["startUTF16": "0", "endUTF16": "27", "pageTextStartUTF16": "0",
                "pageTextEndUTF16": "27", "indexTextRange": "utf16", "imageAnchorX": "0.75", "imageAnchorY": "0.23"]) { _, new in new }
            if adapterID == ImageAdapter.id {
                ["ocrRevisionID", "ocrSpanID", "ocrSchema", "derivedText"].forEach { payload[$0] = nil }
            }
            let fragment = Locator(sourceID: original.sourceID, snapshotID: original.snapshotID,
                adapterID: adapterID, payload: payload, structuralPath: original.structuralPath,
                textQuote: original.textQuote, fingerprint: original.fingerprint)
            let previousCaptureCount = log.values.count
            update(fixture, locator: fragment, revision: revision, selectable: false, log: log)
            let target = CGRect(x: 900, y: 135, width: 120, height: 72)
            try await waitUntil {
                canvas.visibleRect.insetBy(dx: -1, dy: -1).contains(target) && log.values.count > previousCaptureCount
            }
            let fragmentVisible = canvas.visibleRect
            // Move through the real native image scroll view after the source jump.
            canvas.scroll(CGPoint(x: 100, y: 400))
            scroll.reflectScrolledClipView(scroll.contentView)
            let visible = canvas.visibleRect
            XCTAssertGreaterThan(abs(visible.minY - fragmentVisible.minY), 100)
            var captured: ReadingPositionUpdate?
            let request = ReadingPositionCaptureRequest(targetID: fixture.targetID,
                sourceID: fragment.sourceID, snapshotID: fragment.snapshotID) { captured = $0 }
            NotificationCenter.default.post(name: ReadingPositionCaptureSignal.requested, object: request)
            XCTAssertTrue(request.isClaimed)
            let position = try XCTUnwrap(captured)
            for key in ["startUTF16", "endUTF16", "pageTextStartUTF16", "pageTextEndUTF16",
                        "indexTextRange", "ocrRevisionID", "ocrSpanID", "ocrSchema", "derivedText", "rect"] {
                XCTAssertNil(position.locator.payload[key], "\(adapterID): \(key)")
            }
            XCTAssertEqual(position.locator.sourceID, fragment.sourceID)
            XCTAssertEqual(position.locator.snapshotID, fragment.snapshotID)
            XCTAssertEqual(position.locator.adapterID, ImageAdapter.id)
            XCTAssertNil(position.locator.textQuote)
            XCTAssertNil(position.locator.fingerprint)
            XCTAssertEqual(try XCTUnwrap(Double(position.locator.payload["imageScale"] ?? "")), 1.5, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(Double(position.locator.payload["imageX"] ?? "")),
                Double(visible.minX / canvas.bounds.width), accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(Double(position.locator.payload["imageY"] ?? "")),
                Double(visible.minY / canvas.bounds.height), accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(Double(position.locator.payload["imageAnchorX"] ?? "")),
                Double(visible.minX / canvas.bounds.width), accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(Double(position.locator.payload["imageAnchorY"] ?? "")),
                Double(visible.maxY / canvas.bounds.height), accuracy: 0.000001)
        }
    }

    func testSameImageOCRTargetScrollsIntoViewWithoutReloadingOrResettingMagnification() async throws {
        let log = PositionLog()
        let fixture = try await makeImage(log: log)
        defer { fixture.close() }
        let (scroll, canvas) = try nativeImage(in: fixture.host)
        scroll.magnification = 1.5
        canvas.scroll(CGPoint(x: 0, y: 600))
        let target = CGRect(x: 900, y: 135, width: 120, height: 72)
        XCTAssertFalse(canvas.visibleRect.contains(target))
        let revision = makeRevision(rect: CGRect(x: 0.75, y: 0.15, width: 0.1, height: 0.08))
        let locator = revision.locator(page: revision.pages[0], span: revision.pages[0].spans[0])

        // Changing the fixture bytes detects a mistaken same-URL re-decode without using private properties.
        // Production snapshots remain immutable; this is only a decoder-lifetime probe.
        try writePNG(size: CGSize(width: 200, height: 100), at: fixture.url)
        update(fixture, locator: locator, revision: revision, selectable: false, log: log)
        try await waitUntil {
            guard let (_, current) = try? self.nativeImage(in: fixture.host) else { return false }
            return current.visibleRect.insetBy(dx: -1, dy: -1).contains(target)
        }
        let (navigated, navigatedCanvas) = try nativeImage(in: fixture.host)
        XCTAssertTrue(navigatedCanvas === canvas)
        XCTAssertEqual(navigatedCanvas.bounds.size, CGSize(width: 1200, height: 900))
        XCTAssertEqual(navigated.magnification, 1.5, accuracy: 0.001)
        let passive = try XCTUnwrap(descendants(navigatedCanvas, as: NSButton.self).first)
        XCTAssertFalse(passive.isEnabled)
        XCTAssertNil(passive.hitTest(CGPoint(x: passive.frame.midX, y: passive.frame.midY)),
            "Disabled OCR highlights must not claim native image gestures")

        canvas.scroll(CGPoint(x: 100, y: 400))
        let userVisible = canvas.visibleRect
        update(fixture, locator: locator, revision: revision, selectable: true, log: log)
        try await waitUntil {
            guard let (_, current) = try? self.nativeImage(in: fixture.host) else { return false }
            return self.descendants(current, as: NSButton.self).first?.isEnabled == true
        }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(canvas.visibleRect.minX, userVisible.minX, accuracy: 0.5)
        XCTAssertEqual(canvas.visibleRect.minY, userVisible.minY, accuracy: 0.5)
        XCTAssertEqual(scroll.magnification, 1.5, accuracy: 0.001)
    }

    func testSameImageExplicitViewportAppliesOnlyOnceAndNewestAnchorWins() async throws {
        let log = PositionLog()
        let fixture = try await makeImage(log: log)
        defer { fixture.close() }
        let (_, originalCanvas) = try nativeImage(in: fixture.host)
        let first = ImageViewportAnchor.locator(base: fixture.document.locator, scale: 1.5, x: 0.1, y: 0.1)
        let latest = ImageViewportAnchor.locator(base: fixture.document.locator, scale: 1.5, x: 0.2, y: 0.25)
        update(fixture, locator: first, revision: nil, selectable: false, log: log)
        update(fixture, locator: latest, revision: nil, selectable: false, log: log)
        try await waitUntil {
            guard let (scroll, canvas) = try? self.nativeImage(in: fixture.host) else { return false }
            return abs(scroll.magnification - 1.5) < 0.001
                && abs(canvas.visibleRect.minX - 240) < 1 && abs(canvas.visibleRect.minY - 225) < 1
        }
        let (scroll, canvas) = try nativeImage(in: fixture.host)
        XCTAssertTrue(canvas === originalCanvas)
        scroll.magnification = 1.9
        canvas.scroll(CGPoint(x: 300, y: 400))
        let userVisible = canvas.visibleRect
        update(fixture, locator: latest, revision: nil, selectable: true, log: log)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(scroll.magnification, 1.9, accuracy: 0.001)
        XCTAssertEqual(canvas.visibleRect.minX, userVisible.minX, accuracy: 0.5)
        XCTAssertEqual(canvas.visibleRect.minY, userVisible.minY, accuracy: 0.5)
    }

    private func update(_ fixture: Fixture, locator: Locator, revision: OCRRevision?,
                        selectable: Bool, log: PositionLog) {
        let document = PresentationDocument(id: fixture.document.id, surface: .nativeImage, locator: locator,
            title: fixture.document.title, mediaType: "image/png", content: nil, contentURL: fixture.url,
            baseURL: nil, limitations: [])
        fixture.host.rootView = AnyView(OCRImagePresentation(document: document, revision: revision,
            selectable: selectable, onSelection: { _ in }, onPosition: { log.values.append($0) },
            captureTargetID: fixture.targetID))
        fixture.host.needsLayout = true; fixture.host.layoutSubtreeIfNeeded()
    }

    private func nativeImage(in host: NSView) throws -> (NSScrollView, NSView) {
        for scroll in descendants(host, as: NSScrollView.self) {
            if let canvas = scroll.documentView, canvas.bounds.width > 0, canvas.bounds.height > 0 {
                return (scroll, canvas)
            }
        }
        throw NSError(domain: "OCRImageNavigationTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Native image scroll view is not mounted"])
    }

    private func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, as: type) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "OCRImageNavigationTests", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Image navigation did not finish"])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeRevision(rect: CGRect) -> OCRRevision {
        let page = OCRPage(pageIndex: 0, inputDigest: "generated-image",
            geometry: OCRGeometry(bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                pixelWidth: 1200, pixelHeight: 900, transform: CGAffineTransform(scaleX: 1200, y: 900)),
            spans: [OCRSpan(id: "span", text: "Generated OCR target", confidence: 0.9,
                bounds: OCRRectangle(rect), order: 0)], usesNativeText: false)
        return OCRRevision(id: "revision", sourceID: "source", snapshotID: "snapshot", jobID: "job",
            engineVersion: OCRSettings.engineVersion, settings: OCRSettings(), pages: [page], createdAt: .now)
    }

    @MainActor
    private final class PositionLog { var values: [ReadingPositionUpdate] = [] }

    @MainActor
    private struct Fixture {
        let root: URL
        let url: URL
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let document: PresentationDocument
        let targetID: UUID
        func close() {
            window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeImage(log: PositionLog) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OneReader-MacImageNavigation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("image.png")
        try writePNG(size: CGSize(width: 1200, height: 900), at: url)
        let locator = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: ImageAdapter.id)
        let document = PresentationDocument(id: "image", surface: .nativeImage, locator: locator,
            title: "Generated image", mediaType: "image/png", content: nil, contentURL: url,
            baseURL: nil, limitations: [])
        let targetID = UUID()
        let host = NSHostingView(rootView: AnyView(OCRImagePresentation(document: document, revision: nil,
            selectable: false, onSelection: { _ in }, onPosition: { log.values.append($0) }, captureTargetID: targetID)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        host.needsLayout = true; host.layoutSubtreeIfNeeded()
        do {
            try await waitUntil { (try? self.nativeImage(in: host)) != nil && !log.values.isEmpty }
            return Fixture(root: root, url: url, host: host, window: window, document: document, targetID: targetID)
        } catch {
            window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func writePNG(size: CGSize, at url: URL) throws {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(origin: .zero, size: size))
        let image = try XCTUnwrap(bitmap.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
#endif
