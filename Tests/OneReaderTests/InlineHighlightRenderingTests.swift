#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import OneReader

@MainActor
final class InlineHighlightRenderingTests: XCTestCase {
    func testMarkdownUTF16RangeResolutionMapsOffsetsAndQuotesWhileFilteringOrphanedAndCrossFileAnnotations() throws {
        let source = """
            # Evidence Desk

            First paragraph with **highlighted evidence** in context.

            Second paragraph with repeated phrase and `inlineCode()` token.
            """
        var renderer = NativeMarkdownRenderer(fontSize: 17, lineSpacing: 5)
        let rendered = renderer.render(source)
        let sourceNSString = source as NSString
        let renderedNSString = rendered.string as NSString

        let documentLocator = Locator(
            sourceID: "source-md",
            snapshotID: "snap-1",
            adapterID: "onereader.markdown",
            payload: ["path": "docs/guide.md"]
        )

        let rawBoldPhraseRange = sourceNSString.range(of: "**highlighted evidence**")
        XCTAssertNotEqual(rawBoldPhraseRange.location, NSNotFound)

        let offsetAnnotation = Annotation(
            id: "hl-offset",
            spaceID: "space-1",
            sourceID: "source-md",
            snapshotID: "snap-1",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-md",
                snapshotID: "snap-1",
                adapterID: "onereader.markdown",
                payload: [
                    "path": "docs/guide.md",
                    "startUTF16": String(rawBoldPhraseRange.location),
                    "endUTF16": String(NSMaxRange(rawBoldPhraseRange)),
                ],
                textQuote: TextQuote(prefix: "with ", exact: "**highlighted evidence**", suffix: " in")
            ),
            anchorState: .current,
            selectedText: "highlighted evidence",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )

