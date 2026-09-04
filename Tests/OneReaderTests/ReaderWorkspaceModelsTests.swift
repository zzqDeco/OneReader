import XCTest
@testable import OneReader

@MainActor
final class ReaderWorkspaceModelsTests: XCTestCase {
    func testReaderViewportSizingAcceptsOnlyFiniteTwoDimensionalViewport() {
        XCTAssertEqual(
            ReaderViewportSizing.finiteSize(width: 390, height: 720),
            CGSize(width: 390, height: 720)
        )
        XCTAssertNil(ReaderViewportSizing.finiteSize(width: nil, height: 720))
        XCTAssertNil(ReaderViewportSizing.finiteSize(width: 390, height: nil))
        XCTAssertNil(ReaderViewportSizing.finiteSize(width: .infinity, height: 720))
        XCTAssertNil(ReaderViewportSizing.finiteSize(width: 390, height: .infinity))
        XCTAssertNil(ReaderViewportSizing.finiteSize(width: 0, height: 720))
        XCTAssertNil(ReaderViewportSizing.finiteSize(width: 390, height: 0))
    }

    func testReaderNavigationKeepsReadableDocumentsInsideAssetDirectories() {
        let readme = node(
            path: "assets/README.md",
            mediaType: "text/markdown",
            isReadable: true
        )
        let image = node(
            path: "assets/cover.png",
            mediaType: "image/png",
            isReadable: true
        )
        let font = node(
            path: "fonts/reader.woff2",
            mediaType: "font/woff2",
            isReadable: true
        )
        let directory = node(
            path: "assets",
            mediaType: "text/x-directory",
            isReadable: false,
            kind: .directory
        )

        XCTAssertEqual(
            ReaderContentNavigation.outlineNodes(from: [directory, readme, image, font]),
            [directory, readme]
        )
        XCTAssertEqual(
            ReaderContentNavigation.readableNodes(from: [directory, readme, image, font]),
            [readme]
        )
    }

    func testRevealReaderNavigationChangesTabAndPublishesARevealRequest() {
        let model = AppModel(automaticBootstrap: false)
        let initialRequest = model.readerNavigationRequestID

        model.revealReaderNavigation(.search)

        XCTAssertEqual(model.navigationTab, .search)
        XCTAssertNotEqual(model.readerNavigationRequestID, initialRequest)
    }

    func testNavigationMatchesDirectoryPDFByPathBeforePageFallback() throws {
        let introduction = node(
            path: "00-introduction.md",
            mediaType: "text/markdown",
            isReadable: true
        )
        let pdf = node(
            path: "assets/book.pdf",
            mediaType: "application/pdf",
            isReadable: true
        )
        let appendix = node(
            path: "99-appendix.md",
            mediaType: "text/markdown",
            isReadable: true
        )
        let activePDFPage = Locator(
            sourceID: "source",
            snapshotID: "snapshot",
            adapterID: "adapter",
            payload: ["path": "assets/book.pdf", "pageIndex": "9"],
            structuralPath: "assets/book.pdf::page/9"
        )
        let readable = [introduction, pdf, appendix]

        XCTAssertEqual(
            ReaderContentNavigation.index(of: activePDFPage, in: readable),
            1
        )
        let availability = ReaderContentNavigation.availability(
            at: activePDFPage,
            in: readable
        )
        XCTAssertTrue(availability.previous)
        XCTAssertTrue(availability.next)
    }

    func testNavigationMatchesDirectPDFByCurrentPage() {
        let pages = (0..<3).map { pageIndex in
            let locator = Locator(
                sourceID: "source",
                snapshotID: "snapshot",
                adapterID: "adapter",
                payload: ["pageIndex": String(pageIndex)],
                structuralPath: "page/\(pageIndex)"
            )
            return ContentNode(
                id: locator.stableID,
                title: "第 \(pageIndex + 1) 页",
                kind: .page,
                locator: locator,
                depth: 0,
                order: pageIndex,
                mediaType: "application/pdf",
                isReadable: true
            )
        }
        var activePayload = pages[1].locator.payload
        activePayload["rectX"] = "12"
        let active = Locator(
            sourceID: "source",
            snapshotID: "snapshot",
            adapterID: "adapter",
            payload: activePayload,
            structuralPath: "page/1",
            textQuote: TextQuote(prefix: nil, exact: "current page", suffix: nil)
        )

        XCTAssertEqual(ReaderContentNavigation.index(of: active, in: pages), 1)
        XCTAssertEqual(
            ReaderContentNavigation.availability(at: active, in: pages).next,
            true
        )
    }

