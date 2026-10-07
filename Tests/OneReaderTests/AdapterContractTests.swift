import AppKit
import CryptoKit
import Foundation
import GRDB
import PDFKit
import XCTest
import ZIPFoundation
@testable import OneReader

final class AdapterContractTests: XCTestCase {
    func testManagedMarkdownIndexCoversPreambleParagraphsAndHeadinglessFiles() async throws {
        let root = try makeTemporaryRoot(prefix: "OneReader-FullText")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: unlimitedStoragePolicy)
        let coordinator = try AdapterCoordinator.standard(database: database)
        let cases = [
            ("chapters.md", "PreambleToken\n\n# Opening\n\nParagraphToken\n\n## Nested\n\nNestedBodyToken", ["Opening", "Nested"], ["PreambleToken", "ParagraphToken", "NestedBodyToken"]),
            ("without-headings.md", "NoHeadingToken in an ordinary paragraph.", ["without-headings.md"], ["NoHeadingToken"]),
        ]
        for (name, text, titles, queries) in cases {
            let url = root.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            let imported = try await library.importLocalSource(at: url)
            let plan = try await coordinator.prepareAndIndex(
                sourceID: imported.source.id, snapshotID: imported.snapshot.id
            )
            let nodes = try await coordinator.list(plan: plan)
            XCTAssertEqual(nodes.map(\.title), titles)
            XCTAssertTrue(try database.isObservationIndexComplete(snapshotID: plan.snapshotID, planID: plan.id))
            XCTAssertEqual(try database.observationCount(snapshotID: plan.snapshotID), 0)
            for query in queries {
                let hits = try database.searchObservations(query: query, planID: plan.id)
                XCTAssertEqual(hits.count, 1, query)
                let hit = try XCTUnwrap(hits.first)
                let observation = try await coordinator.read(plan: plan, locator: hit.locator, persistObservation: false)
                XCTAssertEqual(observation.content, query)
                XCTAssertEqual(hit.locator.payload["startUTF16"], String((text as NSString).range(of: query).location))
            }
        }
    }

    func testLongMarkdownIndexesBeyondMillionCharactersAndDeduplicatesOverlap() async throws {
        let root = try makeTemporaryRoot(prefix: "OneReader-LongMarkdown")
        defer { try? FileManager.default.removeItem(at: root) }
        let chunk = TextAdapterCore.indexChunkCharacters
        var text = "# Long chapter\r\n👩🏽‍💻 e\u{301}\r"
        text += String(repeating: "x", count: chunk - text.count - 200)
        text += " overlapduplicate "
        text += String(repeating: "x", count: chunk - text.count - 7)
        text += " CrossBoundaryToken overlapneedle "
        text += String(repeating: " longline", count: 120_000)
        text += "\r\nTailBeyondMillionToken"
        XCTAssertGreaterThan(text.count, 1_000_000)
        let url = root.appendingPathComponent("long.md")
        try Data(text.utf8).write(to: url)
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: unlimitedStoragePolicy)
        let imported = try await library.importLocalSource(at: url)
        let coordinator = try AdapterCoordinator.standard(database: database)
        let plan = try await coordinator.prepareAndIndex(sourceID: imported.source.id, snapshotID: imported.snapshot.id)
        XCTAssertGreaterThan(try database.searchDocumentCount(planID: plan.id), 16)
        for query in ["CrossBoundaryToken", "overlapneedle", "overlapduplicate", "TailBeyondMillionToken"] {
            let hits = try database.searchObservations(query: query)
            XCTAssertEqual(hits.count, 1, query)
            let hit = try XCTUnwrap(hits.first)
            let expectedRange = (text as NSString).range(of: query)
            XCTAssertEqual(hit.locator.payload["startUTF16"], String(expectedRange.location))
            XCTAssertEqual(hit.locator.payload["endUTF16"], String(NSMaxRange(expectedRange)))
            XCTAssertEqual(hit.locator.lineRange, query == "TailBeyondMillionToken" ? 4...4 : 3...3)
            let read = try await coordinator.read(plan: plan, locator: hit.locator, persistObservation: false)
            XCTAssertEqual(read.content, query)
            let presentation = try await coordinator.render(plan: plan, locator: hit.locator)
            XCTAssertEqual(presentation.content, text)
        }
    }

    func testOverlapDeduplicationHappensBeforeTwentyResultLimitForFTSAndSubstring() async throws {
        let root = try makeTemporaryRoot(prefix: "OneReader-SearchDedup")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Book")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = String(repeating: "x", count: TextAdapterCore.indexChunkCharacters - 100)
            + " overlapmatch 时间管理的意义 " + String(repeating: "y", count: 200)
        for index in 0..<22 {
            try Data(text.utf8).write(to: folder.appendingPathComponent("chapter-\(index).md"))
        }
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: unlimitedStoragePolicy)
        let imported = try await library.importLocalSource(at: folder)
        let coordinator = try AdapterCoordinator.standard(database: database)
        let plan = try await coordinator.prepareAndIndex(sourceID: imported.source.id, snapshotID: imported.snapshot.id)
        XCTAssertEqual(try database.searchDocumentCount(planID: plan.id), 44)
        for query in ["overlapmatch", "时间管理"] {
            let hits = try database.searchObservations(query: query, limit: 20)
            XCTAssertEqual(hits.count, 20)
            XCTAssertEqual(Set(hits.compactMap { $0.locator.relativePath }).count, 20)
        }
    }

    func testTextChunksRoundTripUnicodeNewlinesAndKeepViewportReadSemantics() async throws {
        let text = "👩🏽‍💻 e\u{301}\r\n中文\rsecond\nthird\r\nfourth long line 👨‍👩‍👧‍👦 end"
        let fixture = try makeFileFixture(name: "unicode.txt", content: text)
        defer { fixture.remove() }
        let collector = IndexObservationCollector()
        try await TextAdapterCore.index(
            fixture.context, adapterID: PlainTextAdapter.id, mediaType: "text/plain",
            chunkCharacters: 12, overlapCharacters: 3
        ) { await collector.append($0) }
        let observations = await collector.values
        XCTAssertGreaterThan(observations.count, 3)
        for observation in observations {
            XCTAssertFalse(observation.truncated)
            XCTAssertLessThanOrEqual(observation.content.count, 12)
            let start = try XCTUnwrap(Int(observation.locator.payload["startUTF16"] ?? ""))
            let end = try XCTUnwrap(Int(observation.locator.payload["endUTF16"] ?? ""))
            let range = try XCTUnwrap(Range(NSRange(location: start, length: end - start), in: text))
            XCTAssertEqual(observation.content, String(text[range]))
            let expectedLine = text[..<range.lowerBound].reduce(1) { $1.isNewline ? $0 + 1 : $0 }
            XCTAssertEqual(observation.locator.lineRange?.lowerBound, expectedLine)
            let read = try TextAdapterCore.read(
                fixture.context, adapterID: PlainTextAdapter.id, locator: observation.locator,
                mediaType: "text/plain", maxCharacters: 100
            )
            XCTAssertEqual(read.content, observation.content)
        }
        let original = try XCTUnwrap(observations.first).locator
        var payload = original.payload
        payload["positionKind"] = "viewport"
        payload["startLine"] = "2"
        payload["endLine"] = "2"
        let viewport = replacingTestAnchor(original, payload: payload)
        let read = try TextAdapterCore.read(
            fixture.context, adapterID: PlainTextAdapter.id, locator: viewport,
            mediaType: "text/plain", maxCharacters: 100
        )
        XCTAssertEqual(read.content, "中文")
        payload["positionKind"] = nil
        payload["startUTF16"] = "1"
        let invalid = replacingTestAnchor(original, payload: payload)
        XCTAssertThrowsError(try TextAdapterCore.read(
            fixture.context, adapterID: PlainTextAdapter.id, locator: invalid,
            mediaType: "text/plain", maxCharacters: 100
        ))
    }

    func testRepeatedQuoteRelocationUsesContextThenOriginalOffsetAndRejectsTies() async throws {
        let text = "first repeated end\nsecond repeated end\nlast repeated end"
        let fixture = try makeFileFixture(name: "repeat.md", content: text)
        defer { fixture.remove() }
        let locator = Locator(
            sourceID: fixture.context.source.id, snapshotID: "old", adapterID: MarkdownAdapter.id,
            payload: ["path": "repeat.md", "indexTextRange": "utf16", "startLine": "1", "startUTF16": "0", "endUTF16": "8"],
            structuralPath: "repeat.md", textQuote: TextQuote(prefix: "second ", exact: "repeated", suffix: " end"), fingerprint: nil
        )
        let resolution = try await MarkdownAdapter().resolve(locator, in: fixture.context)
        let resolved = try XCTUnwrap(resolution.resolved)
        XCTAssertEqual(resolution.state, .relocated)
        XCTAssertEqual(resolved.lineRange, 2...2)
        XCTAssertEqual(resolved.payload["startUTF16"], String((text as NSString).range(of: "second repeated").location + 7))
        let read = try await MarkdownAdapter().readFragment(in: fixture.context, at: resolved, maxCharacters: 100)
        XCTAssertEqual(read.content, "repeated")

        var payload = locator.payload
        payload["startUTF16"] = resolved.payload["startUTF16"]
        let quote = TextQuote(prefix: nil, exact: "repeated", suffix: nil)
        let noContext = replacingTestAnchor(locator, payload: payload, quote: quote)
        let nearest = try await MarkdownAdapter().resolve(noContext, in: fixture.context)
        XCTAssertEqual(nearest.resolved?.lineRange, 2...2)
        payload["startUTF16"] = nil
        let ambiguous = try await MarkdownAdapter().resolve(
            replacingTestAnchor(locator, payload: payload, quote: quote), in: fixture.context
        )
        XCTAssertEqual(ambiguous.state, .orphaned)
    }

    func testIndexBudgetsFailCleanlyAndRetryWithoutPublishingPartialResults() async throws {
        let root = try makeTemporaryRoot(prefix: "OneReader-IndexBudget")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("budget.md")
        try Data(("# Budget\n" + String(repeating: "budgetword ", count: 14_000)).utf8).write(to: url)
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: unlimitedStoragePolicy)
        let imported = try await library.importLocalSource(at: url)
        let registry = try AdapterRegistry.standard()
        let limited = AdapterCoordinator(
            database: database, registry: registry,
            indexingPolicy: SearchIndexPolicy(maximumFragments: 1, storagePolicy: unlimitedStoragePolicy)
        )
        let plan = try await limited.prepare(sourceID: imported.source.id, snapshotID: imported.snapshot.id)
        do { try await limited.index(plan: plan); XCTFail("Must reject incomplete projection") }
        catch is AdapterError { }
        XCTAssertFalse(try database.isObservationIndexComplete(snapshotID: plan.snapshotID, planID: plan.id))
        XCTAssertEqual(try database.searchDocumentCount(planID: plan.id), 0)
        XCTAssertTrue(try database.searchObservations(query: "budgetword").isEmpty)
        let stagedCount = try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM observation_index_staging") }
        XCTAssertEqual(stagedCount, 0)
        let noSpace = AdapterCoordinator(
            database: database, registry: registry,
            indexingPolicy: SearchIndexPolicy(storagePolicy: LibraryStoragePolicy(
                largeImportThreshold: .max, minimumFreeCapacity: 2_048, capacityProvider: { _ in 1_024 }
            ))
        )
        do { try await noSpace.index(plan: plan); XCTFail("Must reject low capacity") }
        catch let error as LibraryStorageError {
            guard case .insufficientFreeSpace = error else { return XCTFail("Unexpected \(error)") }
        }
        let retry = AdapterCoordinator(database: database, registry: registry, indexingPolicy: SearchIndexPolicy(storagePolicy: unlimitedStoragePolicy))
        try await retry.index(plan: plan)
        XCTAssertTrue(try database.isObservationIndexComplete(snapshotID: plan.snapshotID, planID: plan.id))
        XCTAssertFalse(try database.searchObservations(query: "budgetword").isEmpty)
    }

    func testDirectoryIndexDetectsSentinelInsteadOfCompletingTruncatedList() async throws {
        let root = try makeTemporaryRoot(prefix: "OneReader-IndexNodeLimit")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Book")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["first.md", "second.txt", "third.swift"] {
            try Data("# Heading\n\nbody-only sentinelneedle".utf8).write(to: folder.appendingPathComponent(name))
        }
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: unlimitedStoragePolicy)
        let imported = try await library.importLocalSource(at: folder)
        let registry = try AdapterRegistry.standard()
        let limited = AdapterCoordinator(database: database, registry: registry, indexingPolicy: SearchIndexPolicy(maximumNodes: 2, storagePolicy: unlimitedStoragePolicy))
        let plan = try await limited.prepare(sourceID: imported.source.id, snapshotID: imported.snapshot.id)
        do { try await limited.index(plan: plan); XCTFail("Must detect third node") }
        catch is AdapterError { }
        XCTAssertFalse(try database.isObservationIndexComplete(snapshotID: plan.snapshotID, planID: plan.id))
        XCTAssertEqual(try database.searchDocumentCount(planID: plan.id), 0)
        let retry = AdapterCoordinator(database: database, registry: registry, indexingPolicy: SearchIndexPolicy(storagePolicy: unlimitedStoragePolicy))
        try await retry.index(plan: plan)
        let hits = try database.searchObservations(query: "sentinelneedle")
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(Set(hits.map(\.adapterID)), [MarkdownAdapter.id, PlainTextAdapter.id, CodeAdapter.id])
    }

    func testGlobalIndexGateSerializesAndCancelsQueuedWork() async throws {
        let gate = SearchIndexGate()
        try await gate.acquire()
        let cancelled = Task { try await gate.acquire() }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled waiter acquired a slot") }
        catch is CancellationError { }
        await gate.release()
        let counter = IndexConcurrencyCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await gate.acquire()
                    await counter.begin()
                    await Task.yield()
                    await counter.end()
                    await gate.release()
                }
            }
            try await group.waitForAll()
        }
        let maximum = await counter.maximum
        let completed = await counter.completed
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(completed, 12)
    }

    func testStandardRegistryContainsEveryV1BaseAdapter() async throws {
        let registry = try AdapterRegistry.standard()
        let ids = await registry.descriptors().map(\.id)

        XCTAssertEqual(
            Set(ids),
            Set([
                PDFAdapter.id,
                EPUBAdapter.id,
                MarkdownAdapter.id,
                HTMLAdapter.id,
                WebSnapshotAdapter.id,
                CodeAdapter.id,
                PlainTextAdapter.id,
                DirectoryAdapter.id,
                QuickLookAdapter.id,
            ])
        )
    }

    func testMarkdownImplementsProbeRevisionListReadSearchRenderAndResolve() async throws {
        let fixture = try makeFileFixture(
            name: "book.md",
            content: "# Opening\n\nDurable evidence.\n\n## Details\n\nMore evidence."
        )
        defer { fixture.remove() }
        let adapter = MarkdownAdapter()

        let probe = try await adapter.probe(fixture.context)
        XCTAssertEqual(probe?.adapterID, MarkdownAdapter.id)
        try await adapter.verifyRevision(in: fixture.context)
        let nodes = try await adapter.listContent(in: fixture.context, under: nil, limit: 20)
        XCTAssertEqual(nodes.map(\.title), ["Opening", "Details"])
        let observation = try await adapter.readFragment(
            in: fixture.context,
            at: nodes[0].locator,
            maxCharacters: 1_000
        )
        XCTAssertTrue(observation.content.contains("Opening"))
        XCTAssertEqual(observation.sourceID, fixture.context.source.id)
        XCTAssertEqual(observation.snapshotID, fixture.context.snapshot.id)
        let searchHits = try await adapter.searchContent(
            in: fixture.context,
            query: "evidence",
            limit: 20
        )
        XCTAssertEqual(searchHits.count, 2)
        let presentation = try await adapter.presentation(
            in: fixture.context,
            at: nodes[0].locator
        )
        XCTAssertEqual(presentation.surface, .nativeMarkdown)
        let currentResolution = try await adapter.resolve(
            nodes[0].locator,
            in: fixture.context
        )
        XCTAssertEqual(currentResolution.state, .current)

        let newer = fixture.context(replacingSnapshotID: "snapshot-new")
        let resolution = try await adapter.resolve(nodes[0].locator, in: newer)
        XCTAssertEqual(resolution.state, .relocated)
        XCTAssertEqual(resolution.resolved?.snapshotID, "snapshot-new")
    }

    func testDirectoryMarkdownPresentationKeepsSnapshotRootAndDocumentBase() async throws {
        let root = try makeTemporaryRoot(prefix: "OneReader-MarkdownResources")
        defer { try? FileManager.default.removeItem(at: root) }
        let documentDirectory = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documentDirectory,
            withIntermediateDirectories: true
        )
        let markdownURL = documentDirectory.appendingPathComponent("chapter.md")
        let content = "# Chapter\n\n![Figure](../assets/figure.png)"
        try Data(content.utf8).write(to: markdownURL)
        let source = Source(
            id: "directory-markdown-source",
            displayName: "Book",
            originKind: .localDirectory,
            originURL: root,
            managedState: .ready,
            latestSnapshotID: "directory-markdown-snapshot"
        )
        let snapshot = SourceSnapshot(
            id: "directory-markdown-snapshot",
            sourceID: source.id,
            revision: "tree-digest",
            revisionKind: .directoryTreeDigest,
            digest: "tree-digest",
            observedAt: .now,
            origin: root,
            managedRelativePath: nil,
            byteCount: Int64(content.utf8.count)
        )
        let context = AdapterContext(
            source: source,
            snapshot: snapshot,
            managedURL: markdownURL,
            contentRootURL: root,
            derivedRootURL: root.appendingPathComponent("Derived")
        )

        let presentation = try await MarkdownAdapter().presentation(
            in: context,
            at: nil
        )

        XCTAssertEqual(
            presentation.baseURL?.standardizedFileURL,
            root.standardizedFileURL
        )
        XCTAssertEqual(
            presentation.contentURL?.standardizedFileURL,
            markdownURL.standardizedFileURL
        )
    }

    func testPlainTextAndCodeUseNativeSelectablePresentations() async throws {
        let text = try makeFileFixture(name: "notes.txt", content: "plain searchable words")
        let code = try makeFileFixture(name: "Reader.swift", content: "struct Reader { let evidence = true }")
        defer {
            text.remove()
            code.remove()
        }

        let textAdapter = PlainTextAdapter()
        let codeAdapter = CodeAdapter()
        let textProbe = try await textAdapter.probe(text.context)
        let codeProbe = try await codeAdapter.probe(code.context)
        XCTAssertNotNil(textProbe)
        XCTAssertNotNil(codeProbe)
        let textPresentation = try await textAdapter.presentation(
            in: text.context,
            at: nil
        )
        let codePresentation = try await codeAdapter.presentation(
            in: code.context,
            at: nil
        )
        XCTAssertEqual(textPresentation.surface, .nativeText)
        XCTAssertEqual(codePresentation.surface, .nativeCode)
        let codeHits = try await codeAdapter.searchContent(
            in: code.context,
            query: "evidence",
            limit: 20
        )
        XCTAssertEqual(codeHits.first?.locator.lineRange, 1...1)
    }

    func testTextLoadingRejectsBytesBeyondConfiguredBound() throws {
        let root = try makeTemporaryRoot(prefix: "OneReader-TextBound")
        defer { try? FileManager.default.removeItem(at: root) }
        let textURL = root.appendingPathComponent("large.txt")
        try Data(repeating: 65, count: 17).write(to: textURL)

        XCTAssertThrowsError(
            try TextAdapterCore.loadText(textURL, maximumBytes: 16)
        ) { error in
            guard case let AdapterError.textSizeLimit(limit, actual) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(limit, 16)
            XCTAssertEqual(actual, 17)
        }
    }

    func testMarkdownRelocationRecomputesStaleLineRangeFromQuote() async throws {
        let root = try makeTemporaryRoot(prefix: "OneReader-MarkdownRelocation")
        defer { try? FileManager.default.removeItem(at: root) }
        let markdownURL = root.appendingPathComponent("chapter.md")
        try Data("preface\nsecond\n# Heading\nEvidence line\n".utf8).write(to: markdownURL)
        let source = Source(
            id: "relocated-source",
            displayName: "chapter.md",
            originKind: .localFile,
            originURL: markdownURL,
            managedState: .ready,
            latestSnapshotID: "new-snapshot"
        )
        let snapshot = SourceSnapshot(
            id: "new-snapshot",
            sourceID: source.id,
            revision: "new-digest",
            revisionKind: .contentDigest,
            digest: "new-digest",
            observedAt: .now,
            origin: markdownURL,
            managedRelativePath: nil,
            byteCount: 0
        )
        let context = AdapterContext(
            source: source,
            snapshot: snapshot,
            managedURL: markdownURL,
            derivedRootURL: root.appendingPathComponent("Derived")
        )
        let stale = Locator(
            sourceID: source.id,
            snapshotID: "old-snapshot",
            adapterID: MarkdownAdapter.id,
            payload: [
                "path": "chapter.md",
                "startLine": "2",
                "endLine": "2",
            ],
            structuralPath: "h1[1]",
            textQuote: TextQuote(prefix: nil, exact: "Evidence line", suffix: nil),
            fingerprint: AdapterUtilities.sha256("Evidence line")
        )

        let resolution = try await MarkdownAdapter().resolve(stale, in: context)
        let relocated = try XCTUnwrap(resolution.resolved)
        XCTAssertEqual(resolution.state, .relocated)
        XCTAssertEqual(relocated.payload["startLine"], "4")
        XCTAssertEqual(relocated.payload["endLine"], "4")
        let observation = try await MarkdownAdapter().readFragment(
            in: context,
            at: relocated,
            maxCharacters: 1_000
        )
        XCTAssertEqual(observation.content, "Evidence line")
    }

    func testHTMLIsSanitizedBeforeReadAndRender() async throws {
        let fixture = try makeFileFixture(
            name: "unsafe.html",
            content: """
                <!doctype html><html><head><title>Unsafe</title></head><body>
                <h1 onclick="steal()">Chapter</h1>
                <script>promptInjection()</script>
                <a href="javascript:steal()">bad</a>
                <p>trusted evidence</p><img src="cover.png">
                </body></html>
                """
        )
        defer { fixture.remove() }
        try Data([0x89, 0x50, 0x4e, 0x47]).write(
            to: fixture.context.managedURL.deletingLastPathComponent()
                .appendingPathComponent("cover.png")
        )
        let adapter = HTMLAdapter()

        let probe = try await adapter.probe(fixture.context)
        XCTAssertNotNil(probe)
        let nodes = try await adapter.listContent(in: fixture.context, under: nil, limit: 20)
        XCTAssertEqual(nodes.first?.title, "Chapter")
        XCTAssertEqual(
            nodes.first?.locator.payload["domPath"],
            "body > h1:nth-of-type(1)"
        )
        let rendered = try await adapter.presentation(in: fixture.context, at: nil)
        let html = try XCTUnwrap(rendered.content)
        XCTAssertFalse(html.localizedCaseInsensitiveContains("<script"))
        XCTAssertFalse(html.localizedCaseInsensitiveContains("onclick"))
        XCTAssertFalse(html.localizedCaseInsensitiveContains("javascript:"))
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("onereader-content:/cover.png"))
        let observation = try await adapter.readFragment(
            in: fixture.context,
            at: nodes[0].locator,
            maxCharacters: 1_000
        )
        XCTAssertTrue(observation.content.contains("trusted evidence"))
    }

    func testNestedDirectoryHTMLUsesSnapshotRootForRewrittenResources() async throws {
        let root = try makeTemporaryRoot(prefix: "OneReader-NestedHTML")
        defer { try? FileManager.default.removeItem(at: root) }
        let managedRoot = root.appendingPathComponent("Managed", isDirectory: true)
        let chapterRoot = managedRoot.appendingPathComponent("chapters", isDirectory: true)
        let imageRoot = chapterRoot.appendingPathComponent("img", isDirectory: true)
        try FileManager.default.createDirectory(at: imageRoot, withIntermediateDirectories: true)
        let pageURL = chapterRoot.appendingPathComponent("page.html")
        let imageURL = imageRoot.appendingPathComponent("a.png")
        try Data("<html><body><img src=\"img/a.png\">nested</body></html>".utf8)
            .write(to: pageURL)
        let imageBytes = Data([0x89, 0x50, 0x4e, 0x47])
        try imageBytes.write(to: imageURL)
        let source = Source(
            id: "nested-html-source",
            displayName: "Managed",
            originKind: .localDirectory,
            originURL: managedRoot,
            managedState: .ready,
            latestSnapshotID: "nested-html-snapshot"
        )
        let snapshot = SourceSnapshot(
            id: "nested-html-snapshot",
            sourceID: source.id,
            revision: "nested-html-revision",
            revisionKind: .directoryTreeDigest,
            digest: "nested-html-digest",
            observedAt: .now,
            origin: managedRoot,
            managedRelativePath: nil,
            byteCount: Int64(imageBytes.count)
        )
        let context = AdapterContext(
            source: source,
            snapshot: snapshot,
            managedURL: pageURL,
            contentRootURL: managedRoot,
            derivedRootURL: root.appendingPathComponent("Derived")
        )

        let presentation = try await HTMLAdapter().presentation(in: context, at: nil)
        XCTAssertEqual(presentation.baseURL?.standardizedFileURL, managedRoot.standardizedFileURL)
        XCTAssertTrue(try XCTUnwrap(presentation.content).contains(
            "onereader-content:/chapters/img/a.png"
        ))
        let loader = ReadOnlyContentResourceLoader(rootURL: try XCTUnwrap(presentation.baseURL))
        let resource = try loader.resolve(
            requestURL: URL(
                string: "onereader-content://nested-html-snapshot/chapters/img/a.png"
            )!
        )
        XCTAssertEqual(resource.fileURL.standardizedFileURL, imageURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: resource.fileURL), imageBytes)
    }

    @MainActor
    func testPDFImplementsStablePageLocatorAndPDFKitPresentation() async throws {
        let root = try makeTemporaryRoot(prefix: "OneReader-PDFAdapter")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.pdf")
        let image = NSImage(size: NSSize(width: 300, height: 420))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let page = try XCTUnwrap(PDFPage(image: image))
        let document = PDFDocument()
        document.insert(page, at: 0)
        try XCTUnwrap(document.dataRepresentation()).write(to: url)
        let context = try makeContext(url: url, displayName: "fixture.pdf")
        let adapter = PDFAdapter()

        let probe = try await adapter.probe(context)
        XCTAssertNotNil(probe)
        try await adapter.verifyRevision(in: context)
        let nodes = try await adapter.listContent(in: context, under: nil, limit: 10)
        XCTAssertEqual(nodes.first?.locator.pdfPageIndex, 0)
        let presentation = try await adapter.presentation(
            in: context,
            at: nodes.first?.locator
        )
        XCTAssertEqual(presentation.surface, .pdfKit)
        let resolution = try await adapter.resolve(
            try XCTUnwrap(nodes.first?.locator),
            in: context
        )
        XCTAssertEqual(resolution.state, .current)
    }

    func testPDFRectAnchorParsesAndClipsExactSelectionGeometry() throws {
        let anchor = try XCTUnwrap(PDFPageRectAnchor.parse("12.5,20,80,24"))
        XCTAssertEqual(anchor.rect, CGRect(x: 12.5, y: 20, width: 80, height: 24))
        XCTAssertEqual(
            anchor.clipped(to: CGRect(x: 20, y: 10, width: 30, height: 40)),
            CGRect(x: 20, y: 20, width: 30, height: 24)
        )
        XCTAssertNil(PDFPageRectAnchor.parse("12,20,0,24"))
        XCTAssertNil(PDFPageRectAnchor.parse("12,20,-1,24"))
        XCTAssertNil(PDFPageRectAnchor.parse("12,20,nan,24"))
        XCTAssertNil(PDFPageRectAnchor.parse("12,20,80"))
        XCTAssertNil(anchor.clipped(to: CGRect(x: 200, y: 200, width: 10, height: 10)))
    }

    func testDirectoryComposesChildAdaptersAndFTSIndex() async throws {
        let root = try makeTemporaryRoot(prefix: "OneReader-DirectoryAdapter")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("Input/Book", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try Data("# Start\n\nCross source evidence.".utf8).write(
            to: input.appendingPathComponent("README.md")
        )
        try Data("supporting evidence appears first; repeated evidence appears later".utf8).write(
            to: input.appendingPathComponent("notes.txt")
        )
        try Data("# 中文\n\n时间管理的意义在于管理自己。".utf8).write(
            to: input.appendingPathComponent("chapter-cn.md")
        )
        try Data([0, 1, 2]).write(to: input.appendingPathComponent("cover.bin"))

        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(
            database: database,
            storagePolicy: unlimitedStoragePolicy
        )
        let imported = try await library.importLocalSource(at: input)
        let coordinator = try AdapterCoordinator.standard(database: database)
        let plan = try await coordinator.prepareAndIndex(
            sourceID: imported.source.id,
            snapshotID: imported.snapshot.id
        )

        XCTAssertEqual(plan.primaryAdapterID, DirectoryAdapter.id)
        XCTAssertTrue(plan.auxiliaryAdapterIDs.contains(MarkdownAdapter.id))
        XCTAssertTrue(plan.auxiliaryAdapterIDs.contains(PlainTextAdapter.id))
        XCTAssertTrue(plan.auxiliaryAdapterIDs.contains(QuickLookAdapter.id))
        let nodes = try await coordinator.list(plan: plan)
        let markdown = try XCTUnwrap(nodes.first {
            $0.locator.adapterID == MarkdownAdapter.id
                && $0.locator.relativePath == "README.md"
        })
        let observation = try await coordinator.read(plan: plan, locator: markdown.locator)
        XCTAssertTrue(observation.content.contains("Cross source evidence"))
        let hits = try await coordinator.search(plan: plan, query: "evidence")
        XCTAssertEqual(Set(hits.map(\.snapshotID)), [imported.snapshot.id])
        XCTAssertGreaterThanOrEqual(hits.count, 2)

        try database.rebuildObservationIndex()
        XCTAssertGreaterThanOrEqual(
            try database.searchObservations(query: "evidence").count,
            2
        )
        let repeatedHit = try XCTUnwrap(
            database.searchObservations(query: "evidence").first {
                $0.locator.relativePath == "notes.txt"
            }
        )
        XCTAssertEqual(repeatedHit.locator.textQuote?.exact.lowercased(), "evidence")
        XCTAssertEqual(repeatedHit.locator.payload["startUTF16"], "11")
        XCTAssertNotNil(repeatedHit.locator.textQuote?.prefix)
        XCTAssertTrue(try XCTUnwrap(repeatedHit.locator.textQuote?.suffix).contains("repeated"))
        let chineseHits = try database.searchObservations(query: "时间管理")
        XCTAssertEqual(chineseHits.count, 1)
        XCTAssertTrue(chineseHits[0].context.contains("时间管理"))
        XCTAssertEqual(chineseHits[0].locator.textQuote?.exact, "时间管理")
        XCTAssertNotNil(chineseHits[0].locator.payload["startUTF16"])

        _ = try database.commitRemoval(sourceID: imported.source.id)
        XCTAssertTrue(try database.searchObservations(query: "evidence").isEmpty)
        do {
            _ = try await coordinator.prepare(
                sourceID: imported.source.id,
                snapshotID: imported.snapshot.id
            )
            XCTFail("Removed source must not remain actionable")
        } catch let error as LibraryStorageError {
            XCTAssertEqual(error, .missingSource(imported.source.id))
        }
    }

    func testDirectoryIndexExpandsEveryPDFPageAndEPUBSpineItem() async throws {
        let root = try makeTemporaryRoot(prefix: "OneReader-DirectoryRichDocuments")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("Input", isDirectory: true)
        let references = input.appendingPathComponent("references", isDirectory: true)
        let books = input.appendingPathComponent("books", isDirectory: true)
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        try createPDF(
            at: references.appendingPathComponent("manual.pdf"),
            pageCount: 2
        )
        try createTwoChapterEPUB(at: books.appendingPathComponent("guide.epub"))

        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: unlimitedStoragePolicy)
        let imported = try await library.importLocalSource(at: input)
        let coordinator = try AdapterCoordinator.standard(database: database)
        let plan = try await coordinator.prepareAndIndex(
            sourceID: imported.source.id,
            snapshotID: imported.snapshot.id
        )

        XCTAssertEqual(plan.primaryAdapterID, DirectoryAdapter.id)
        XCTAssertTrue(plan.auxiliaryAdapterIDs.contains(PDFAdapter.id))
        XCTAssertTrue(plan.auxiliaryAdapterIDs.contains(EPUBAdapter.id))
        XCTAssertEqual(
            try database.searchDocumentCount(planID: plan.id, adapterID: PDFAdapter.id),
            2
        )
        XCTAssertEqual(
            try database.searchDocumentCount(planID: plan.id, adapterID: EPUBAdapter.id),
            2
        )
        let hit = try XCTUnwrap(
            database.searchObservations(query: "second spine").first
        )
        XCTAssertEqual(hit.adapterID, EPUBAdapter.id)
        XCTAssertEqual(hit.locator.payload["path"], "books/guide.epub")
        XCTAssertEqual(hit.locator.payload["spineIndex"], "1")
        XCTAssertEqual(hit.locator.payload["href"], "OEBPS/text/second.xhtml")
    }

    func testIndexedPDFHitPreservesPageAndAddsExactQuoteAnchor() async throws {
        let root = try makeTemporaryRoot(prefix: "OneReader-PDFIndex")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("fixture.pdf")
        try Data("%PDF-1.4\nfixture".utf8).write(to: input)
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: unlimitedStoragePolicy)
        let imported = try await library.importLocalSource(at: input)
        let rootLocator = Locator(
            sourceID: imported.source.id,
            snapshotID: imported.snapshot.id,
            adapterID: PDFAdapter.id,
            payload: ["pageIndex": "4"],
            structuralPath: "page/4"
        )
        let body = "Page five begins here. Indexed PDF evidence is jumpable."
        let plan = AdapterPlan(
            id: "pdf-search-plan",
            schemaVersion: AdapterPlan.currentSchemaVersion,
            sourceID: imported.source.id,
            snapshotID: imported.snapshot.id,
            primaryAdapterID: PDFAdapter.id,
            auxiliaryAdapterIDs: [],
            capabilityRoutes: [
                .list: PDFAdapter.id,
                .read: PDFAdapter.id,
                .search: PDFAdapter.id,
                .render: PDFAdapter.id,
            ],
            evidence: [ProbeEvidence(
                id: "pdf-search-fixture",
                adapterID: PDFAdapter.id,
                rule: "test-fixture",
                detail: "Bound PDF search projection",
                confidence: 1
            )],
            confidence: 1,
            reason: "Search anchor fixture",
            isUserOverride: false,
            createdAt: .now
        )
        try database.saveAdapterPlan(plan)
        let generationID = try database.beginObservationIndex(
            snapshotID: plan.snapshotID,
            planID: plan.id
        )
        try database.stageObservation(
            Observation(
                id: "pdf-observation",
                sourceID: imported.source.id,
                snapshotID: imported.snapshot.id,
                adapterID: PDFAdapter.id,
                locator: rootLocator,
                mediaType: "text/plain; source=application/pdf",
                content: body,
                contentReference: imported.snapshot.managedRelativePath,
                contentDigest: AdapterUtilities.sha256(body),
                truncated: false,
                observedAt: .now
            ),
            title: "Page 5",
            generationID: generationID
        )
        try database.completeObservationIndex(
            snapshotID: plan.snapshotID,
            planID: plan.id,
            generationID: generationID
        )

        let hit = try XCTUnwrap(database.searchObservations(query: "PDF evidence").first)
        XCTAssertEqual(hit.locator.pdfPageIndex, 4)
        XCTAssertEqual(hit.locator.structuralPath, "page/4")
        XCTAssertEqual(hit.locator.textQuote?.exact, "PDF evidence")
        let expectedRange = try XCTUnwrap(body.range(of: "PDF evidence"))
        XCTAssertEqual(
            hit.locator.payload["startUTF16"],
            String(NSRange(expectedRange, in: body).location)
        )
        XCTAssertEqual(hit.snapshotID, imported.snapshot.id)
    }

    func testDirectoryPresentationHonorsSubdirectoryLocator() async throws {
        let root = try makeTemporaryRoot(prefix: "OneReader-DirectoryPresentation")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("Book", isDirectory: true)
        let nested = book.appendingPathComponent("Part", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("root only".utf8).write(to: book.appendingPathComponent("root.txt"))
        try Data("nested only".utf8).write(to: nested.appendingPathComponent("chapter.txt"))
        let source = Source(
            id: "directory-source",
            displayName: "Book",
            originKind: .localDirectory,
            originURL: book,
            managedState: .ready,
            latestSnapshotID: "directory-snapshot"
        )
        let snapshot = SourceSnapshot(
            id: "directory-snapshot",
            sourceID: source.id,
            revision: "tree",
            revisionKind: .directoryTreeDigest,
            digest: "tree",
            observedAt: .now,
            origin: book,
            managedRelativePath: nil,
            byteCount: 0
        )
        let context = AdapterContext(
            source: source,
            snapshot: snapshot,
            managedURL: book,
            derivedRootURL: root.appendingPathComponent("Derived")
        )
        let locator = Locator(
            sourceID: source.id,
            snapshotID: snapshot.id,
            adapterID: DirectoryAdapter.id,
            payload: ["path": "Part"],
            structuralPath: "Part"
        )

        let presentation = try await DirectoryAdapter().presentation(
            in: context,
            at: locator
        )
        let scopedNodes = try await DirectoryAdapter().listContent(
            in: context,
            under: locator,
            limit: 1
        )

        XCTAssertEqual(presentation.title, "Part")
        XCTAssertTrue(try XCTUnwrap(presentation.content).contains("chapter.txt"))
        XCTAssertFalse(try XCTUnwrap(presentation.content).contains("root.txt"))
        XCTAssertEqual(presentation.contentURL, nested)
        XCTAssertEqual(scopedNodes.map(\.locator.relativePath), ["Part/chapter.txt"])
    }

    func testUnknownFileUsesExplicitlyLimitedQuickLookFallback() async throws {
        let fixture = try makeFileFixture(name: "archive.unknown", data: Data([0, 1, 2, 3]))
        defer { fixture.remove() }
        let registry = try AdapterRegistry.standard()
        let plan = try await registry.deterministicPlan(for: fixture.context)

        XCTAssertEqual(plan.primaryAdapterID, QuickLookAdapter.id)
        XCTAssertEqual(plan.capabilityRoutes[.render], QuickLookAdapter.id)
        XCTAssertNil(plan.capabilityRoutes[.read])
        XCTAssertNil(plan.capabilityRoutes[.search])
        let presentation = try await registry.render(
            adapterID: QuickLookAdapter.id,
            in: fixture.context,
            at: nil
        )
        XCTAssertEqual(presentation.surface, .quickLook)
        XCTAssertTrue(presentation.limitations.contains { $0.contains("不提供结构化全文搜索") })
    }

    func testKnownExtensionProbeFailureFallsBackToQuickLookWithEvidence() async throws {
        let fixture = try makeFileFixture(
            name: "damaged.epub",
            data: Data("not a zip archive".utf8)
        )
        defer { fixture.remove() }
        let registry = try AdapterRegistry.standard()

        let plan = try await registry.deterministicPlan(for: fixture.context)

        XCTAssertEqual(plan.primaryAdapterID, QuickLookAdapter.id)
        XCTAssertTrue(plan.evidence.contains {
            $0.adapterID == EPUBAdapter.id && $0.rule == "probe-failed"
        })
        XCTAssertTrue(plan.reason.contains("安全降级"))
    }

    func testQuickLookOnlyPlanSkipsIndexingWithoutFailure() async throws {
        let root = try makeTemporaryRoot(prefix: "OneReader-QuickLookIndex")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("unknown.bin")
        try Data([0, 1, 2, 3]).write(to: input)
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: unlimitedStoragePolicy)
        let imported = try await library.importLocalSource(at: input)
        let coordinator = try AdapterCoordinator.standard(database: database)

        let plan = try await coordinator.prepareAndIndex(
            sourceID: imported.source.id,
            snapshotID: imported.snapshot.id
        )

        XCTAssertEqual(plan.primaryAdapterID, QuickLookAdapter.id)
        XCTAssertEqual(try database.observationCount(), 0)
    }

    func testPresentationRegistryDescribesQuickLookCapabilityLimits() throws {
        let quickLook = try XCTUnwrap(
            PresentationRegistry.standard.descriptor(for: .quickLook)
        )
        XCTAssertFalse(quickLook.supportsFind)
        XCTAssertFalse(quickLook.supportsStructuredHighlight)
        XCTAssertTrue(
            try XCTUnwrap(PresentationRegistry.standard.descriptor(for: .pdfKit))
                .supportsStructuredHighlight
        )
    }
}

