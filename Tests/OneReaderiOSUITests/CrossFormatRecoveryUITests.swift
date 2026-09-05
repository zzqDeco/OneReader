import XCTest

@MainActor
final class CrossFormatRecoveryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPDFWithinPagePositionSurvivesSpaceSwitchAndRelaunch() throws {
        try verifyRecovery(format: "PDF")
    }

    func testPDFLaterPagePositionSurvivesSpaceSwitchAndRelaunch() throws {
        try verifyRecovery(format: "PDF", advancePages: true)
    }

    func testHTMLPositionSurvivesSpaceSwitchAndRelaunch() throws {
        try verifyRecovery(format: "HTML")
    }

    func testEPUBPositionSurvivesSpaceSwitchAndRelaunch() throws {
        try verifyRecovery(format: "EPUB")
    }

    func testEPUBSecondSpinePositionSurvivesSpaceSwitchAndRelaunch() throws {
        try verifyRecovery(format: "EPUB", secondSpine: true)
    }

    func testManagedMarkdownPositionSurvivesSpaceSwitchAndRelaunch() throws {
        try verifyRecovery(format: "Markdown")
    }

    private func verifyRecovery(format: String, advancePages: Bool = false, secondSpine: Bool = false) throws {
        let app = XCUIApplication()
        app.launchEnvironment["ONEREADER_UI_TEST_RECOVERY_ID"] = UUID().uuidString
        app.launch()
        let reader = try open(format, in: app)
        if secondSpine {
            app.buttons["目录"].tap()
            let chapter = app.buttons["EPUB Second Chapter"]
            XCTAssertTrue(chapter.waitForExistence(timeout: 10))
            chapter.tap()
            app.buttons["完成"].tap()
            _ = try stableViewport(reader)
            XCTAssertEqual(try persisted(in: app)["path"], "OEBPS/second.xhtml")
        }
        let initial = try stableViewport(reader)
        let initialPersistence = try persisted(in: app)
        let start = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let end = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        start.press(forDuration: 0.1, thenDragTo: end)
        if advancePages {
            for _ in 0..<10 {
                if (try stableViewport(reader)["page"] ?? 0) >= 2 { break }
                reader.swipeUp(velocity: .slow)
            }
        }
        let scrolled = try stableViewport(reader)
        if format == "PDF" {
            if advancePages {
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(scrolled["page"]), 2)
            } else {
                XCTAssertEqual(scrolled["page"], initial["page"], "Fixture must exercise a same-page scroll")
                XCTAssertLessThan(try XCTUnwrap(scrolled["y"]), try XCTUnwrap(initial["y"]) - 24)
            }
        } else {
            XCTAssertGreaterThan(try XCTUnwrap(scrolled["y"]), try XCTUnwrap(initial["y"]) + 24)
        }
        attach(app, name: "\(format)-scrolled")
        let saved = try waitForPersistence(in: app, viewport: scrolled, format: format)
        XCTAssertEqual(saved["source"], initialPersistence["source"])
        XCTAssertEqual(saved["snapshot"], initialPersistence["snapshot"])
        if format == "PDF" {
            XCTAssertFalse(saved["rect", default: ""].isEmpty, "Same-page PDF scroll must save viewport geometry")
        } else if format != "Markdown" {
            XCTAssertGreaterThan(Double(saved["fraction"] ?? "") ?? -1, 0)
            XCTAssertFalse(saved["dom", default: ""].isEmpty)
        }

        backToLibrary(app)
        _ = try open(format == "HTML" ? "EPUB" : "HTML", in: app)
        backToLibrary(app)
        let switched = try open(format, in: app)
        try assertRestored(switched, expected: scrolled, format: format)
        XCTAssertEqual(try persisted(in: app)["source"], saved["source"])
        attach(app, name: "\(format)-space-restored")

        app.terminate()
        app.launch()
        let restored = try open(format, in: app)
        try assertRestored(restored, expected: scrolled, format: format)
        let reopened = try persisted(in: app)
        XCTAssertEqual(reopened["source"], saved["source"])
        XCTAssertEqual(reopened["snapshot"], saved["snapshot"])
        XCTAssertEqual(reopened["path"], saved["path"])
        attach(app, name: "\(format)-process-restored")
    }

    private func open(_ format: String, in app: XCUIApplication) throws -> XCUIElement {
        XCTAssertTrue(app.staticTexts["recovery-fixture-ready"].waitForExistence(timeout: 45))
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Recovery \(format)")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 45), "Imported \(format) fixture missing: \(app.debugDescription)")
        card.tap()
        let identifier = format == "PDF" ? "reader-pdf-view" : (format == "Markdown" ? "reader-text-view" : "reader-web-view")
        let reader = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 20), "\(format) native surface missing: \(app.debugDescription)")
        _ = try stableViewport(reader)
        return reader
    }

    private func backToLibrary(_ app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.scrollViews["library-scroll-view"].waitForExistence(timeout: 10))
    }

    private func viewport(_ reader: XCUIElement) throws -> [String: Double] {
        guard let value = reader.value as? String else { throw RecoveryObservationError.notReady }
        if !value.hasPrefix("{") {
            return Dictionary(uniqueKeysWithValues: value.split(separator: ";").compactMap { item in
                let parts = item.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let number = Double(parts[1]) else { return nil }
                return (String(parts[0]), number)
            })
        }
        return try JSONDecoder().decode([String: Double].self, from: Data(value.utf8))
    }

    private func persisted(in app: XCUIApplication) throws -> [String: String] {
        let element = app.staticTexts["reader-persisted-position"]
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        let predicate = NSPredicate { _, _ in (element.value as? String)?.hasPrefix("{") == true }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10), .completed)
        return try JSONDecoder().decode([String: String].self, from: Data((element.value as? String ?? "").utf8))
    }

    private func assertRestored(_ reader: XCUIElement, expected: [String: Double], format: String) throws {
        let actual = try stableViewport(reader)
        if format == "PDF" { XCTAssertEqual(actual["page"], expected["page"]) }
        if format == "Markdown" {
            XCTAssertEqual(try XCTUnwrap(actual["visible"]), try XCTUnwrap(expected["visible"]), accuracy: 64)
        }
        XCTAssertEqual(try XCTUnwrap(actual["y"]), try XCTUnwrap(expected["y"]), accuracy: 16, "\(format) visible viewport drift")
    }

    private func stableViewport(_ reader: XCUIElement) throws -> [String: Double] {
        let deadline = Date().addingTimeInterval(12)
        var previous: [String: Double]?
        var stableSamples = 0
        while Date() < deadline {
            if let sample = try? viewport(reader), let y = sample["y"], y.isFinite,
               sample["loading"] != 1, sample["height", default: 100] > 40 {
                if let previousY = previous?["y"], abs(y - previousY) < 0.5 {
                    stableSamples += 1
                    if stableSamples >= 3 { return sample }
                } else { stableSamples = 0 }
                previous = sample
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("Native viewport never settled")
        return try XCTUnwrap(previous)
    }

    private func waitForPersistence(in app: XCUIApplication, viewport: [String: Double], format: String) throws -> [String: String] {
        let deadline = Date().addingTimeInterval(10)
        var latest: [String: String] = [:]
        while Date() < deadline {
            latest = try persisted(in: app)
            if format == "PDF", let y = Double(latest["viewportY"] ?? ""),
               abs(y - (viewport["y"] ?? -.infinity)) < 3 { return latest }
            if format == "Markdown", let start = Double(latest["start"] ?? ""),
               abs(start - (viewport["visible"] ?? -.infinity)) <= 64 { return latest }
            if format != "PDF", format != "Markdown", let fraction = Double(latest["fraction"] ?? ""),
               fraction > 0, abs(fraction - (viewport["fraction"] ?? -.infinity)) < 0.0005 { return latest }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("Saved position did not catch up to the independently measured viewport: \(latest)")
        return latest
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum RecoveryObservationError: Error { case notReady }