    func testNavigationDisablesBothDirectionsWithoutAResolvableTarget() {
        let only = node(path: "README.md", mediaType: "text/markdown", isReadable: true)
        let missing = Locator(
            sourceID: "source",
            snapshotID: "snapshot",
            adapterID: "adapter",
            payload: ["path": "missing.md"]
        )

        let unavailable = ReaderContentNavigation.availability(at: missing, in: [only])
        XCTAssertFalse(unavailable.previous)
        XCTAssertFalse(unavailable.next)

        let single = ReaderContentNavigation.availability(at: only.locator, in: [only])
        XCTAssertFalse(single.previous)
        XCTAssertFalse(single.next)
    }

    func testNavigationUsesCurrentMarkdownLineAheadOfStaleHeadingPath() {
        let sections = [
            section(path: "book.md", title: "One", anchor: "one", startLine: 1),
            section(path: "book.md", title: "Two", anchor: "two", startLine: 20),
            section(path: "book.md", title: "Three", anchor: "three", startLine: 40),
        ]
        let active = Locator(
            sourceID: "source",
            snapshotID: "snapshot",
            adapterID: "adapter",
            payload: ["path": "book.md", "startLine": "44"],
            structuralPath: "one",
            textQuote: TextQuote(prefix: nil, exact: "body", suffix: nil)
        )

        XCTAssertEqual(ReaderContentNavigation.index(of: active, in: sections), 2)
        let availability = ReaderContentNavigation.availability(at: active, in: sections)
        XCTAssertTrue(availability.previous)
        XCTAssertFalse(availability.next)
    }

    func testNavigationMapsTextPositionToNearestPrecedingHeading() {
        let sections = [
            section(path: "book.md", title: "One", anchor: "one", startLine: 1),
            section(path: "book.md", title: "Two", anchor: "two", startLine: 20),
            section(path: "book.md", title: "Three", anchor: "three", startLine: 40),
        ]
        let active = Locator(
            sourceID: "source",
            snapshotID: "snapshot",
            adapterID: "adapter",
            payload: ["path": "book.md", "startLine": "28"],
            structuralPath: "book.md"
        )

        XCTAssertEqual(ReaderContentNavigation.index(of: active, in: sections), 1)
        XCTAssertEqual(
            ReaderContentNavigation.availability(at: active, in: sections).next,
            true
        )
    }

    func testNavigationUsesHTMLDOMAnchorInsteadOfFirstSharedPath() {
        let first = section(
            path: "chapter.html",
            title: "First",
            anchor: "body > h2:nth-of-type(1)",
            startLine: nil,
            domPath: "body > h2:nth-of-type(1)"
        )
        let second = section(
            path: "chapter.html",
            title: "Second",
            anchor: "body > h2:nth-of-type(2)",
            startLine: nil,
            domPath: "body > h2:nth-of-type(2)"
        )
        let active = Locator(
            sourceID: "source",
            snapshotID: "snapshot",
            adapterID: "adapter",
            payload: [
                "path": "chapter.html",
                "domPath": "body > p:nth-of-type(9)",
                "outlineDOMPath": "body > h2:nth-of-type(2)",
                "scrollFraction": "0.8",
            ],
            structuralPath: "body > p:nth-of-type(9)",
            textQuote: TextQuote(prefix: nil, exact: "visible paragraph", suffix: nil)
        )

        XCTAssertEqual(ReaderContentNavigation.index(of: active, in: [first, second]), 1)
        XCTAssertFalse(
            ReaderContentNavigation.availability(at: active, in: [first, second]).next
        )
    }

    func testWebPositionCaptureUsesImmediateHostFractionAndRetainsEvidence() throws {
        let base = Locator(
            sourceID: "source",
            snapshotID: "snapshot",
            adapterID: "onereader.html",
            payload: ["path": "chapter.html", "domPath": "body > p:nth-of-type(1)"],
            structuralPath: "body > p:nth-of-type(1)",
            textQuote: TextQuote(prefix: nil, exact: "earlier paragraph", suffix: nil),
            fingerprint: "earlier-fingerprint"
        )
        let update = WebReadingPositionCapture.update(
            for: base,
            path: "body > p:nth-of-type(7)",
            outlinePath: "body > h2:nth-of-type(3)",
            quote: "current paragraph",
            fraction: 0.73456789
        )

        XCTAssertEqual(update.progressFraction, 0.73456789)
        XCTAssertEqual(update.granularity, .dom)
        XCTAssertEqual(update.locator.payload["scrollFraction"], "0.734568")
        XCTAssertEqual(update.locator.payload["domPath"], "body > p:nth-of-type(7)")
        XCTAssertEqual(
            update.locator.payload["outlineDOMPath"],
            "body > h2:nth-of-type(3)"
        )
        XCTAssertEqual(update.locator.textQuote?.exact, "current paragraph")
        XCTAssertEqual(
            update.locator.fingerprint,
            AdapterUtilities.sha256("current paragraph")
        )
    }

