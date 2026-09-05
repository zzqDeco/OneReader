import Foundation
import PDFKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PDFViewportAnchor {
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

    private static func valid(_ bounds: CGRect) -> Bool {
        !bounds.isNull && !bounds.isEmpty
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
        payload["rect"] = [visible.minX, visible.minY, visible.width, visible.height]
            .map { String(Double($0)) }.joined(separator: ",")
        let locator = Locator(
            sourceID: base.sourceID, snapshotID: base.snapshotID, adapterID: base.adapterID,
            payload: payload, structuralPath: "page/\(index)", textQuote: nil, fingerprint: nil
        )
        let fraction = (Double(index) + Double((bounds.maxY - point.y) / bounds.height)) / Double(document.pageCount)
        return ReadingPositionUpdate(
            locator: locator, progressFraction: fraction, granularity: .page,
            displayLabel: ReadingPositionUpdate.label(for: locator, detail: "第 \(index + 1) / \(document.pageCount) 页")
        )
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
