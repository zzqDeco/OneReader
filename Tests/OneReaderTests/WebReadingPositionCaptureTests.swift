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
        let outlinePath = try XCTUnwrap(body["outlinePath"] as? String)

        XCTAssertEqual(fraction, 0.82, accuracy: 0.03)
        XCTAssertTrue(path.contains("section:nth-of-type(3)"), path)
        XCTAssertTrue(outlinePath.contains("h2:nth-of-type(3)"), outlinePath)
        XCTAssertFalse((body["quote"] as? String ?? "").isEmpty)
    }

    func testProductionBridgeCaptureReloadRestoreRoundTripKeepsExactFraction() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
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
        try await waitUntil(timeout: .seconds(5)) { navigation.finishCount == 1 }

        _ = try await webView.evaluateJavaScript(
            "window.scrollTo(0, (document.scrollingElement.scrollHeight - window.innerHeight) * 0.82); true;"
        )
        let capturedValue = try await webView.evaluateJavaScript(
            WebReadingPositionCapture.currentPositionJavaScript
        )
        let captured = try XCTUnwrap(capturedValue as? [String: Any])
        let base = Locator(
            sourceID: "source",
            snapshotID: "snapshot",
            adapterID: "onereader.html",
            payload: ["path": "chapter.html"],
            structuralPath: "chapter.html"
        )
        let update = WebReadingPositionCapture.capturedUpdate(
            for: base,
            path: captured["path"] as? String,
            outlinePath: captured["outlinePath"] as? String,
            quote: captured["quote"] as? String,
            fraction: (captured["fraction"] as? NSNumber)?.doubleValue
        )

        webView.loadHTMLString(Self.longHTML, baseURL: nil)
        try await waitUntil(timeout: .seconds(5)) { navigation.finishCount == 2 }
        _ = try await webView.evaluateJavaScript(
            ControlledWebPresentation.anchorScript(for: update.locator)
        )
        try await Task.sleep(for: .milliseconds(50))
        let restoredValue = try await webView.evaluateJavaScript(
            WebReadingPositionCapture.currentPositionJavaScript
        )
        let restored = try XCTUnwrap(restoredValue as? [String: Any])
        let restoredFraction = try XCTUnwrap(
            restored["fraction"] as? NSNumber
        ).doubleValue

        XCTAssertEqual(restoredFraction, 0.82, accuracy: 0.03)
        XCTAssertTrue(
            (restored["outlinePath"] as? String ?? "")
                .contains("h2:nth-of-type(3)")
        )
    }

    func testCaptureNotificationTargetsOnlyTheRequestedWindowPresentation() async throws {
        func makeWebView() -> (WKWebView, WebNavigationProbe) {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
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
            return (webView, navigation)
        }

        let (firstWebView, firstNavigation) = makeWebView()
        let (secondWebView, secondNavigation) = makeWebView()
        try await waitUntil(timeout: .seconds(5)) {
            firstNavigation.didFinish && secondNavigation.didFinish
        }
        _ = try await firstWebView.evaluateJavaScript(
            "window.scrollTo(0, (document.scrollingElement.scrollHeight - window.innerHeight) * 0.18); true;"
        )
        _ = try await secondWebView.evaluateJavaScript(
            "window.scrollTo(0, (document.scrollingElement.scrollHeight - window.innerHeight) * 0.82); true;"
        )

        let locator = Locator(
            sourceID: "multi-window-source",
            snapshotID: "multi-window-snapshot",
            adapterID: HTMLAdapter.id,
            payload: ["path": "chapter.html"],
            structuralPath: "chapter.html"
        )
        let document = PresentationDocument(
            id: "multi-window-presentation",
            surface: .sanitizedWeb,
            locator: locator,
            title: "Chapter",
            mediaType: "text/html",
            content: Self.longHTML,
            contentURL: nil,
            baseURL: nil,
            limitations: []
        )
        let firstTargetID = UUID()
        let secondTargetID = UUID()
        let firstCoordinator = ControlledWebPresentation.Coordinator(
            parent: ControlledWebPresentation(
                document: document,
                captureTargetID: firstTargetID,
                preferences: ReaderPreferences(),
                colorScheme: .light,
                onSelectionChange: { _ in },
                onPositionChange: { _ in }
            )
        )
        let secondCoordinator = ControlledWebPresentation.Coordinator(
            parent: ControlledWebPresentation(
                document: document,
                captureTargetID: secondTargetID,
                preferences: ReaderPreferences(),
                colorScheme: .light,
                onSelectionChange: { _ in },
                onPositionChange: { _ in }
            )
        )
        firstCoordinator.observeCaptureRequests(for: firstWebView)
        secondCoordinator.observeCaptureRequests(for: secondWebView)
        defer {
            firstCoordinator.stopObservingCaptureRequests()
            secondCoordinator.stopObservingCaptureRequests()
        }

        var captured: ReadingPositionUpdate?
        let request = ReadingPositionCaptureRequest(
            targetID: secondTargetID,
            sourceID: locator.sourceID,
            snapshotID: locator.snapshotID
        ) { update in
            captured = update
        }
        NotificationCenter.default.post(
            name: ReadingPositionCaptureSignal.requested,
            object: request
        )
        try await waitUntil(timeout: .seconds(5)) { captured != nil }

        XCTAssertTrue(request.isClaimed)
        XCTAssertEqual(
            try XCTUnwrap(captured?.progressFraction),
            0.82,
            accuracy: 0.03
        )
    }

    func testDelayedRealWebCaptureDuringSpaceSwitchPersistsOnlyOldSpace() async throws {
        let root = temporaryRoot("DeferredRealWebSpaceSwitch")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstURL = root.appendingPathComponent("first.html")
        let secondURL = root.appendingPathComponent("second.html")
        try Data(Self.longHTML.utf8).write(to: firstURL)
        try Data("<h1>Second</h1><p>new space</p>".utf8).write(to: secondURL)
        let suite = "OneReaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library"),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil(timeout: .seconds(5)) { model.isBootstrapComplete }
        model.importLocalURLs([firstURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.presentationDocument?.title == "first.html"
                && model.activePendingImportCount == 0
        }
        let firstSpaceID = try XCTUnwrap(model.selectedSpaceID)
        let firstSourceID = try XCTUnwrap(model.selectedSourceID)

        model.importLocalURLs([secondURL])
        try await waitUntil(timeout: .seconds(5)) {
            model.spaces.count == 2
                && model.presentationDocument?.title == "second.html"
                && model.activePendingImportCount == 0
        }
        let secondSpaceID = try XCTUnwrap(model.selectedSpaceID)
        model.openSpace(firstSpaceID)
        try await waitUntil(timeout: .seconds(5)) {
            model.presentationDocument?.title == "first.html"
        }
        let base = try XCTUnwrap(model.presentationDocument?.locator)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
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
        try await waitUntil(timeout: .seconds(5)) { navigation.finishCount == 1 }
        _ = try await webView.evaluateJavaScript(
            "window.scrollTo(0, (document.scrollingElement.scrollHeight - window.innerHeight) * 0.82); true;"
        )

        let captureProbe = DeferredRealWebCaptureProbe(webView: webView, base: base)
        NotificationCenter.default.addObserver(
            captureProbe,
            selector: #selector(DeferredRealWebCaptureProbe.capture(_:)),
            name: ReadingPositionCaptureSignal.requested,
            object: nil
        )
        defer { NotificationCenter.default.removeObserver(captureProbe) }

        model.openSpace(secondSpaceID)
        try await waitUntil(timeout: .seconds(5)) {
            captureProbe.completedCount == 1
                && model.presentationDocument?.title == "second.html"
                && model.progressBySpace[firstSpaceID]?
                    .sourcePositions[firstSourceID]?.progressFraction != nil
        }

        XCTAssertEqual(captureProbe.requestCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(
                model.progressBySpace[firstSpaceID]?
                    .sourcePositions[firstSourceID]?.progressFraction
            ),
            0.82,
            accuracy: 0.03
        )
        XCTAssertNil(
            model.progressBySpace[secondSpaceID]?.sourcePositions[firstSourceID]
        )
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

    private func temporaryRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OneReaderTests")
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
    }
}