    func testWebPositionCaptureNormalizesHostScrollGeometry() throws {
        XCTAssertEqual(
            try XCTUnwrap(WebReadingPositionCapture.normalizedScrollFraction(
                offset: 600,
                contentExtent: 1_000,
                viewportExtent: 200
            )),
            0.75,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            WebReadingPositionCapture.normalizedScrollFraction(
                offset: -20,
                contentExtent: 1_000,
                viewportExtent: 200
            ),
            0
        )
        XCTAssertNil(WebReadingPositionCapture.normalizedScrollFraction(
            offset: .nan,
            contentExtent: 1_000,
            viewportExtent: 200
        ))
    }

    func testWebFractionOnlyFallbackDropsStaleDOMEvidence() throws {
        let base = Locator(
            sourceID: "source",
            snapshotID: "snapshot",
            adapterID: "onereader.html",
            payload: [
                "path": "chapter.html",
                "domPath": "body > p:nth-of-type(1)",
                "outlineDOMPath": "body > h2:nth-of-type(1)",
            ],
            structuralPath: "body > p:nth-of-type(1)",
            textQuote: TextQuote(prefix: nil, exact: "stale paragraph", suffix: nil),
            fingerprint: "stale-fingerprint"
        )

        let update = WebReadingPositionCapture.fractionOnlyUpdate(
            for: base,
            fraction: 0.82
        )

        XCTAssertEqual(update.locator.relativePath, "chapter.html")
        XCTAssertEqual(update.locator.structuralPath, "chapter.html")
        XCTAssertNil(update.locator.payload["domPath"])
        XCTAssertNil(update.locator.payload["outlineDOMPath"])
        XCTAssertNil(update.locator.textQuote)
        XCTAssertNil(update.locator.fingerprint)
        XCTAssertEqual(update.locator.payload["scrollFraction"], "0.820000")
    }

    func testReadingPositionCaptureClaimIsExclusiveAndTargetBound() {
        let targetID = UUID()
        let locator = Locator(
            sourceID: "source",
            snapshotID: "snapshot",
            adapterID: "onereader.html",
            payload: ["path": "chapter.html"],
            structuralPath: "chapter.html"
        )
        var didFinish = false
        let request = ReadingPositionCaptureRequest(
            targetID: targetID,
            sourceID: locator.sourceID,
            snapshotID: locator.snapshotID
        ) { _ in
            didFinish = true
        }
        let wrongLocator = Locator(
            sourceID: "another-source",
            snapshotID: locator.snapshotID,
            adapterID: locator.adapterID,
            payload: locator.payload,
            structuralPath: locator.structuralPath
        )

        XCTAssertFalse(request.claim(targetID: UUID(), locator: locator))
        XCTAssertFalse(request.claim(targetID: targetID, locator: wrongLocator))
        XCTAssertTrue(request.claim(targetID: targetID, locator: locator))
        XCTAssertFalse(request.claim(targetID: targetID, locator: locator))

        request.finish(with: nil, targetID: UUID())
        XCTAssertFalse(didFinish)
        request.finish(with: nil, targetID: targetID)
        XCTAssertTrue(didFinish)
    }

    private func node(
        path: String,
        mediaType: String,
        isReadable: Bool,
        kind: ContentNodeKind = .file
    ) -> ContentNode {
        let locator = Locator(
            sourceID: "source",
            snapshotID: "snapshot",
            adapterID: "adapter",
            payload: ["path": path],
            structuralPath: path
        )
        return ContentNode(
            id: locator.stableID,
            title: (path as NSString).lastPathComponent,
            kind: kind,
            locator: locator,
            depth: max(0, path.split(separator: "/").count - 1),
            order: 0,
            mediaType: mediaType,
            isReadable: isReadable
        )
    }

    private func section(
        path: String,
        title: String,
        anchor: String,
        startLine: Int?,
        domPath: String? = nil
    ) -> ContentNode {
        var payload = ["path": path]
        if let startLine { payload["startLine"] = String(startLine) }
        if let domPath { payload["domPath"] = domPath }
        let locator = Locator(
            sourceID: "source",
            snapshotID: "snapshot",
            adapterID: "adapter",
            payload: payload,
            structuralPath: anchor,
            textQuote: TextQuote(prefix: nil, exact: title, suffix: nil),
            fingerprint: AdapterUtilities.sha256(title)
        )
        return ContentNode(
            id: locator.stableID,
            title: title,
            kind: .section,
            locator: locator,
            depth: 0,
            order: startLine ?? 0,
            mediaType: domPath == nil ? "text/markdown" : "text/html",
            isReadable: true
        )
    }
}