private struct AdapterFileFixture {
    let root: URL
    let context: AdapterContext

    func context(replacingSnapshotID snapshotID: String) -> AdapterContext {
        AdapterContext(
            source: context.source,
            snapshot: SourceSnapshot(
                id: snapshotID,
                sourceID: context.source.id,
                revision: context.snapshot.revision,
                revisionKind: context.snapshot.revisionKind,
                digest: context.snapshot.digest,
                observedAt: .now,
                origin: context.snapshot.origin,
                managedRelativePath: context.snapshot.managedRelativePath,
                byteCount: context.snapshot.byteCount
            ),
            managedURL: context.managedURL,
            contentRootURL: context.contentRootURL,
            derivedRootURL: context.derivedRootURL,
            declaredMediaType: context.declaredMediaType
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeFileFixture(
    name: String,
    content: String
) throws -> AdapterFileFixture {
    try makeFileFixture(name: name, data: Data(content.utf8))
}

private func makeFileFixture(
    name: String,
    data: Data
) throws -> AdapterFileFixture {
    let root = try makeTemporaryRoot(prefix: "OneReader-Adapter")
    let url = root.appendingPathComponent(name)
    try data.write(to: url)
    return AdapterFileFixture(
        root: root,
        context: try makeContext(url: url, displayName: name)
    )
}

private func makeContext(
    url: URL,
    displayName: String,
    originKind: SourceOriginKind = .localFile,
    revisionKind: SourceRevisionKind = .contentDigest,
    sourceID: String = "source",
    snapshotID: String = "snapshot"
) throws -> AdapterContext {
    let data = try Data(contentsOf: url)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let source = Source(
        id: sourceID,
        displayName: displayName,
        originKind: originKind,
        originURL: url,
        managedState: .ready,
        latestSnapshotID: snapshotID
    )
    let snapshot = SourceSnapshot(
        id: snapshotID,
        sourceID: sourceID,
        revision: digest,
        revisionKind: revisionKind,
        digest: digest,
        observedAt: .now,
        origin: url,
        managedRelativePath: nil,
        byteCount: Int64(data.count)
    )
    let derived = url.deletingLastPathComponent().appendingPathComponent("Derived")
    try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
    return AdapterContext(
        source: source,
        snapshot: snapshot,
        managedURL: url,
        derivedRootURL: derived,
        declaredMediaType: nil
    )
}

private func makeTemporaryRoot(prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "\(prefix)-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func createPDF(at url: URL, pageCount: Int) throws {
    let document = PDFDocument()
    for index in 0..<pageCount {
        let image = NSImage(size: NSSize(width: 320, height: 480))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 480)).fill()
        ("PDF page \(index + 1)" as NSString).draw(
            at: NSPoint(x: 32, y: 400),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 20),
                .foregroundColor: NSColor.black,
            ]
        )
        image.unlockFocus()
        guard let page = PDFPage(image: image) else {
            throw CocoaError(.fileWriteUnknown)
        }
        document.insert(page, at: index)
    }
    guard document.write(to: url) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func createTwoChapterEPUB(at url: URL) throws {
    let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
    let package = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Directory EPUB</dc:title>
          </metadata>
          <manifest>
            <item id="first" href="text/first.xhtml" media-type="application/xhtml+xml"/>
            <item id="second" href="text/second.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="first"/><itemref idref="second"/></spine>
        </package>
        """
    let entries: [(String, Data, CompressionMethod)] = [
        ("mimetype", Data("application/epub+zip".utf8), .none),
        ("META-INF/container.xml", Data(container.utf8), .deflate),
        ("OEBPS/content.opf", Data(package.utf8), .deflate),
        (
            "OEBPS/text/first.xhtml",
            Data("<html><head><title>First</title></head><body>first spine evidence</body></html>".utf8),
            .deflate
        ),
        (
            "OEBPS/text/second.xhtml",
            Data("<html><head><title>Second</title></head><body>second spine evidence</body></html>".utf8),
            .deflate
        ),
    ]
    let archive = try Archive(url: url, accessMode: .create)
    for (path, data, compression) in entries {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compression,
            provider: { position, size in
                let lower = Int(position)
                let upper = min(lower + size, data.count)
                guard lower < upper else { return Data() }
                return data.subdata(in: lower..<upper)
            }
        )
    }
}

private func replacingTestAnchor(
    _ original: Locator, payload: [String: String], quote: TextQuote? = nil
) -> Locator {
    Locator(
        sourceID: original.sourceID, snapshotID: original.snapshotID,
        adapterID: original.adapterID, schemaVersion: original.schemaVersion,
        payload: payload, structuralPath: original.structuralPath,
        textQuote: quote ?? original.textQuote, fingerprint: original.fingerprint
    )
}

private actor IndexObservationCollector {
    var values: [Observation] = []
    func append(_ observation: Observation) { values.append(observation) }
}

private actor IndexConcurrencyCounter {
    var active = 0
    var maximum = 0
    var completed = 0
    func begin() { active += 1; maximum = max(maximum, active) }
    func end() { active -= 1; completed += 1 }
}

private let unlimitedStoragePolicy = LibraryStoragePolicy(
    largeImportThreshold: .max,
    minimumFreeCapacity: 0,
    capacityProvider: { _ in .max }
)
