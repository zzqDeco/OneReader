import AppKit
import XCTest
@testable import OneReader

final class NativeMarkdownRendererTests: XCTestCase {
    func testRendererProducesReadableNativeStructureAndDropsRawHTMLBlocks() throws {
        var renderer = NativeMarkdownRenderer(fontSize: 17, lineSpacing: 6)
        let rendered = renderer.render(
            """
            # Native Reader

            A **readable** paragraph with `code`.

            - First item
            - Second item

            <script>untrustedPayload()</script>
            """
        )

        XCTAssertTrue(rendered.string.contains("Native Reader"))
        XCTAssertTrue(rendered.string.contains("A readable paragraph with code."))
        XCTAssertTrue(rendered.string.contains("•  First item"))
        XCTAssertFalse(rendered.string.contains("untrustedPayload"))

        let titleRange = (rendered.string as NSString).range(of: "Native Reader")
        let titleFont = try XCTUnwrap(
            rendered.attribute(.font, at: titleRange.location, effectiveRange: nil) as? NSFont
        )
        XCTAssertGreaterThan(titleFont.pointSize, 17)
    }

    func testRendererMakesOnlyExplicitHTTPLinksClickable() throws {
        var renderer = NativeMarkdownRenderer(fontSize: 17, lineSpacing: 5)
        let rendered = renderer.render(
            "[Safe](https://example.com) and [Unsafe](javascript:alert(1))"
        )
        let value = rendered.string as NSString
        let safeRange = value.range(of: "Safe")
        let unsafeRange = value.range(of: "Unsafe")

        XCTAssertEqual(
            (rendered.attribute(.link, at: safeRange.location, effectiveRange: nil) as? URL)?
                .absoluteString,
            "https://example.com"
        )
        XCTAssertNil(
            rendered.attribute(.link, at: unsafeRange.location, effectiveRange: nil)
        )
    }
}
