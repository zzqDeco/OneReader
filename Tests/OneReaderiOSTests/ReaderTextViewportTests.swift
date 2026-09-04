#if os(iOS)
import UIKit
import XCTest
@testable import OneReader

@MainActor
final class ReaderTextViewportTests: XCTestCase {
    func testProseViewportExposesVerticalContentRange() {
        let textView = makeTextView(displaysCode: false)
        textView.attributedText = NSAttributedString(
            string: Array(repeating: "A readable line of prose.", count: 240).joined(separator: "\n"),
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )

        textView.layoutIfNeeded()

        XCTAssertGreaterThan(textView.contentSize.height, textView.bounds.height)
        let requestedOffset = min(
            180,
            textView.contentSize.height - textView.bounds.height
        )
        textView.setContentOffset(CGPoint(x: 0, y: requestedOffset), animated: false)
        XCTAssertGreaterThan(textView.contentOffset.y, 0)
    }

    func testProseViewportReflowsWhenSwiftUIAssignsBoundsAfterContent() {
        let textView = makeTextView(
            displaysCode: false,
            frame: .zero
        )
        textView.attributedText = NSAttributedString(
            string: Array(repeating: "A readable line of prose.", count: 240).joined(separator: "\n"),
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )

        textView.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        textView.setNeedsLayout()
        textView.layoutIfNeeded()

        XCTAssertGreaterThan(textView.contentSize.height, textView.bounds.height)
    }

    func testProseViewportExposesVerticalContentRangeForLargeDocument() {
        let textView = makeTextView(displaysCode: false)
        let content = (0..<900).map { index in
            "Reading line \(index + 1): this deterministic fixture verifies real vertical touch scrolling through the complete OneReader workspace."
        }.joined(separator: "\n\n")
        textView.attributedText = NSAttributedString(
            string: content,
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )

        textView.layoutIfNeeded()

        XCTAssertGreaterThan(textView.contentSize.height, textView.bounds.height)
    }

    func testCodeViewportExposesCappedHorizontalContentRange() throws {
        let textView = makeTextView(displaysCode: true)
        let content = String(repeating: "0123456789", count: 320)
        let font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.attributedText = NSAttributedString(
            string: content,
            attributes: [.font: font]
        )
        textView.applyCodeContentWidth(
            try ReaderTextLayoutMetrics.codeContentWidth(
                for: content,
                glyphAdvance: ("M" as NSString).size(withAttributes: [.font: font]).width,
                lineFragmentPadding: textView.textContainer.lineFragmentPadding
            )
        )

        textView.layoutIfNeeded()

        XCTAssertGreaterThan(textView.textContainer.size.width, textView.bounds.width)
        XCTAssertGreaterThan(textView.contentSize.width, textView.bounds.width)
        let requestedOffset = min(
            180,
            textView.contentSize.width - textView.bounds.width
        )
        textView.setContentOffset(CGPoint(x: requestedOffset, y: 0), animated: false)
        XCTAssertGreaterThan(textView.contentOffset.x, 0)
    }

    func testCodeWidthMeasurementStopsAtSafetyLimit() throws {
        let oversizedLine = String(repeating: "x", count: ReaderTextLayoutMetrics.maximumCodeColumns * 4)

        XCTAssertEqual(
            try ReaderTextLayoutMetrics.maximumVisualColumns(
                in: oversizedLine,
                limit: ReaderTextLayoutMetrics.maximumCodeColumns
            ),
            ReaderTextLayoutMetrics.maximumCodeColumns
        )
    }

    func testEstimatedHeightUnlocksLargeWrappedDocumentWithoutWholeDocumentLayout() throws {
        let textView = makeTextView(displaysCode: false)
        let content = String(repeating: "long wrapped prose ", count: 8_000)
        textView.attributedText = NSAttributedString(
            string: content,
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        let minimumHeight = try ReaderTextLayoutMetrics.minimumContentHeight(
            for: content,
            availableWidth: 354,
            glyphAdvance: 4,
            lineHeight: 23,
            verticalInsets: 68,
            wrapsLines: true
        )

        textView.applyMinimumScrollableContentHeight(minimumHeight)
        textView.layoutIfNeeded()

        XCTAssertGreaterThan(minimumHeight, textView.bounds.height)
        XCTAssertGreaterThan(textView.contentSize.height, textView.bounds.height)
    }

    func testScrollableHeightEstimateCanShrinkAfterReflow() {
        let textView = makeTextView(displaysCode: false)
        textView.attributedText = NSAttributedString(
            string: "Short content",
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        textView.applyMinimumScrollableContentHeight(10_000)
        textView.layoutIfNeeded()
        let expandedHeight = textView.contentSize.height

        textView.applyMinimumScrollableContentHeight(900)
        textView.layoutIfNeeded()

        XCTAssertGreaterThanOrEqual(textView.contentSize.height, 900)
        XCTAssertLessThan(textView.contentSize.height, expandedHeight)
    }

    func testCodeWidthCanShrinkAfterRotationAndRemeasurement() {
        let textView = makeTextView(displaysCode: true)
        textView.attributedText = NSAttributedString(
            string: "let answer = 42",
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)]
        )
        textView.applyCodeContentWidth(10_000)
        textView.layoutIfNeeded()
        let expandedWidth = textView.contentSize.width

        textView.frame = CGRect(x: 0, y: 0, width: 720, height: 390)
        textView.applyCodeContentWidth(900)
        textView.layoutIfNeeded()

        XCTAssertGreaterThanOrEqual(textView.contentSize.width, 900)
        XCTAssertLessThan(textView.contentSize.width, expandedWidth)
    }

    func testLayoutMetricScanCooperativelyCancels() async {
        let content = String(repeating: "cancellable reader content\n", count: 100_000)
        let worker = Task.detached {
            try ReaderTextLayoutMetrics.minimumContentHeight(
                for: content,
                availableWidth: 320,
                glyphAdvance: 4,
                lineHeight: 22,
                verticalInsets: 68,
                wrapsLines: true
            )
        }
        worker.cancel()

        do {
            _ = try await worker.value
            XCTFail("Cancelled layout scan unexpectedly completed")
        } catch is CancellationError {
            // Expected: the worker observes cancellation before publishing metrics.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    private func makeTextView(
        displaysCode: Bool,
        frame: CGRect = CGRect(x: 0, y: 0, width: 390, height: 720)
    ) -> ReaderTextView {
        let textView = ReaderTextView(frame: frame)
        textView.displaysCode = displaysCode
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 26, left: 18, bottom: 42, right: 18)
        textView.textContainer.widthTracksTextView = !displaysCode
        textView.textContainer.heightTracksTextView = false
        textView.textContainer.lineBreakMode = displaysCode ? .byClipping : .byWordWrapping
        textView.setNeedsLayout()
        return textView
    }
}
#endif
