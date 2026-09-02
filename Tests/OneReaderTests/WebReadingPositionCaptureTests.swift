#if os(macOS)
import AppKit
import WebKit
import XCTest
@testable import OneReader

@MainActor
final class WebReadingPositionCaptureTests: XCTestCase {
    func testProductionBridgeCapturesCurrentWKWebViewScrollPositionOnDemand() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let sink = WebPositionMessageSink()
        configuration.userContentController.add(
            sink,
            name: ControlledWebPresentation.Coordinator.positionHandlerName
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: ControlledWebPresentation.Coordinator.positionBridge,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 420),
            configuration: configuration
        )
        let navigation = WebNavigationProbe()
        webView.navigationDelegate = navigation
        webView.loadHTMLString(Self.longHTML, baseURL: nil)
        try await waitUntil(timeout: .seconds(5)) { navigation.didFinish }

        _ = try await webView.evaluateJavaScript(
            "window.scrollTo(0, (document.scrollingElement.scrollHeight - window.innerHeight) * 0.82); true;"
        )
        let result = try await webView.evaluateJavaScript(
            WebReadingPositionCapture.currentPositionJavaScript
        )
        let body = try XCTUnwrap(result as? [String: Any])
        let fraction = try XCTUnwrap(body["fraction"] as? NSNumber).doubleValue
        let path = try XCTUnwrap(body["path"] as? String)

        XCTAssertEqual(fraction, 0.82, accuracy: 0.03)
        XCTAssertTrue(path.contains("h2:nth-of-type(3)"), path)
        XCTAssertFalse((body["quote"] as? String ?? "").isEmpty)
    }

    private static let longHTML = """
        <!doctype html>
        <html><head><style>
        body { margin: 0; }
        h2 { margin: 0; padding: 12px; }
        section { height: 720px; padding: 12px; }
        </style></head><body>
        <h2>First</h2><section>first body</section>
        <h2>Second</h2><section>second body</section>
        <h2>Third</h2><section>third body</section>
        </body></html>
        """

    private func waitUntil(
        timeout: Duration,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Condition did not become true before timeout")
    }
}

@MainActor
private final class WebNavigationProbe: NSObject, WKNavigationDelegate {
    private(set) var didFinish = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish = true
    }
}

@MainActor
private final class WebPositionMessageSink: NSObject, WKScriptMessageHandler {
    private(set) var messages: [[String: Any]] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if let body = message.body as? [String: Any] {
            messages.append(body)
        }
    }
}
#endif
