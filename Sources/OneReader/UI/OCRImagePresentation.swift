import ImageIO
import SwiftUI

/// A bounded EXIF-normalized image. Original bytes remain in the managed snapshot.
private func loadReaderImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 4096
    ] as CFDictionary)
}

struct OCRImagePresentation: View {
    let document: PresentationDocument
    let revision: OCRRevision?
    let selectable: Bool
    let onSelection: (ReaderSelection?) -> Void
    let onPosition: (ReadingPositionUpdate) -> Void
    let captureTargetID: UUID

    var body: some View {
        Group {
            if let url = document.contentURL {
                NativeZoomImage(url: url, revision: revision, selectable: selectable,
                    locator: document.locator, onSelection: onSelection, onPosition: onPosition, captureTargetID: captureTargetID)
            } else { ContentUnavailableView("图像不可用", systemImage: "photo") }
        }
        .accessibilityIdentifier("reader-image-view")
    }
}

enum ImageViewportAnchor {
    static func locator(base: Locator, scale: Double, x: Double, y: Double,
                        readingPoint: CGPoint? = nil) -> Locator {
        var payload = base.payload
        // Native progress is geometry, even when its base was a translated native fragment.
        ["ocrRevisionID", "ocrSpanID", "ocrSchema", "derivedText", "rect", "startUTF16", "endUTF16",
         "pageTextStartUTF16", "pageTextEndUTF16", "indexTextRange", "imageAnchorX", "imageAnchorY"]
            .forEach { payload[$0] = nil }
        payload["imageScale"] = String(min(6, max(0.1, scale.isFinite ? scale : 1)))
        payload["imageX"] = String(min(1, max(0, x.isFinite ? x : 0)))
        payload["imageY"] = String(min(1, max(0, y.isFinite ? y : 0)))
        // Only a new native capture supplies this original lower-left reading edge.
        // Restoration's existing imageX/Y conventions remain unchanged across platforms.
        if let readingPoint, readingPoint.x.isFinite, readingPoint.y.isFinite {
            payload["imageAnchorX"] = String(Double(min(1, max(0, readingPoint.x))))
            payload["imageAnchorY"] = String(Double(min(1, max(0, readingPoint.y))))
        }
        return Locator(sourceID: base.sourceID, snapshotID: base.snapshotID, adapterID: ImageAdapter.id,
            payload: payload, structuralPath: "image/0")
    }
    static func value(_ name: String, in locator: Locator, fallback: Double) -> Double {
        guard let value = Double(locator.payload[name] ?? ""), value.isFinite else { return fallback }
        return name == "imageScale" ? min(6, max(0.1, value)) : min(1, max(0, value))
    }

    static func navigationSignature(_ locator: Locator) -> String {
        let keys = ["imageScale", "imageX", "imageY", "ocrRevisionID", "ocrSpanID", "rect"]
        return ([locator.sourceID, locator.snapshotID, locator.adapterID]
            + keys.map { "\($0)=\(locator.payload[$0] ?? "")" }).joined(separator: "|")
    }

