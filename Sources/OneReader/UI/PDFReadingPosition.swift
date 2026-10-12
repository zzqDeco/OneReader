import Foundation
import PDFKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PDFViewportAnchor {
    static let payloadKeys = ["positionKind", "viewportX", "viewportY", "viewportScreenX", "viewportScreenY"]

    static func point(in locator: Locator, pageBounds: CGRect) -> CGPoint? {
        guard valid(pageBounds), locator.payload["positionKind"] == "viewport",
              locator.textQuote == nil,
              let x = Double(locator.payload["viewportX"] ?? ""),
              let y = Double(locator.payload["viewportY"] ?? ""),
              x.isFinite, y.isFinite,
              x >= pageBounds.minX, x <= pageBounds.maxX,
              y >= pageBounds.minY, y <= pageBounds.maxY else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Normalized screen placement of the bounded page anchor, measured from
    /// the viewport's left/top edges. Side/page-gap whitespace is not page X/Y.
    static func screenPosition(in locator: Locator) -> CGPoint? {
        guard locator.payload["positionKind"] == "viewport", locator.textQuote == nil,
              let x = Double(locator.payload["viewportScreenX"] ?? ""),
              let y = Double(locator.payload["viewportScreenY"] ?? ""),
              x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

#if os(macOS)
    @MainActor
    @discardableResult
    static func restore(in view: PDFView, page: PDFPage, locator: Locator) -> Bool {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let point = point(in: locator, pageBounds: page.bounds(for: view.displayBox)) else { return false }
        let placement = screenPosition(in: locator)
        let scrollView = view.documentView?.enclosingScrollView
        guard placement == nil || scrollView != nil else { return false }
        view.go(to: PDFDestination(page: page, at: point))
        guard let placement, let scroll = scrollView else { return true }
        let clip = scroll.contentView
        let anchor = clip.convert(view.convert(point, from: page), from: view)
        let top = view.isFlipped ? view.bounds.minY : view.bounds.maxY
        let screen = CGPoint(
            x: view.bounds.minX + placement.x * view.bounds.width,
            y: top + (view.isFlipped ? 1 : -1) * placement.y * view.bounds.height
        )
        let target = clip.convert(screen, from: view)
        let proposed = clip.bounds.offsetBy(dx: anchor.x - target.x, dy: anchor.y - target.y)
        guard [proposed.minX, proposed.minY, proposed.width, proposed.height].allSatisfy(\.isFinite) else { return true }
        // Clip coordinates can have a different scale/orientation from PDFView;
        // never add a raw page or screen delta directly to its bounds origin.
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(clip)
        return true
    }
#endif

    private static func valid(_ bounds: CGRect) -> Bool {
        !bounds.isNull && !bounds.isInfinite && !bounds.isEmpty
            && [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite)
    }

    @MainActor
    static func capture(from view: PDFView, base: Locator) -> ReadingPositionUpdate? {
        guard let document = view.document, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
#if os(macOS)
        let top = view.isFlipped ? view.bounds.minY : view.bounds.maxY
        let insideTop = top + (view.isFlipped ? 1 : -1)
#else
        let top = view.bounds.minY
        let insideTop = top + 1
#endif
        guard let page = view.page(for: CGPoint(x: view.bounds.midX, y: insideTop), nearest: true) else { return nil }
        let index = document.index(for: page)
        guard index >= 0, index < document.pageCount else { return nil }
        let bounds = page.bounds(for: view.displayBox)
        guard valid(bounds) else { return nil }
        let raw = view.convert(CGPoint(x: view.bounds.minX, y: top), to: page)
        guard raw.x.isFinite, raw.y.isFinite else { return nil }
        let point = CGPoint(x: min(max(raw.x, bounds.minX), bounds.maxX), y: min(max(raw.y, bounds.minY), bounds.maxY))
        let visible = view.convert(view.bounds, to: page).intersection(bounds)
        guard !visible.isNull, !visible.isEmpty else { return nil }
        var payload = base.payload
        payload["pageIndex"] = String(index)
        payload["positionKind"] = "viewport"
        payload["viewportX"] = String(Double(point.x))
        payload["viewportY"] = String(Double(point.y))
        payload["viewportScreenX"] = nil
        payload["viewportScreenY"] = nil
#if os(macOS)
        let screen = view.convert(point, from: page)
        let screenX = (screen.x - view.bounds.minX) / view.bounds.width
        let screenY = (view.isFlipped ? screen.y - top : top - screen.y) / view.bounds.height
        if screenX.isFinite, screenY.isFinite,
           (-0.001...1.001).contains(screenX), (-0.001...1.001).contains(screenY) {
            payload["viewportScreenX"] = String(Double(min(max(screenX, 0), 1)))
            payload["viewportScreenY"] = String(Double(min(max(screenY, 0), 1)))
        }
#endif
        payload["rect"] = [visible.minX, visible.minY, visible.width, visible.height]
            .map { String(Double($0)) }.joined(separator: ",")
        let locator = Locator(
            sourceID: base.sourceID, snapshotID: base.snapshotID, adapterID: base.adapterID,
            payload: payload, structuralPath: "page/\(index)", textQuote: nil, fingerprint: nil
        )
        // Measure progress on the displayed vertical axis, not page-space y:
        // page rotations can swap or reverse the PDF coordinate axes.
        let displayedPage = view.convert(bounds, from: page)
        guard valid(displayedPage) else { return nil }
#if os(macOS)
        let distance = view.isFlipped ? top - displayedPage.minY : displayedPage.maxY - top
#else
        let distance = top - displayedPage.minY
#endif
        let withinPage = min(max(distance / displayedPage.height, 0), 1)
        let fraction = (Double(index) + Double(withinPage)) / Double(document.pageCount)
        return ReadingPositionUpdate(
            locator: locator, progressFraction: fraction, granularity: .page,
            displayLabel: ReadingPositionUpdate.label(for: locator, detail: "第 \(index + 1) / \(document.pageCount) 页")
        )
    }
}

/// A representable is initially updated with zero bounds. PDF destinations
/// applied at that point are discarded by PDFKit's first document layout.
@MainActor
class ReadingPDFView: PDFView {
    var pendingAnchor: ((PDFView) -> Void)?
#if os(iOS)
    var onViewportLayout: ((PDFView) -> Void)?
#endif
    private var anchorScheduled = false

#if os(macOS)
    override func layout() {
        super.layout()
        schedulePendingAnchor()
    }
#else
    override func layoutSubviews() {
        super.layoutSubviews()
        onViewportLayout?(self)
        schedulePendingAnchor()
    }
#endif

    func schedulePendingAnchor() {
        guard pendingAnchor != nil, !anchorScheduled,
              bounds.width > 0, bounds.height > 0 else { return }
        anchorScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            anchorScheduled = false
            guard bounds.width > 0, bounds.height > 0 else { return }
            layoutDocumentView()
#if os(macOS)
            // A nonzero representable can still be detached from PDFKit's
            // native clip. Preserve the anchor until a later mounted layout.
            guard documentView?.enclosingScrollView != nil else { return }
#endif
            guard let apply = pendingAnchor else { return }
            pendingAnchor = nil
            apply(self)
        }
    }
}

/// PDFKit owns scrolling. Observe its native viewport without replacing its
/// delegate or installing a competing gesture recognizer.
@MainActor
final class PDFReadingPositionObserver: NSObject {
    var base: () -> Locator?
    var targetID: () -> UUID?
    var isApplyingAnchor: () -> Bool
    var publish: (ReadingPositionUpdate) -> Void
    private weak var view: PDFView?
    private var pending: Task<Void, Never>?
    private var lastChange = Date.distantPast
#if os(iOS)
    private weak var scrollView: UIScrollView?
    private var offsetObservation: NSKeyValueObservation?
#else
    private weak var clipView: NSClipView?
#endif

    init(base: @escaping () -> Locator?, targetID: @escaping () -> UUID?, isApplyingAnchor: @escaping () -> Bool, publish: @escaping (ReadingPositionUpdate) -> Void) {
        self.base = base
        self.targetID = targetID
        self.isApplyingAnchor = isApplyingAnchor
        self.publish = publish
    }

    deinit {
        pending?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func observe(_ view: PDFView) {
        self.view = view
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(captureRequested(_:)), name: ReadingPositionCaptureSignal.requested, object: nil)
        refreshScrollObservation()
    }

    func refreshScrollObservation() {
        guard let view else { return }
#if os(iOS)
        func firstScroll(in child: UIView) -> UIScrollView? {
            if let scroll = child as? UIScrollView { return scroll }
            for descendant in child.subviews {
                if let scroll = firstScroll(in: descendant) { return scroll }
            }
            return nil
        }
        guard let scroll = firstScroll(in: view), scroll !== scrollView else { return }
        scrollView = scroll
        offsetObservation = scroll.observe(\.contentOffset) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.viewportChanged() }
        }
#else
        guard let clip = view.documentView?.enclosingScrollView?.contentView, clip !== clipView else { return }
        if let clipView { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView) }
        clipView = clip
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: clip)
#endif
    }

    func stop() {
        pending?.cancel()
        pending = nil
        NotificationCenter.default.removeObserver(self)
#if os(iOS)
        offsetObservation = nil
        scrollView = nil
#else
        clipView = nil
#endif
        view = nil
    }

    func captureImmediately() {
        pending?.cancel()
        pending = nil
        guard let update = currentUpdate() else { return }
        publish(update)
    }

    private func currentUpdate() -> ReadingPositionUpdate? {
        guard !isApplyingAnchor(), let view, let base = base() else { return nil }
        return PDFViewportAnchor.capture(from: view, base: base)
    }

    @objc private func captureRequested(_ notification: Notification) {
        guard let update = currentUpdate() else { return }
        if let request = notification.object as? ReadingPositionCaptureRequest {
            guard let targetID = targetID(), request.claim(targetID: targetID, locator: update.locator) else { return }
            pending?.cancel()
            pending = nil
            request.finish(with: update, targetID: targetID)
        } else {
            captureImmediately()
        }
    }

    @objc private func viewportChanged() {
        guard !isApplyingAnchor() else { return }
        lastChange = .now
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            do {
                while let self, !Task.isCancelled {
                    let remaining = 0.15 - Date.now.timeIntervalSince(lastChange)
                    if remaining > 0 {
                        try await Task.sleep(for: .milliseconds(max(1, Int(ceil(remaining * 1_000)))))
                        continue
                    }
                    pending = nil
                    if let update = currentUpdate() { publish(update) }
                    return
                }
            } catch { }
        }
    }
}