@MainActor
private final class WebNavigationProbe: NSObject, WKNavigationDelegate {
    private(set) var finishCount = 0
    var didFinish: Bool { finishCount > 0 }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishCount += 1
    }
}

@MainActor
private final class DeferredRealWebCaptureProbe: NSObject {
    private weak var webView: WKWebView?
    private let base: Locator
    private(set) var requestCount = 0
    private(set) var completedCount = 0

    init(webView: WKWebView, base: Locator) {
        self.webView = webView
        self.base = base
        super.init()
    }

    @objc func capture(_ notification: Notification) {
        guard let request = notification.object as? ReadingPositionCaptureRequest else {
            return
        }
        requestCount += 1
        let base = base
        let targetID = request.targetID
        guard request.claim(targetID: targetID, locator: base) else { return }
        Task { @MainActor [weak self, weak webView] in
            try? await Task.sleep(for: .milliseconds(40))
            guard let self, let webView,
                  let body = try? await webView.evaluateJavaScript(
                    WebReadingPositionCapture.currentPositionJavaScript
                  ) as? [String: Any] else {
                request.finish(with: nil, targetID: targetID)
                return
            }
            let update = WebReadingPositionCapture.capturedUpdate(
                for: base,
                path: body["path"] as? String,
                outlinePath: body["outlinePath"] as? String,
                quote: body["quote"] as? String,
                fraction: (body["fraction"] as? NSNumber)?.doubleValue
            )
            completedCount += 1
            request.finish(with: update, targetID: targetID)
        }
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