    static func normalizedRectangle(_ locator: Locator) -> CGRect? {
        PDFPageRectAnchor.parse(locator.payload["rect"])?.clipped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

/// Image identity controls decoding; explicit anchor identity independently controls navigation.
/// A changed selection-mode flag never schedules another scroll. Superseded queued anchors cannot
/// apply after a newer locator or after the native view has been dismantled.
@MainActor
private final class ImageAnchorApplication {
    private(set) var appliedSignature: String?
    private var pendingSignature: String?
    private var task: Task<Void, Never>?
    private(set) var isApplying = false

    func reset(suppressCapture: Bool = false) {
        task?.cancel(); task = nil
        pendingSignature = nil; appliedSignature = nil; isApplying = suppressCapture
    }

    func request(signature: String, ready: @escaping () -> Bool,
                 apply: @escaping () -> Void, completion: @escaping () -> Void) {
        guard signature != appliedSignature, signature != pendingSignature else { return }
        task?.cancel()
        pendingSignature = signature; isApplying = true
        task = Task { @MainActor [weak self] in
            await Task.yield()
            for _ in 0..<12 where !ready() {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            guard !Task.isCancelled, let self, pendingSignature == signature else { return }
            if ready() {
                apply()
                appliedSignature = signature
            }
            pendingSignature = nil; isApplying = false; task = nil
            completion()
        }
    }
}

#if os(macOS)
private struct NativeZoomImage: NSViewRepresentable {
    let url: URL
    let revision: OCRRevision?
    let selectable: Bool
    let locator: Locator
    let onSelection: (ReaderSelection?) -> Void
    let onPosition: (ReadingPositionUpdate) -> Void
    let captureTargetID: UUID

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true; scroll.minMagnification = 0.25; scroll.maxMagnification = 6
        scroll.drawsBackground = false
        context.coordinator.observe(scroll)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let existing = scroll.documentView as? OCRImageCanvas
        let canvas = existing ?? OCRImageCanvas()
        let changed = canvas.identity != url.absoluteString
        if changed {
            guard let image = loadReaderImage(url) else { return }
            context.coordinator.navigation.reset(suppressCapture: true)
            canvas.image = image; canvas.identity = url.absoluteString
            canvas.frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            scroll.documentView = canvas
        }
        canvas.configure(revision: revision, selectable: selectable, locator: locator, onSelection: onSelection)
        context.coordinator.navigate(scroll, canvas: canvas, imageChanged: changed, locator: locator)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.capture(); coordinator.stop()
    }

    @MainActor final class Coordinator: NSObject {
        var parent: NativeZoomImage
        weak var scroll: NSScrollView?
        let navigation = ImageAnchorApplication()
        var restoring: Bool { navigation.isApplying }
        private var pending: Task<Void, Never>?
        init(parent: NativeZoomImage) { self.parent = parent }
        func observe(_ scroll: NSScrollView) {
            self.scroll = scroll; scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(requested(_:)), name: ReadingPositionCaptureSignal.requested, object: nil)
        }
        func stop() { pending?.cancel(); navigation.reset(); NotificationCenter.default.removeObserver(self) }
        func navigate(_ scroll: NSScrollView, canvas: OCRImageCanvas, imageChanged: Bool, locator: Locator) {
            let initializeViewport = imageChanged || navigation.appliedSignature == nil
            navigation.request(signature: ImageViewportAnchor.navigationSignature(locator), ready: { [weak scroll, weak canvas] in
                guard let scroll, let canvas else { return false }
                return scroll.contentSize.width > 0 && scroll.contentSize.height > 0 && canvas.bounds.width > 0
            }, apply: { [weak scroll, weak canvas] in
                guard let scroll, let canvas else { return }
                if initializeViewport || locator.payload["imageScale"] != nil {
                    let fit = min(1, max(scroll.minMagnification, scroll.contentSize.width / canvas.bounds.width))
                    let scale = ImageViewportAnchor.value("imageScale", in: locator,
                        fallback: initializeViewport ? fit : scroll.magnification)
                    scroll.magnification = min(scroll.maxMagnification, max(scroll.minMagnification, scale))
                }
                if let rect = ImageViewportAnchor.normalizedRectangle(locator) {
                    canvas.scrollToVisible(CGRect(x: rect.minX * canvas.bounds.width, y: rect.minY * canvas.bounds.height,
                        width: rect.width * canvas.bounds.width, height: rect.height * canvas.bounds.height))
                } else if initializeViewport || locator.payload["imageX"] != nil || locator.payload["imageY"] != nil {
                    let visible = canvas.visibleRect
                    let x = ImageViewportAnchor.value("imageX", in: locator, fallback: initializeViewport ? 0 : visible.minX / canvas.bounds.width) * canvas.bounds.width
                    let y = ImageViewportAnchor.value("imageY", in: locator, fallback: initializeViewport ? 1 : visible.minY / canvas.bounds.height) * canvas.bounds.height
                    canvas.scroll(CGPoint(x: min(max(0, x), max(0, canvas.bounds.width - visible.width)),
                        y: min(max(0, y), max(0, canvas.bounds.height - visible.height))))
                }
            }, completion: { [weak self] in self?.capture() })
        }
        private func update() -> ReadingPositionUpdate? {
            guard !restoring, let scroll, let canvas = scroll.documentView, canvas.bounds.width > 0, canvas.bounds.height > 0 else { return nil }
            let visible = canvas.visibleRect
            return ReadingPositionUpdate(locator: ImageViewportAnchor.locator(base: parent.locator, scale: scroll.magnification,
                x: visible.minX / canvas.bounds.width, y: visible.minY / canvas.bounds.height,
                readingPoint: CGPoint(x: visible.minX / canvas.bounds.width, y: visible.maxY / canvas.bounds.height)),
                granularity: .document, displayLabel: "原始图像")
        }
        func capture() { if let update = update() { parent.onPosition(update) } }
        @objc private func changed() {
            pending?.cancel()
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }; self?.capture()
            }
        }
        @objc private func requested(_ notification: Notification) {
            guard let update = update() else { return }
            if let request = notification.object as? ReadingPositionCaptureRequest {
                if request.claim(targetID: parent.captureTargetID, locator: update.locator) { request.finish(with: update, targetID: parent.captureTargetID) }
            } else { parent.onPosition(update) }
        }
    }
}

