import XCTest

@MainActor
final class FileImportAndPDFZoomUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSystemPickerImportsPDFAndPinchSurvivesPositionUpdates() throws {
        let (app, runID) = launchEmptyLibrary()
        app.buttons["粘贴 URL"].tap()
        let local = app.buttons["import-local-materials"]
        XCTAssertTrue(local.waitForExistence(timeout: 10))
        local.tap()
        try selectFile("Picker PDF", in: app, runID: runID)
        let reader = app.otherElements["reader-pdf-view"]
        XCTAssertTrue(reader.waitForExistence(timeout: 30), "The selected PDF never reached the reader: \(app.debugDescription)")
        let initial = try settledMetrics(reader)
        XCTAssertLessThanOrEqual(try number("pageWidth", in: initial), try number("width", in: initial) + 2)
        XCTAssertGreaterThan(try number("pageWidth", in: initial), try number("width", in: initial) * 0.9)
        attach(app, "picked-PDF-fits-width")

        reader.pinch(withScale: 1.8, velocity: 1)
        let enlarged = try settledMetrics(reader)
        XCTAssertGreaterThan(try number("scale", in: enlarged), try number("scale", in: initial) * 1.3)
        reader.swipeUp(velocity: .slow)
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        let afterPositionSave = try settledMetrics(reader)
        XCTAssertEqual(try number("scale", in: afterPositionSave), try number("scale", in: enlarged), accuracy: 0.015)
        attach(app, "pinch-preserved-after-position-save")

