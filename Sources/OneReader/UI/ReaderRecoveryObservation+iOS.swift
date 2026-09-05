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
final class RecoveryObservablePDFView: PDFView {
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
            let point = convert(CGPoint(x: bounds.midX, y: bounds.minY + 1), to: page)
            let fields: [String: Double] = [
                "page": Double(document.index(for: page)), "y": point.y,
                "height": bounds.height, "scale": scaleFactor,
            ]
            return (try? JSONEncoder().encode(fields)).map { String(decoding: $0, as: UTF8.self) }
        }
        set { super.accessibilityValue = newValue }
    }
}

@MainActor
final class RecoveryObservableWebView: WKWebView {
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
typealias RecoveryObservablePDFView = PDFView
typealias RecoveryObservableWebView = WKWebView
#endif
#endif
