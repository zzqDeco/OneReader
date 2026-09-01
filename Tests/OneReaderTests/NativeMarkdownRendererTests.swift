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

    func testSourceMapExcludesFenceAndRepeatedLanguageInfoFromCodeBlock() throws {
        let source = """
            ```swift
            let swift = "swift"
            ```
            """
        var renderer = NativeMarkdownRenderer(fontSize: 17, lineSpacing: 5)
        let rendered = renderer.render(source)
        let sourceValue = source as NSString
        let renderedValue = rendered.string as NSString
        let swiftRanges = ranges(of: "swift", in: sourceValue)
        let fenceRanges = ranges(of: "```", in: sourceValue)
        XCTAssertEqual(swiftRanges.count, 3)
        XCTAssertEqual(fenceRanges.count, 2)

        for fenceRange in fenceRanges {
            XCTAssertNil(MarkdownSourceMap.renderedRange(
                forSourceRange: fenceRange,
                in: rendered
            ), "A fenced-code delimiter is syntax, not visible code")
        }

        XCTAssertNil(MarkdownSourceMap.renderedRange(
            forSourceRange: swiftRanges[0],
            in: rendered
        ), "A fenced-code language identifier is syntax, not visible code")

        for sourceRange in swiftRanges.dropFirst() {
            let renderedRange = try XCTUnwrap(MarkdownSourceMap.renderedRange(
                forSourceRange: sourceRange,
                in: rendered
            ))
            XCTAssertEqual(renderedValue.substring(with: renderedRange), "swift")
            XCTAssertEqual(
                MarkdownSourceMap.sourceRange(
                    forRenderedRange: renderedRange,
                    in: rendered
                ),
                sourceRange
            )
        }
    }

    func testSourceMapUsesInnerLiteralForMultiBacktickInlineCode() throws {
        let source = "`` ` ``"
        var renderer = NativeMarkdownRenderer(fontSize: 17, lineSpacing: 5)
        let rendered = renderer.render(source)
        let sourceValue = source as NSString
        let openingDelimiter = NSRange(location: 0, length: 2)
        let literal = NSRange(location: 3, length: 1)
        let closingDelimiter = NSRange(location: 5, length: 2)

        XCTAssertEqual(rendered.string, "`")
        XCTAssertNil(MarkdownSourceMap.renderedRange(
            forSourceRange: openingDelimiter,
            in: rendered
        ))
        XCTAssertEqual(
            MarkdownSourceMap.renderedRange(forSourceRange: literal, in: rendered),
            NSRange(location: 0, length: 1)
        )
        XCTAssertNil(MarkdownSourceMap.renderedRange(
            forSourceRange: closingDelimiter,
            in: rendered
        ))
        XCTAssertEqual(
            MarkdownSourceMap.sourceRange(
                forRenderedRange: NSRange(location: 0, length: 1),
                in: rendered
            ),
            literal
        )
        XCTAssertEqual(sourceValue.substring(with: literal), "`")
    }

    func testNormalizedInlineCodeFailsClosedInsteadOfPartiallyMapping() throws {
        let source = "`a\nb`"
        var renderer = NativeMarkdownRenderer(fontSize: 17, lineSpacing: 5)
        let rendered = renderer.render(source)
        let fullRenderedRange = NSRange(location: 0, length: rendered.length)

        XCTAssertEqual(rendered.string, "a b")
        XCTAssertNil(MarkdownSourceMap.sourceRange(
            forRenderedRange: fullRenderedRange,
            in: rendered
        ))
        XCTAssertNil(MarkdownSourceMap.renderedRange(
            forSourceRange: NSRange(location: 1, length: 1),
            in: rendered
        ), "A leaf requiring newline normalization must not expose a partial map")
    }

    func testIndentedFenceFailsClosedInsteadOfMappingStructuralSpaces() throws {
        let source = """
              ```
               x
              ````
            """
        var renderer = NativeMarkdownRenderer(fontSize: 17, lineSpacing: 5)
        let rendered = renderer.render(source)
        let visibleCodeRange = (rendered.string as NSString).range(of: " x")

        XCTAssertNotEqual(visibleCodeRange.location, NSNotFound)
        XCTAssertNil(MarkdownSourceMap.sourceRange(
            forRenderedRange: visibleCodeRange,
            in: rendered
        ), "Fence indentation normalization must drop the entire code-leaf map")
        XCTAssertNil(MarkdownSourceMap.sourceRange(
            forRenderedRange: NSRange(location: visibleCodeRange.location, length: 1),
            in: rendered
        ), "The visible space must not anchor to fence indentation syntax")
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