private final class OCRImageCanvas: NSView {
    var image: CGImage?
    var identity = ""
    private var buttons: [NSButton] = []
    private var actions: [() -> Void] = []
    private var overlaySignature = ""
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let image { NSGraphicsContext.current?.cgContext.draw(image, in: bounds) }
    }
    func configure(revision: OCRRevision?, selectable: Bool, locator: Locator,
                   onSelection: @escaping (ReaderSelection?) -> Void) {
        let signature = "\(revision?.id ?? ""):\(selectable):\(locator.stableID)"
        guard signature != overlaySignature else { return }
        overlaySignature = signature
        buttons.forEach { $0.removeFromSuperview() }; buttons = []; actions = []
        guard let revision, let page = revision.pages.first else { return }
        for span in page.spans where selectable || span.id == locator.payload["ocrSpanID"] {
            let button = OCRImageSpanButton(title: "", target: self, action: #selector(selectSpan(_:)))
            button.tag = buttons.count; button.isBordered = false; button.isEnabled = selectable
            button.frame = CGRect(x: span.bounds.x * bounds.width, y: span.bounds.y * bounds.height,
                width: span.bounds.width * bounds.width, height: span.bounds.height * bounds.height)
            button.wantsLayer = true; button.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
            button.setAccessibilityLabel("识别文字：\(span.text)")
            actions.append { onSelection(ReaderSelection(text: span.text, locator: revision.locator(page: page, span: span))) }
            buttons.append(button); addSubview(button)
        }
        if locator.payload["ocrSpanID"] == nil, let rect = PDFPageRectAnchor.parse(locator.payload["rect"])?.rect {
            let highlight = OCRImageSpanButton(title: "", target: nil, action: nil)
            highlight.isEnabled = false; highlight.isBordered = false; highlight.wantsLayer = true
            highlight.frame = CGRect(x: rect.minX * bounds.width, y: rect.minY * bounds.height,
                width: rect.width * bounds.width, height: rect.height * bounds.height)
            highlight.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.28).cgColor
            buttons.append(highlight); addSubview(highlight)
        }
        needsDisplay = true
    }
    @objc private func selectSpan(_ sender: NSButton) { actions[sender.tag]() }
}

