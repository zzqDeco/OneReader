import XCTest

@MainActor
final class ReaderTouchScrollUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLibraryRespondsToVerticalSwipeInCompleteWorkspace() {
        let app = launch(fixture: "library-scroll")
        let library = app.scrollViews["library-scroll-view"]
        XCTAssertTrue(library.waitForExistence(timeout: 10), "Library scroll view did not appear")
        let firstCard = app.buttons["space-card-ui-library-0"]
        XCTAssertTrue(firstCard.waitForExistence(timeout: 5), "First fixture card did not appear")
        let initialY = firstCard.frame.minY

        library.swipeUp()
        waitForScrollingToSettle()

        XCTAssertLessThan(
            firstCard.frame.minY,
            initialY - 24,
            "Library ignored a real vertical swipe"
        )
    }

    func testNativeTextReaderRespondsToVerticalSwipeInCompleteWorkspace() {
        let app = launch(fixture: "text-scroll")
        let reader = app.textViews["reader-text-view"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10), "Native text reader did not appear")
        waitForScrollingToSettle()
        XCTAssertEqual(offset("y", of: reader), 0)

        reader.swipeUp()
        waitForScrollingToSettle()

        XCTAssertGreaterThan(
            offset("y", of: reader),
            24,
            "Native text reader ignored a real vertical swipe: \(reader.value ?? "nil")"
        )
    }

    func testNativeMarkdownReaderRespondsToVerticalSwipeInCompleteWorkspace() {
        let app = launch(fixture: "markdown-scroll")
        let reader = app.textViews["reader-text-view"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10), "Native Markdown reader did not appear")
        waitForScrollingToSettle()
        XCTAssertEqual(offset("y", of: reader), 0)

        reader.swipeUp()
        waitForScrollingToSettle()

        XCTAssertGreaterThan(
            offset("y", of: reader),
            24,
            "Native Markdown reader ignored a real vertical swipe: \(reader.value ?? "nil")"
        )
    }

    func testNativeCodeReaderRespondsToVerticalAndHorizontalSwipesInCompleteWorkspace() {
        let app = launch(fixture: "code-scroll")
        let reader = app.textViews["reader-code-view"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10), "Native code reader did not appear")
        waitForScrollingToSettle()
        XCTAssertEqual(offset("x", of: reader), 0)
        XCTAssertEqual(offset("y", of: reader), 0)

        reader.swipeUp()
        waitForScrollingToSettle()

        XCTAssertGreaterThan(
            offset("y", of: reader),
            24,
            "Native code reader ignored a real vertical swipe: \(reader.value ?? "nil")"
        )

        reader.swipeLeft()
        waitForScrollingToSettle()

        XCTAssertGreaterThan(
            offset("x", of: reader),
            24,
            "Native code reader ignored a real horizontal swipe: \(reader.value ?? "nil")"
        )
    }

    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ONEREADER_UI_TEST_FIXTURE"] = fixture
        app.launch()
        return app
    }

    private func waitForScrollingToSettle() {
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    }

    private func offset(_ axis: String, of element: XCUIElement) -> Int {
        metric(axis, of: element)
    }

    private func metric(_ name: String, of element: XCUIElement) -> Int {
        let value = element.value as? String ?? ""
        let component = value.split(separator: ";").first { $0.hasPrefix("\(name):") }
        return component
            .flatMap { Int($0.dropFirst(name.count + 1)) }
            ?? -1
    }
}
