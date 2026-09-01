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

    func testSourceMapDistinguishesRepeatedHeadingEmphasisAndListText() throws {
        let source = """
            # same

            same **same**

            - same
            """
        var renderer = NativeMarkdownRenderer(fontSize: 17, lineSpacing: 5)
        let rendered = renderer.render(source)
        let sourceValue = source as NSString
        var sourceRanges: [NSRange] = []
        var cursor = 0
        while cursor < sourceValue.length {
            let match = sourceValue.range(
                of: "same",
                options: [],
                range: NSRange(location: cursor, length: sourceValue.length - cursor)
            )
            guard match.location != NSNotFound else { break }
            sourceRanges.append(match)
            cursor = NSMaxRange(match)
        }
        XCTAssertEqual(sourceRanges.count, 4)

        let renderedRanges = try sourceRanges.map { sourceRange in
            try XCTUnwrap(
                MarkdownSourceMap.renderedRange(
                    forSourceRange: sourceRange,
                    in: rendered
                )
            )
        }
        XCTAssertEqual(renderedRanges.map { (rendered.string as NSString).substring(with: $0) }, [
            "same", "same", "same", "same",
        ])
        XCTAssertEqual(renderedRanges.map(\.location), renderedRanges.map(\.location).sorted())
        XCTAssertEqual(Set(renderedRanges.map(\.location)).count, 4)

        for (sourceRange, renderedRange) in zip(sourceRanges, renderedRanges) {
            XCTAssertEqual(
                MarkdownSourceMap.sourceRange(
                    forRenderedRange: renderedRange,
                    in: rendered
                ),
                sourceRange
            )
        }

        let emphasizedSourceRange = NSRange(
            location: sourceRanges[2].location - 2,
            length: sourceRanges[2].length + 4
        )
        XCTAssertEqual(
            MarkdownSourceMap.renderedRange(
                forSourceRange: emphasizedSourceRange,
                in: rendered
            ),
            renderedRanges[2]
        )
    }

    func testSourceMapUsesASTRangesAndExcludesHiddenMarkdownSyntax() throws {
        let source = """
            中文 [label](same) same &amp; \\*

            <div>
            same
            </div>

            final same
            """
        var renderer = NativeMarkdownRenderer(fontSize: 17, lineSpacing: 5)
        let rendered = renderer.render(source)
        let sourceValue = source as NSString
        let renderedValue = rendered.string as NSString
        let sameRanges = ranges(of: "same", in: sourceValue)
        XCTAssertEqual(sameRanges.count, 4)

        XCTAssertNil(MarkdownSourceMap.renderedRange(
            forSourceRange: sameRanges[0],
            in: rendered
        ), "A link destination is syntax, not visible text")
        XCTAssertNil(MarkdownSourceMap.renderedRange(
            forSourceRange: sameRanges[2],
            in: rendered
        ), "Raw HTML blocks are intentionally omitted from the native surface")

        for sourceRange in [sameRanges[1], sameRanges[3]] {
            let renderedRange = try XCTUnwrap(MarkdownSourceMap.renderedRange(
                forSourceRange: sourceRange,
                in: rendered
            ))
            XCTAssertEqual(renderedValue.substring(with: renderedRange), "same")
            XCTAssertEqual(
                MarkdownSourceMap.sourceRange(
                    forRenderedRange: renderedRange,
                    in: rendered
                ),
                sourceRange
            )
        }

        let entityRange = sourceValue.range(of: "&amp;")
        let renderedEntity = try XCTUnwrap(MarkdownSourceMap.renderedRange(
            forSourceRange: entityRange,
            in: rendered
        ))
        XCTAssertEqual(renderedValue.substring(with: renderedEntity), "&")
        XCTAssertEqual(
            MarkdownSourceMap.sourceRange(forRenderedRange: renderedEntity, in: rendered),
            entityRange
        )

        let escapedRange = sourceValue.range(of: "\\*")
        let renderedEscape = try XCTUnwrap(MarkdownSourceMap.renderedRange(
            forSourceRange: escapedRange,
            in: rendered
        ))
        XCTAssertEqual(renderedValue.substring(with: renderedEscape), "*")
        XCTAssertEqual(
            MarkdownSourceMap.sourceRange(forRenderedRange: renderedEscape, in: rendered),
            escapedRange
        )
    }

    private func ranges(of needle: String, in value: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var cursor = 0
        while cursor < value.length {
            let range = value.range(
                of: needle,
                options: [],
                range: NSRange(location: cursor, length: value.length - cursor)
            )
            guard range.location != NSNotFound else { break }
            result.append(range)
            cursor = NSMaxRange(range)
        }
        return result
    }
}
