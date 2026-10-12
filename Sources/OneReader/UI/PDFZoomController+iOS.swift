#if os(iOS)
import PDFKit
import UIKit

/// PDFKit owns the live pinch scale. Only a changed default, a width change,
/// or a new explicit command may write the scale back to the mounted view.
@MainActor
final class PDFZoomController {
    private(set) var fitWidthScale: CGFloat?
    private(set) var isUpdating = false
    private var appliedDefault: Double?
    private var appliedRequestID: UUID?
    private var viewportWidth: CGFloat?

    func reset() {
        fitWidthScale = nil
        appliedDefault = nil
        appliedRequestID = nil
        viewportWidth = nil
    }

    func update(_ view: PDFView, defaultScale: Double, request: PDFZoomRequest?, pageIndex: Int) {
        guard !isUpdating,
              let page = fitWidthScale == nil
                ? (view.document?.page(at: pageIndex) ?? view.currentPage)
                : (view.currentPage ?? view.document?.page(at: pageIndex)),
              let measuredFit = fitScale(for: page, in: view) else { return }

        isUpdating = true
        defer { isUpdating = false }
        let widthChanged = viewportWidth.map { abs($0 - view.bounds.width) > 0.5 } ?? true
        let newRequest = request.map { $0.id != appliedRequestID } ?? false
        let fittingRequested = newRequest && request?.action == .fitWidth
        let previousFit = fitWidthScale
        let liveRelativeScale = previousFit.map { view.scaleFactor / $0 } ?? 1
        if widthChanged || fittingRequested || previousFit == nil {
            fitWidthScale = measuredFit
            viewportWidth = view.bounds.width
            let fit = fitWidthScale ?? 1
            view.minScaleFactor = fit * 0.5
            view.maxScaleFactor = fit * 6
        }
        guard let fit = fitWidthScale, fit.isFinite, fit > 0 else { return }
        let sanitizedDefault = defaultScale.isFinite ? min(max(defaultScale, 0.5), 3) : 1
        var target: CGFloat?
        if appliedDefault != sanitizedDefault {
            appliedDefault = sanitizedDefault
            target = fit * sanitizedDefault
        } else if widthChanged {
            target = fit * liveRelativeScale
        }
        if newRequest, let request {
            appliedRequestID = request.id
            switch request.action {
            case .zoomIn: target = (target ?? view.scaleFactor) * 1.25
            case .zoomOut: target = (target ?? view.scaleFactor) / 1.25
            case .fitWidth: target = fit
            }
        }
        if let target, target.isFinite {
            let bounded = min(max(target, view.minScaleFactor), view.maxScaleFactor)
            if abs(view.scaleFactor - bounded) > 0.0001 { view.scaleFactor = bounded }
        }
        if fittingRequested {
            view.layoutDocumentView()
            alignHorizontally(page, in: view)
        }
    }

    /// The deferred restore anchor may navigate away from PDFKit's initial
    /// currentPage. Reconcile against the actual target without losing a pinch.
    func refitAfterNavigation(to page: PDFPage, in view: PDFView) {
        guard !isUpdating, let fit = fitScale(for: page, in: view) else { return }
        let relative = fitWidthScale.map { view.scaleFactor / $0 } ?? 1
        isUpdating = true
        defer { isUpdating = false }
        fitWidthScale = fit
        viewportWidth = view.bounds.width
        view.minScaleFactor = fit * 0.5
        view.maxScaleFactor = fit * 6
        let target = min(max(fit * relative, view.minScaleFactor), view.maxScaleFactor)
        if target.isFinite, abs(view.scaleFactor - target) > 0.0001 { view.scaleFactor = target }
    }

    /// Continuous documents use a canvas wide enough for their widest page.
    /// A fitting narrow page can therefore be offscreen even at 100%. Change
    /// only native horizontal offset after page-start/explicit-fit actions or
    /// a viewport restore that remounts at fitting scale;
    /// ordinary updates must never recenter a user's live pan or pinch.
    func alignHorizontally(_ page: PDFPage, in view: PDFView, onlyIfFitting: Bool = false) {
        let displayed = view.convert(page.bounds(for: view.displayBox), from: page)
        guard !onlyIfFitting || displayed.width <= view.bounds.width + 0.5 else { return }
        var ancestor = view.documentView?.superview
        while let current = ancestor {
            if let scroll = current as? UIScrollView {
                let center = scroll.convert(CGPoint(x: displayed.midX, y: view.bounds.midY), from: view)
                let target = scroll.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
                let minimum = -scroll.adjustedContentInset.left
                let maximum = max(minimum, scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right)
                let x = min(max(scroll.contentOffset.x + center.x - target.x, minimum), maximum)
                guard x.isFinite else { return }
                if abs(scroll.contentOffset.x - x) > 0.5 {
                    scroll.setContentOffset(CGPoint(x: x, y: scroll.contentOffset.y), animated: false)
                }
                return
            }
            ancestor = current.superview
        }
    }

    private func fitScale(for page: PDFPage, in view: PDFView) -> CGFloat? {
        guard view.bounds.width.isFinite, view.bounds.width > 0 else { return nil }
        let pageBounds = page.bounds(for: view.displayBox)
        let pageWidth = abs(page.rotation % 180) == 90 ? pageBounds.height : pageBounds.width
        let margins = view.displaysPageBreaks
            ? view.pageBreakMargins.left + view.pageBreakMargins.right : 0
        let availableWidth = view.bounds.width - margins
        guard pageWidth.isFinite, pageWidth > 0,
              availableWidth.isFinite, availableWidth > 0 else { return nil }
        return availableWidth / pageWidth
    }

    func relativeScale(in view: PDFView) -> Double? {
        guard let fitWidthScale, fitWidthScale > 0, view.scaleFactor.isFinite else { return nil }
        return Double(view.scaleFactor / fitWidthScale)
    }
}
#endif