        reader.pinch(withScale: 0.7, velocity: -1)
        let reduced = try settledMetrics(reader)
        XCTAssertLessThan(try number("scale", in: reduced), try number("scale", in: enlarged) * 0.9)
        attach(app, "pinch-out-preserved")
        app.terminate()
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Picker PDF")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Picked source did not survive relaunch")
        card.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
        attach(app, "picked-PDF-readable-after-relaunch")
    }

    func testPDFButtonsUseLivePinchScaleAndFitWidth() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ONEREADER_UI_TEST_RECOVERY_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.staticTexts["recovery-fixture-ready"].waitForExistence(timeout: 45))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Recovery PDF")).firstMatch.tap()
        let reader = app.otherElements["reader-pdf-view"]
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
        let fit = try number("scale", in: settledMetrics(reader))
        reader.pinch(withScale: 1.5, velocity: 1)
        let pinched = try number("scale", in: settledMetrics(reader))
        XCTAssertGreaterThan(pinched, fit * 1.15)

        app.buttons["pdf-zoom-in"].tap()
        let increased = try number("scale", in: settledMetrics(reader))
        XCTAssertEqual(increased, pinched * 1.25, accuracy: 0.015)
        reader.swipeUp(velocity: .slow)
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(try number("scale", in: settledMetrics(reader)), increased, accuracy: 0.015)
        attach(app, "zoom-in-from-live-pinch")

        app.buttons["pdf-zoom-out"].tap()
        XCTAssertEqual(try number("scale", in: settledMetrics(reader)), increased / 1.25, accuracy: 0.015)
        app.buttons["pdf-fit-width"].tap()
        let fitted = try settledMetrics(reader)
        XCTAssertEqual(try number("scale", in: fitted), fit, accuracy: 0.015)
        XCTAssertLessThanOrEqual(try number("pageWidth", in: fitted), try number("width", in: fitted) + 2)
        XCTAssertTrue(app.staticTexts["pdf-zoom-percentage"].exists)
        XCTAssertEqual(app.staticTexts["pdf-zoom-percentage"].value as? String, "100%")
        attach(app, "zoom-out-and-fit-width")
    }

    func testPDFScrollFramePacing() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ONEREADER_UI_TEST_RECOVERY_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.staticTexts["recovery-fixture-ready"].waitForExistence(timeout: 45))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Recovery PDF")).firstMatch.tap()
        let reader = app.otherElements["reader-pdf-view"]
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
        _ = try settledMetrics(reader)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            reader.swipeUp(velocity: .fast)
            reader.swipeUp(velocity: .fast)
            reader.swipeDown(velocity: .fast)
            reader.swipeDown(velocity: .fast)
        }
        attach(app, "PDF-scroll-frame-pacing")
    }

    func testZoomedPDFRepeatedScrollAndPausePreservesNativeScale() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ONEREADER_UI_TEST_RECOVERY_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.staticTexts["recovery-fixture-ready"].waitForExistence(timeout: 45))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Recovery PDF")).firstMatch.tap()
        let reader = app.otherElements["reader-pdf-view"]
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
        let fit = try number("scale", in: settledMetrics(reader))
        reader.pinch(withScale: 1.8, velocity: 1)
        let initial = try settledMetrics(reader)
        let pinched = try number("scale", in: initial)
        XCTAssertGreaterThan(pinched, fit * 1.3)
        let initialSaved = try waitForPDFPersistence(in: app, viewport: initial)
        reader.swipeUp(velocity: .slow)
        let moved = try settledMetrics(reader)
        let displacement = try number("y", in: moved) - number("y", in: initial)
        XCTAssertTrue(
            moved["page"] != initial["page"] || abs(displacement) > 24,
            "The zoomed gesture must move the mounted viewport"
        )
        let movedSaved = try waitForPDFPersistence(in: app, viewport: moved)
        XCTAssertEqual(movedSaved["source"], initialSaved["source"])
        XCTAssertEqual(movedSaved["snapshot"], initialSaved["snapshot"])
        XCTAssertTrue(movedSaved["page"] != initialSaved["page"] || movedSaved["viewportY"] != initialSaved["viewportY"])
        XCTAssertEqual(try number("scale", in: settledMetrics(reader)), pinched, accuracy: 0.015)

        let options = XCTMeasureOptions()
        options.iterationCount = 6
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            reader.swipeUp(velocity: .slow)
            reader.swipeUp(velocity: .fast)
            // Interleave idle gaps with new bursts. Independent settled
            // viewport/persistence checks outside measurement prove that
            // callbacks and saves occurred; this delay alone does not.
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
            reader.swipeDown(velocity: .slow)
            reader.swipeDown(velocity: .fast)
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        }
        let final = try settledMetrics(reader)
        _ = try waitForPDFPersistence(in: app, viewport: final)
        XCTAssertEqual(try number("scale", in: final), pinched, accuracy: 0.015)
        app.buttons["pdf-fit-width"].tap()
        XCTAssertEqual(try number("scale", in: settledMetrics(reader)), fit, accuracy: 0.015)
        attach(app, "zoomed-PDF-repeated-scroll-pauses-preserve-scale")
    }

    func testPickerCancelRetryAndAddToCurrentSpace() throws {
        let (app, runID) = launchEmptyLibrary()
        app.buttons["选择文件或目录"].tap()
        let file = app.staticTexts["Picker PDF"]
        XCTAssertTrue(file.waitForExistence(timeout: 15), "The system picker must finish presenting before cancellation")
        attach(app, "system-picker-before-cancellation")
        // On iOS 27, a non-hittable cancel AX wrapper overlaps Files' More
        // button. Dismiss the actual system sheet with its native drag gesture.
        let picker = app.otherElements["Browse View (Picker)"]
        let start = picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        let end = picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: end)
        let libraryButton = app.buttons["粘贴 URL"]
        let unblocked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: libraryButton)
        XCTAssertEqual(XCTWaiter.wait(for: [unblocked], timeout: 10), .completed, "The Library must be hittable after the real picker is dismissed: \(app.debugDescription)")
        attach(app, "system-picker-cancelled-library-unblocked")
        app.buttons["粘贴 URL"].tap()
        let local = app.buttons["import-local-materials"]
        XCTAssertTrue(local.waitForExistence(timeout: 10), "The import sheet did not open after cancellation: \(app.debugDescription)")
        local.tap()
        try selectFile("Picker PDF", in: app, runID: runID)
        XCTAssertTrue(app.otherElements["reader-pdf-view"].waitForExistence(timeout: 30))
        app.buttons["更多"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "加入当前阅读空间")).firstMatch.tap()
        try selectFile("Picker Note", in: app, runID: runID)
        XCTAssertTrue(app.textViews["reader-text-view"].waitForExistence(timeout: 30))
        app.navigationBars.buttons.firstMatch.tap()
        let card = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "Picker PDF", "2 个来源"
        )).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The second selection did not join the existing Space: \(app.debugDescription)")
        attach(app, "cancel-retry-current-space-two-sources")
    }

    func testMixedWidthPDFRestoresWiderPageAtFitWidth() throws {
        let (app, runID) = launchEmptyLibrary()
        app.buttons["选择文件或目录"].tap()
        try selectFile("Picker Mixed PDF", in: app, runID: runID)
        let reader = app.otherElements["reader-pdf-view"]
        XCTAssertTrue(reader.waitForExistence(timeout: 30))
        _ = try settledMetrics(reader)
        app.buttons["下一项"].tap()
        let wider = try settledMetrics(reader)
        XCTAssertEqual(try number("page", in: wider), 1)
        XCTAssertLessThanOrEqual(try number("pageWidth", in: wider), try number("width", in: wider) + 2)
        XCTAssertGreaterThan(try number("pageWidth", in: wider), try number("width", in: wider) * 0.9)
        attach(app, "mixed-width-second-page-fits")
        app.navigationBars.buttons.firstMatch.tap()
        app.terminate()
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Picker Mixed PDF")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
        let restored = try settledMetrics(reader)
        XCTAssertEqual(try number("page", in: restored), 1)
        XCTAssertEqual(try number("scale", in: restored), try number("scale", in: wider), accuracy: 0.015)
        XCTAssertLessThanOrEqual(try number("pageWidth", in: restored), try number("width", in: restored) + 2)
        XCTAssertEqual(app.staticTexts["pdf-zoom-percentage"].value as? String, "100%")
        attach(app, "mixed-width-second-page-restored")
    }

    private func launchEmptyLibrary() -> (XCUIApplication, String) {
        let runID = UUID().uuidString
        let app = XCUIApplication()
        app.launchEnvironment["ONEREADER_UI_TEST_RECOVERY_ID"] = runID
        app.launchEnvironment["ONEREADER_UI_TEST_IMPORT_FLOW"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["recovery-fixture-ready"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["选择文件或目录"].exists, "The test must start with an empty Library")
        return (app, runID)
    }

    private func selectFile(_ name: String, in app: XCUIApplication, runID: String) throws {
        let file = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR label == %@ OR label == %@", name, name + ".pdf", name + ".txt"
        )).firstMatch
        if !file.waitForExistence(timeout: 8) {
            let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["浏览", "Browse"])).firstMatch
            if browse.exists { browse.tap() }
            let device = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["在我的 iPhone 上", "On My iPhone"])).firstMatch
            XCTAssertTrue(device.waitForExistence(timeout: 10), "Files locations unavailable: \(app.debugDescription)")
            device.tap()
            for folder in ["OneReader Fix Preview", "OneReader Test Inputs", runID] {
                let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", folder)).firstMatch
                XCTAssertTrue(item.waitForExistence(timeout: 10), "Missing fixture folder \(folder): \(app.debugDescription)")
                item.tap()
            }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 10), "Generated file missing from system picker: \(app.debugDescription)")
        attach(app, "system-picker-" + name)
        file.tap()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["打开", "Open", "导入", "Import"])).firstMatch
        if open.waitForExistence(timeout: 3), open.isEnabled { open.tap() }
    }

    private func settledMetrics(_ reader: XCUIElement) throws -> [String: Double] {
        let deadline = Date().addingTimeInterval(10)
        var previous: [String: Double]?
        var stable = 0
        while Date() < deadline {
            if let value = reader.value as? String,
               let data = value.data(using: .utf8),
               let metrics = try? JSONDecoder().decode([String: Double].self, from: data),
               let scale = metrics["scale"], scale.isFinite, scale > 0 {
                if let previous, abs((previous["scale"] ?? -1) - scale) < 0.001,
                   abs((previous["y"] ?? -.infinity) - (metrics["y"] ?? .infinity)) < 1 {
                    stable += 1
                } else { stable = 0 }
                if stable >= 4 { return metrics }
                previous = metrics
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        XCTFail("Native PDF did not settle: \(reader.value ?? "missing")")
        throw ZoomObservationError.notReady
    }

    private func number(_ key: String, in metrics: [String: Double]) throws -> Double {
        try XCTUnwrap(metrics[key], "Missing native PDF metric \(key)")
    }

    private func waitForPDFPersistence(in app: XCUIApplication, viewport: [String: Double]) throws -> [String: String] {
        let element = app.staticTexts["reader-persisted-position"]
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let value = element.value as? String,
               let saved = try? JSONDecoder().decode([String: String].self, from: Data(value.utf8)),
               let page = Double(saved["page"] ?? ""), page == viewport["page"],
               let y = Double(saved["viewportY"] ?? ""), abs(y - (viewport["y"] ?? .infinity)) < 3,
               !saved["rect", default: ""].isEmpty { return saved }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("Saved PDF position did not catch up to the independently settled viewport: \(element.value ?? "missing")")
        throw ZoomObservationError.notReady
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum ZoomObservationError: Error { case notReady }
