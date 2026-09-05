#if os(iOS)
import PDFKit
import WebKit

#if DEBUG
@MainActor
private func recoveryMetricsEnabled() -> Bool {
#if DEBUG
    ProcessInfo.processInfo.environment["ONEREADER_UI_TEST_RECOVERY_ID"] != nil
#else
    false
#endif
}

/// Read-only observations of the mounted native surface. Saved Locators are
/// deliberately unavailable here, so a persisted row cannot masquerade as a
/// successful visual restoration.
@MainActor
final class RecoveryObservablePDFView: ReadingPDFView {
    override var accessibilityIdentifier: String? {
        get { recoveryMetricsEnabled() ? "reader-pdf-view" : super.accessibilityIdentifier }
        set { super.accessibilityIdentifier = newValue }
    }

    override var isAccessibilityElement: Bool {
        get { recoveryMetricsEnabled() || super.isAccessibilityElement }
        set { super.isAccessibilityElement = newValue }
    }

    override var accessibilityValue: String? {
        get {
            guard recoveryMetricsEnabled(), let document,
                  let page = page(for: CGPoint(x: bounds.midX, y: bounds.minY + 1), nearest: true) else {
                return super.accessibilityValue
            }
            let point = convert(CGPoint(x: bounds.minX, y: bounds.minY), to: page)
            let fields: [String: Double] = [
                "page": Double(document.index(for: page)), "x": point.x, "y": point.y,
                "height": bounds.height, "scale": scaleFactor,
            ]
            return (try? JSONEncoder().encode(fields)).map { String(decoding: $0, as: UTF8.self) }
        }
        set { super.accessibilityValue = newValue }
    }
}

@MainActor
final class RecoveryObservableWebView: WKWebView {
    private(set) var observedDocumentTitle: String?

    func refreshDocumentObservation() {
        guard recoveryMetricsEnabled() else { return }
        // This observes the loaded DOM, never PresentationDocument/Locator.
        evaluateJavaScript("document.title") { [weak self] result, _ in
            self?.observedDocumentTitle = result as? String
            self?.accessibilityLabel = result as? String
        }
    }

    override var accessibilityIdentifier: String? {
        get { recoveryMetricsEnabled() ? "reader-web-view" : super.accessibilityIdentifier }
        set { super.accessibilityIdentifier = newValue }
    }

    override var accessibilityValue: String? {
        get {
            guard recoveryMetricsEnabled() else { return super.accessibilityValue }
            let maximum = max(1, scrollView.contentSize.height - scrollView.bounds.height)
            let fields: [String: Double] = [
                "y": scrollView.contentOffset.y,
                "fraction": scrollView.contentOffset.y / maximum,
                "height": scrollView.bounds.height,
                "loading": isLoading ? 1 : 0,
            ]
            return (try? JSONEncoder().encode(fields)).map { String(decoding: $0, as: UTF8.self) }
        }
        set { super.accessibilityValue = newValue }
    }
}
#else
typealias RecoveryObservablePDFView = ReadingPDFView
typealias RecoveryObservableWebView = WKWebView
#endif
#endif