private final class OCRImageSpanButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled ? super.hitTest(point) : nil
    }
}
#else
private struct NativeZoomImage: UIViewRepresentable {
    let url: URL
    let revision: OCRRevision?
    let selectable: Bool
    let locator: Locator
    let onSelection: (ReaderSelection?) -> Void
    let onPosition: (ReadingPositionUpdate) -> Void
    let captureTargetID: UUID
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView(); scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 0.1; scroll.maximumZoomScale = 6
        scroll.alwaysBounceVertical = true; scroll.alwaysBounceHorizontal = true
        scroll.addSubview(context.coordinator.canvas)
        context.coordinator.observe(scroll)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        let canvas = context.coordinator.canvas
        let changed = context.coordinator.identity != url.absoluteString
        if changed {
            guard let image = loadReaderImage(url) else { return }
            context.coordinator.navigation.reset(suppressCapture: true)
            context.coordinator.identity = url.absoluteString
            scroll.zoomScale = 1
            canvas.frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            canvas.image = UIImage(cgImage: image)
            scroll.contentSize = canvas.bounds.size
        }
        context.coordinator.navigate(scroll, imageChanged: changed, locator: locator)
        let signature = "\(revision?.id ?? ""):\(selectable):\(locator.stableID)"
        guard context.coordinator.overlaySignature != signature else { return }
        context.coordinator.overlaySignature = signature
        canvas.subviews.forEach { $0.removeFromSuperview() }
        if let revision, let page = revision.pages.first {
            for span in page.spans where selectable || span.id == locator.payload["ocrSpanID"] {
                let button = UIButton(type: .custom)
                button.frame = CGRect(x: span.bounds.x * canvas.bounds.width,
                    y: (1 - span.bounds.y - span.bounds.height) * canvas.bounds.height,
                    width: span.bounds.width * canvas.bounds.width, height: span.bounds.height * canvas.bounds.height)
                button.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.18)
                button.accessibilityLabel = "识别文字：\(span.text)"; button.isUserInteractionEnabled = selectable
                button.addAction(UIAction { _ in onSelection(ReaderSelection(text: span.text,
                    locator: revision.locator(page: page, span: span))) }, for: .touchUpInside)
                canvas.addSubview(button)
            }
            if locator.payload["ocrSpanID"] == nil, let rect = PDFPageRectAnchor.parse(locator.payload["rect"])?.rect {
                let highlight = UIView(frame: CGRect(x: rect.minX * canvas.bounds.width,
                    y: (1 - rect.maxY) * canvas.bounds.height, width: rect.width * canvas.bounds.width,
                    height: rect.height * canvas.bounds.height))
                highlight.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.28)
                highlight.isUserInteractionEnabled = false; canvas.addSubview(highlight)
            }
        }
    }
    static func dismantleUIView(_ scroll: UIScrollView, coordinator: Coordinator) {
        coordinator.capture(); coordinator.stop()
    }
    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: NativeZoomImage
        weak var scroll: UIScrollView?
        let navigation = ImageAnchorApplication()
        var restoring: Bool { navigation.isApplying }
        var overlaySignature = ""
        let canvas: UIImageView = { let view = UIImageView(); view.isUserInteractionEnabled = true; return view }()
        var identity = ""
        init(parent: NativeZoomImage) { self.parent = parent }
        func observe(_ scroll: UIScrollView) {
            self.scroll = scroll
            NotificationCenter.default.addObserver(self, selector: #selector(requested(_:)), name: ReadingPositionCaptureSignal.requested, object: nil)
        }
        func stop() { navigation.reset(); NotificationCenter.default.removeObserver(self) }
        func navigate(_ scroll: UIScrollView, imageChanged: Bool, locator: Locator) {
            let initializeViewport = imageChanged || navigation.appliedSignature == nil
            navigation.request(signature: ImageViewportAnchor.navigationSignature(locator), ready: { [weak scroll, weak self] in
                guard let scroll, let self else { return false }
                return scroll.bounds.width > 0 && scroll.bounds.height > 0 && canvas.bounds.width > 0
            }, apply: { [weak scroll, weak self] in
                guard let scroll, let self else { return }
                if initializeViewport || locator.payload["imageScale"] != nil {
                    let fit = min(1, max(scroll.minimumZoomScale, scroll.bounds.width / canvas.bounds.width))
                    let scale = ImageViewportAnchor.value("imageScale", in: locator,
                        fallback: initializeViewport ? fit : scroll.zoomScale)
                    scroll.setZoomScale(scale, animated: false)
                }
                if let rect = ImageViewportAnchor.normalizedRectangle(locator) {
                    scroll.scrollRectToVisible(CGRect(x: canvas.frame.minX + rect.minX * canvas.frame.width,
                        y: canvas.frame.minY + (1 - rect.maxY) * canvas.frame.height,
                        width: rect.width * canvas.frame.width, height: rect.height * canvas.frame.height), animated: false)
                } else if initializeViewport || locator.payload["imageX"] != nil || locator.payload["imageY"] != nil {
                    let x = ImageViewportAnchor.value("imageX", in: locator,
                        fallback: initializeViewport ? 0 : scroll.contentOffset.x / canvas.frame.width) * canvas.frame.width
                    let y = ImageViewportAnchor.value("imageY", in: locator,
                        fallback: initializeViewport ? 0 : scroll.contentOffset.y / canvas.frame.height) * canvas.frame.height
                    let inset = scroll.adjustedContentInset
                    scroll.contentOffset = CGPoint(
                        x: min(max(-inset.left, x), max(-inset.left, scroll.contentSize.width - scroll.bounds.width + inset.right)),
                        y: min(max(-inset.top, y), max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom)))
                }
            }, completion: { [weak self] in self?.capture() })
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { capture() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { capture() } }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { capture() }
        private func update() -> ReadingPositionUpdate? {
            guard !restoring, let scroll, canvas.frame.width > 0, canvas.frame.height > 0 else { return nil }
            return ReadingPositionUpdate(locator: ImageViewportAnchor.locator(base: parent.locator, scale: scroll.zoomScale,
                x: scroll.contentOffset.x / canvas.frame.width, y: scroll.contentOffset.y / canvas.frame.height,
                readingPoint: CGPoint(x: scroll.contentOffset.x / canvas.frame.width,
                    y: 1 - scroll.contentOffset.y / canvas.frame.height)),
                granularity: .document, displayLabel: "原始图像")
        }
        func capture() { if let update = update() { parent.onPosition(update) } }
        @objc private func requested(_ notification: Notification) {
            guard let update = update() else { return }
            if let request = notification.object as? ReadingPositionCaptureRequest {
                if request.claim(targetID: parent.captureTargetID, locator: update.locator) { request.finish(with: update, targetID: parent.captureTargetID) }
            } else { parent.onPosition(update) }
        }
    }
}
#endif
