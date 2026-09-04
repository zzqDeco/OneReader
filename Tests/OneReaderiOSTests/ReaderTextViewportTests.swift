#if os(iOS)
import UIKit
import XCTest
@testable import OneReader

@MainActor
final class ReaderTextViewportTests: XCTestCase {
    func testProseViewportHasScrollableVerticalRange() {
        let viewport = makeViewport(displaysCode: false)
        viewport.textView.attributedText = NSAttributedString(
            string: Array(repeating: "A readable line of prose.", count: 240).joined(separator: "\n"),
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )

        viewport.layoutIfNeeded()

        XCTAssertGreaterThan(viewport.textView.contentSize.height, viewport.textView.bounds.height)
        let requestedOffset = min(
            180,
            viewport.textView.contentSize.height - viewport.textView.bounds.height
        )
        viewport.textView.setContentOffset(CGPoint(x: 0, y: requestedOffset), animated: false)
        XCTAssertGreaterThan(viewport.textView.contentOffset.y, 0)
    }

    func testCodeViewportHasScrollableHorizontalRange() {
        let viewport = makeViewport(displaysCode: true)
        viewport.textView.attributedText = NSAttributedString(
            string: String(repeating: "0123456789", count: 320),
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)]
        )

        viewport.layoutIfNeeded()

        XCTAssertGreaterThan(viewport.textView.contentSize.width, viewport.textView.bounds.width)
        let requestedOffset = min(
            180,
            viewport.textView.contentSize.width - viewport.textView.bounds.width
        )
        viewport.textView.setContentOffset(CGPoint(x: requestedOffset, y: 0), animated: false)
        XCTAssertGreaterThan(viewport.textView.contentOffset.x, 0)
    }

    private func makeViewport(displaysCode: Bool) -> ReaderTextViewportView {
        let viewport = ReaderTextViewportView(frame: CGRect(x: 0, y: 0, width: 390, height: 720))
        viewport.displaysCode = displaysCode
        viewport.textView.isScrollEnabled = true
        viewport.textView.textContainerInset = UIEdgeInsets(top: 26, left: 18, bottom: 42, right: 18)
        viewport.textView.textContainer.widthTracksTextView = !displaysCode
        viewport.textView.textContainer.heightTracksTextView = false
        viewport.textView.textContainer.lineBreakMode = displaysCode ? .byClipping : .byWordWrapping
        viewport.setNeedsLayout()
        return viewport
    }
}
#endif