        let quoteOnlyAnnotation = Annotation(
            id: "hl-quote",
            spaceID: "space-1",
            sourceID: "source-md",
            snapshotID: "snap-0",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-md",
                snapshotID: "snap-1",
                adapterID: "onereader.markdown",
                payload: ["path": "docs/guide.md"],
                textQuote: TextQuote(
                    prefix: "Second paragraph with ",
                    exact: "repeated phrase",
                    suffix: " and"
                )
            ),
            anchorState: .relocated,
            selectedText: "repeated phrase",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )

        let orphanedAnnotation = Annotation(
            id: "hl-orphaned",
            spaceID: "space-1",
            sourceID: "source-md",
            snapshotID: "snap-0",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-md",
                snapshotID: "snap-0",
                adapterID: "onereader.markdown",
                payload: ["path": "docs/guide.md"],
                textQuote: TextQuote(prefix: nil, exact: "First paragraph", suffix: nil)
            ),
            anchorState: .orphaned,
            selectedText: "First paragraph",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )

        let otherFileAnnotation = Annotation(
            id: "hl-other-file",
            spaceID: "space-1",
            sourceID: "source-md",
            snapshotID: "snap-1",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-md",
                snapshotID: "snap-1",
                adapterID: "onereader.markdown",
                payload: ["path": "docs/other.md"],
                textQuote: TextQuote(prefix: nil, exact: "Evidence Desk", suffix: nil)
            ),
            anchorState: .current,
            selectedText: "Evidence Desk",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )

        let otherSourceAnnotation = Annotation(
            id: "hl-other-source",
            spaceID: "space-1",
            sourceID: "source-other",
            snapshotID: "snap-1",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-other",
                snapshotID: "snap-1",
                adapterID: "onereader.markdown",
                payload: ["path": "docs/guide.md"],
                textQuote: TextQuote(prefix: nil, exact: "Evidence Desk", suffix: nil)
            ),
            anchorState: .current,
            selectedText: "Evidence Desk",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )

        let ranges = InlineHighlightSupport.resolvedUTF16Ranges(
            for: [
                offsetAnnotation,
                quoteOnlyAnnotation,
                orphanedAnnotation,
                otherFileAnnotation,
                otherSourceAnnotation,
            ],
            documentLocator: documentLocator,
            renderedString: rendered,
            isMarkdown: true
        )

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(
            ranges.map { renderedNSString.substring(with: $0) },
            ["highlighted evidence", "repeated phrase"]
        )
    }

    func testPlainTextAndCodeHighlightResolutionAndAttributeRestoration() throws {
        let code = """
            func computeEvidenceScore(items: [String]) -> Int {
                let valid = items.filter { !$0.isEmpty }
                return valid.count
            }
            """
        let codeNSString = code as NSString
        let baseAttributed = NSAttributedString(string: code)
        let storage = NSMutableAttributedString(attributedString: baseAttributed)
        let documentLocator = Locator(
            sourceID: "source-code",
            snapshotID: "snap-code",
            adapterID: "onereader.code",
            payload: ["path": "Sources/Score.swift"]
        )

        let filterRange = codeNSString.range(of: "items.filter { !$0.isEmpty }")
        let offsetHighlight = Annotation(
            id: "code-offset",
            spaceID: "space-1",
            sourceID: "source-code",
            snapshotID: "snap-code",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-code",
                snapshotID: "snap-code",
                adapterID: "onereader.code",
                payload: [
                    "path": "Sources/Score.swift",
                    "startUTF16": String(filterRange.location),
                    "endUTF16": String(NSMaxRange(filterRange)),
                ]
            ),
            anchorState: .current,
            selectedText: "items.filter { !$0.isEmpty }",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )

        let lineHighlight = Annotation(
            id: "code-line",
            spaceID: "space-1",
            sourceID: "source-code",
            snapshotID: "snap-code",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-code",
                snapshotID: "snap-code",
                adapterID: "onereader.code",
                payload: [
                    "path": "Sources/Score.swift",
                    "startLine": "3",
                    "endLine": "3",
                ]
            ),
            anchorState: .current,
            selectedText: "    return valid.count",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )

        let resolved = InlineHighlightSupport.resolvedUTF16Ranges(
            for: [offsetHighlight, lineHighlight],
            documentLocator: documentLocator,
            renderedString: baseAttributed,
            isMarkdown: false
        )
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(
            resolved.map { codeNSString.substring(with: $0) },
            ["items.filter { !$0.isEmpty }", "    return valid.count"]
        )

        let applied = InlineHighlightSupport.applyNativeHighlights(
            for: [offsetHighlight],
            documentLocator: documentLocator,
            isMarkdown: false,
            baseAttributedString: baseAttributed,
            to: storage,
            previousRanges: []
        )
        XCTAssertEqual(applied, [filterRange])
        XCTAssertNotNil(
            storage.attribute(.backgroundColor, at: filterRange.location, effectiveRange: nil)
        )

        let cleared = InlineHighlightSupport.applyNativeHighlights(
            for: [],
            documentLocator: documentLocator,
            isMarkdown: false,
            baseAttributedString: baseAttributed,
            to: storage,
            previousRanges: applied
        )
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertNil(
            storage.attribute(.backgroundColor, at: filterRange.location, effectiveRange: nil)
        )
    }

    func testWebHighlightJavaScriptSafelyEncodesUntrustedQuotesWithoutJSInjection() throws {
        let locator = Locator(
            sourceID: "source-web",
            snapshotID: "snap-web",
            adapterID: "onereader.web",
            payload: ["href": "chapter1.xhtml"]
        )
        let maliciousQuote = "</script><script>alert(\"xss\")</script>\n\"quoted\" & 'single' \u{2028}"
        let validAnnotation = Annotation(
            id: "web-hl-1",
            spaceID: "space-1",
            sourceID: "source-web",
            snapshotID: "snap-web",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-web",
                snapshotID: "snap-web",
                adapterID: "onereader.web",
                payload: [
                    "href": "chapter1.xhtml",
                    "domPath": "body > p:nth-of-type(2)",
                ],
                textQuote: TextQuote(prefix: nil, exact: maliciousQuote, suffix: nil)
            ),
            anchorState: .current,
            selectedText: maliciousQuote,
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )
        let orphanedAnnotation = Annotation(
            id: "web-hl-orphaned",
            spaceID: "space-1",
            sourceID: "source-web",
            snapshotID: "snap-web",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-web",
                snapshotID: "snap-web",
                adapterID: "onereader.web",
                payload: ["href": "chapter1.xhtml"],
                textQuote: TextQuote(prefix: nil, exact: "should-not-appear", suffix: nil)
            ),
            anchorState: .orphaned,
            selectedText: "should-not-appear",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )

        let descriptors = InlineHighlightSupport.webHighlightDescriptors(
            for: [validAnnotation, orphanedAnnotation],
            documentLocator: locator
        )
        XCTAssertEqual(descriptors, [
            WebHighlightDescriptor(
                id: "web-hl-1",
                quote: maliciousQuote.trimmingCharacters(in: .whitespacesAndNewlines),
                domPath: "body > p:nth-of-type(2)"
            ),
        ])

        let script = InlineHighlightSupport.webHighlightJavaScript(
            for: [validAnnotation, orphanedAnnotation],
            documentLocator: locator
        )
        XCTAssertTrue(script.hasPrefix("(() => {"))
        XCTAssertTrue(script.hasSuffix("})();"))
        XCTAssertFalse(script.contains("<script>"))
        XCTAssertFalse(script.contains("</script>"))
        XCTAssertFalse(script.contains("should-not-appear"))
        XCTAssertTrue(script.contains("\\u003cscript\\u003e"))
        XCTAssertTrue(script.contains("mark[data-onereader-highlight]"))
    }

    func testPDFHighlightResolutionAndTemporaryPDFAnnotations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OneReader-InlinePDFHighlights-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("sample.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 300)
        let consumer = try XCTUnwrap(CGDataConsumer(url: pdfURL as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: "Verifiable PDF inline highlight",
                attributes: [.font: PlatformHighlightColor.self == NSColor.self ? NSFont.systemFont(ofSize: 20) : NSFont.systemFont(ofSize: 20)]
            )
        )
        context.textPosition = CGPoint(x: 30, y: 200)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()

        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        let page = try XCTUnwrap(document.page(at: 0))

        let nativeAnnotation = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
            forType: .square,
            withProperties: nil
        )
        nativeAnnotation.userName = "ExternalAuthor"
        page.addAnnotation(nativeAnnotation)

        let highlightAnnotation = Annotation(
            id: "pdf-hl-1",
            spaceID: "space-1",
            sourceID: "source-pdf",
            snapshotID: "snap-pdf",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-pdf",
                snapshotID: "snap-pdf",
                adapterID: PDFAdapter.id,
                payload: [
                    "pageIndex": "0",
                    "rect": "30.0,190.0,220.0,30.0",
                ],
                textQuote: TextQuote(
                    prefix: nil,
                    exact: "Verifiable PDF inline highlight",
                    suffix: nil
                )
            ),
            anchorState: .current,
            selectedText: "Verifiable PDF inline highlight",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )

        let selections = InlineHighlightSupport.resolvedPDFSelections(
            for: [highlightAnnotation],
            in: document,
            sourceID: "source-pdf"
        )
        XCTAssertFalse(selections.isEmpty)

        InlineHighlightSupport.applyPDFHighlights(
            [highlightAnnotation],
            to: document,
            sourceID: "source-pdf"
        )
        XCTAssertTrue(
            page.annotations.contains { $0.userName == InlineHighlightSupport.pdfAnnotationUserName }
        )
        XCTAssertTrue(
            page.annotations.contains { $0.userName == "ExternalAuthor" }
        )

        InlineHighlightSupport.applyPDFHighlights(
            [],
            to: document,
            sourceID: "source-pdf"
        )
        XCTAssertFalse(
            page.annotations.contains { $0.userName == InlineHighlightSupport.pdfAnnotationUserName }
        )
        XCTAssertTrue(
            page.annotations.contains { $0.userName == "ExternalAuthor" }
        )
    }

    func testAppModelCurrentSourceHighlightsFiltersOrphanedAndOtherSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OneReader-AppModelHighlights-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "OneReaderTests.Highlights.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library"),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }
        let database = try XCTUnwrap(model.database)
        let library = try XCTUnwrap(model.managedLibrary)

        let urlA = root.appendingPathComponent("a.md")
        let urlB = root.appendingPathComponent("b.md")
        try Data("Selected A content".utf8).write(to: urlA)
        try Data("Selected B content".utf8).write(to: urlB)

        let importedA = try await library.importLocalSource(at: urlA)
        let importedB = try await library.importLocalSource(
            at: urlB,
            intoSpaceID: importedA.space.id
        )
        let space = importedA.space
        let sourceA = importedA.source
        let sourceB = importedB.source
        let snapshotA = importedA.snapshot
        let snapshotB = importedB.snapshot

        let baseLocatorA = Locator(
            sourceID: sourceA.id,
            snapshotID: snapshotA.id,
            adapterID: "onereader.markdown",
            payload: ["startUTF16": "0", "endUTF16": "10"],
            textQuote: TextQuote(prefix: nil, exact: "Selected A", suffix: nil)
        )
        let baseLocatorB = Locator(
            sourceID: sourceB.id,
            snapshotID: snapshotB.id,
            adapterID: "onereader.markdown",
            payload: ["startUTF16": "0", "endUTF16": "10"],
            textQuote: TextQuote(prefix: nil, exact: "Selected B", suffix: nil)
        )

        let currentHighlightA = Annotation(
            id: "ann-current-a",
            spaceID: space.id,
            sourceID: sourceA.id,
            snapshotID: snapshotA.id,
            kind: .highlight,
            locator: baseLocatorA,
            anchorState: .current,
            selectedText: "Selected A",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )
        let relocatedHighlightA = Annotation(
            id: "ann-relocated-a",
            spaceID: space.id,
            sourceID: sourceA.id,
            snapshotID: snapshotA.id,
            kind: .highlight,
            locator: baseLocatorA,
            anchorState: .relocated,
            selectedText: "Relocated A",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )
        let orphanedHighlightA = Annotation(
            id: "ann-orphaned-a",
            spaceID: space.id,
            sourceID: sourceA.id,
            snapshotID: snapshotA.id,
            kind: .highlight,
            locator: baseLocatorA,
            anchorState: .orphaned,
            selectedText: "Orphaned A",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )
        let bookmarkOnlyA = Annotation(
            id: "ann-bookmark-a",
            spaceID: space.id,
            sourceID: sourceA.id,
            snapshotID: snapshotA.id,
            kind: .bookmark,
            locator: baseLocatorA,
            anchorState: .current,
            selectedText: nil,
            note: nil,
            color: nil,
            createdAt: .now,
            updatedAt: .now
        )
        let highlightB = Annotation(
            id: "ann-current-b",
            spaceID: space.id,
            sourceID: sourceB.id,
            snapshotID: snapshotB.id,
            kind: .highlight,
            locator: baseLocatorB,
            anchorState: .current,
            selectedText: "Selected B",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )

        for annotation in [
            currentHighlightA,
            relocatedHighlightA,
            orphanedHighlightA,
            bookmarkOnlyA,
            highlightB,
        ] {
            try database.saveAnnotation(annotation)
        }

        try model.reloadLibraryState()
        model.selectedSpaceID = space.id
        model.selectedSourceID = sourceA.id
        model.loadAnnotations()

        let activeIDs = Set(model.currentSourceHighlights.map(\.id))
        XCTAssertEqual(activeIDs, ["ann-current-a", "ann-relocated-a"])

        model.selectedSourceID = sourceB.id
        XCTAssertEqual(model.currentSourceHighlights.map(\.id), ["ann-current-b"])
    }

    func testCrossSnapshotHighlightsNeverReuseStaleUTF16OffsetsOrLineRanges() throws {
        let oldSource = "Target phrase at top.\n"
        let newSource = "Inserted preface line that shifts offsets.\n\nTarget phrase at top.\n"
        let oldNSString = oldSource as NSString
        let oldPhraseRange = oldNSString.range(of: "Target phrase at top.")
        XCTAssertNotEqual(oldPhraseRange.location, NSNotFound)

        var renderer = NativeMarkdownRenderer(fontSize: 17, lineSpacing: 5)
        let newRenderedMarkdown = renderer.render(newSource)
        let newRenderedNSString = newRenderedMarkdown.string as NSString

        let newDocumentLocator = Locator(
            sourceID: "source-refresh",
            snapshotID: "snap-2",
            adapterID: "onereader.markdown",
            payload: ["path": "docs/refreshed.md"]
        )

        // 1. Unmigrated (.current) annotation from snap-1 must NOT apply its old offset to snap-2
        let unmigratedOldOffsetAnnotation = Annotation(
            id: "hl-unmigrated-old-offset",
            spaceID: "space-1",
            sourceID: "source-refresh",
            snapshotID: "snap-1",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-refresh",
                snapshotID: "snap-1",
                adapterID: "onereader.markdown",
                payload: [
                    "path": "docs/refreshed.md",
                    "startUTF16": String(oldPhraseRange.location),
                    "endUTF16": String(NSMaxRange(oldPhraseRange)),
                ]
            ),
            anchorState: .current,
            selectedText: nil,
            note: "Offset-only old snapshot",
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )

        // 2. Relocated (.relocated) annotation from snap-1 still carries snap-1's startUTF16/endUTF16,
        //    so it must ignore the stale offset and resolve strictly by quote in snap-2.
        let relocatedShiftedAnnotation = Annotation(
            id: "hl-relocated-shifted",
            spaceID: "space-1",
            sourceID: "source-refresh",
            snapshotID: "snap-1",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-refresh",
                snapshotID: "snap-1",
                adapterID: "onereader.markdown",
                payload: [
                    "path": "docs/refreshed.md",
                    "startUTF16": String(oldPhraseRange.location),
                    "endUTF16": String(NSMaxRange(oldPhraseRange)),
                    "startLine": "1",
                    "endLine": "1",
                ],
                textQuote: TextQuote(prefix: nil, exact: "Target phrase at top.", suffix: nil)
            ),
            anchorState: .relocated,
            selectedText: "Target phrase at top.",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )

        let markdownRanges = InlineHighlightSupport.resolvedUTF16Ranges(
            for: [unmigratedOldOffsetAnnotation, relocatedShiftedAnnotation],
            documentLocator: newDocumentLocator,
            renderedString: newRenderedMarkdown,
            isMarkdown: true
        )
        XCTAssertEqual(markdownRanges.count, 1)
        XCTAssertEqual(
            markdownRanges.map { newRenderedNSString.substring(with: $0) },
            ["Target phrase at top."]
        )

        let plainRanges = InlineHighlightSupport.resolvedUTF16Ranges(
            for: [unmigratedOldOffsetAnnotation, relocatedShiftedAnnotation],
            documentLocator: newDocumentLocator,
            renderedString: NSAttributedString(string: newSource),
            isMarkdown: false
        )
        XCTAssertEqual(plainRanges.count, 1)
        XCTAssertEqual(
            plainRanges.map { (newSource as NSString).substring(with: $0) },
            ["Target phrase at top."]
        )
    }

    func testCrossSnapshotPDFHighlightsNeverReuseStaleRectangles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OneReader-CrossSnapshotPDF-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("refreshed.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 300)
        let consumer = try XCTUnwrap(CGDataConsumer(url: pdfURL as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: "Completely new PDF revision text",
                attributes: [.font: PlatformHighlightColor.self == NSColor.self ? NSFont.systemFont(ofSize: 20) : NSFont.systemFont(ofSize: 20)]
            )
        )
        context.textPosition = CGPoint(x: 30, y: 200)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()

        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        let page = try XCTUnwrap(document.page(at: 0))

        let staleRectFromOldSnapshot = Annotation(
            id: "pdf-stale-rect",
            spaceID: "space-1",
            sourceID: "source-pdf",
            snapshotID: "snap-pdf-1",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-pdf",
                snapshotID: "snap-pdf-1",
                adapterID: PDFAdapter.id,
                payload: [
                    "pageIndex": "0",
                    "rect": "30.0,190.0,220.0,30.0",
                ],
                textQuote: TextQuote(
                    prefix: nil,
                    exact: "Old snapshot text that was replaced",
                    suffix: nil
                )
            ),
            anchorState: .relocated,
            selectedText: "Old snapshot text that was replaced",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )

        let unmigratedOldSnapshot = Annotation(
            id: "pdf-unmigrated-old",
            spaceID: "space-1",
            sourceID: "source-pdf",
            snapshotID: "snap-pdf-1",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-pdf",
                snapshotID: "snap-pdf-1",
                adapterID: PDFAdapter.id,
                payload: [
                    "pageIndex": "0",
                    "rect": "30.0,190.0,220.0,30.0",
                ]
            ),
            anchorState: .current,
            selectedText: nil,
            note: "Rect only on old snapshot",
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )

        let newDocumentLocator = Locator(
            sourceID: "source-pdf",
            snapshotID: "snap-pdf-2",
            adapterID: PDFAdapter.id,
            payload: ["pageIndex": "0"]
        )

        let selections = InlineHighlightSupport.resolvedPDFSelections(
            for: [staleRectFromOldSnapshot, unmigratedOldSnapshot],
            in: document,
            documentLocator: newDocumentLocator
        )
        XCTAssertTrue(selections.isEmpty)

        InlineHighlightSupport.applyPDFHighlights(
            [staleRectFromOldSnapshot, unmigratedOldSnapshot],
            to: document,
            documentLocator: newDocumentLocator
        )
        XCTAssertFalse(
            page.annotations.contains { $0.userName == InlineHighlightSupport.pdfAnnotationUserName }
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
