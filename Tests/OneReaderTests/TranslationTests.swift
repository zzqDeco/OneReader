import Foundation
import GRDB
import XCTest
@testable import OneReader

@MainActor
final class TranslationTests: XCTestCase {
    private var locator: Locator {
        Locator(sourceID: "source", snapshotID: "snapshot", adapterID: MarkdownAdapter.id,
            payload: ["path": "book.md"], structuralPath: "book.md")
    }

    func testMarkdownASTMappingPreservesUnicodeAndProtectedContent() throws {
        let text = "# 标题 👩🏽‍💻\n\n相同段落 é。\n\n相同段落 é。\n\nDo not change `count = 3`, $x+1$ or [guide](https://example.invalid/a).\n\n```swift\nlet secret = 42\n```\n"
        let segments = try TranslationSourceBuilder.textSegments(text, locator: locator, markdown: true)
        XCTAssertEqual(segments.count, 5)
        XCTAssertEqual(Set(segments.map(\.id)).count, 5)
        XCTAssertEqual(segments[1].originalText, segments[2].originalText)
        XCTAssertNotEqual(segments[1].id, segments[2].id)
        XCTAssertTrue(segments.last?.isVerbatim == true)
        let protected = segments[3]
        XCTAssertFalse(protected.modelText.contains("https://example.invalid"))
        XCTAssertFalse(protected.modelText.contains("count = 3"))
        XCTAssertFalse(protected.modelText.contains("$x+1$"))
        XCTAssertEqual(try protected.restoringProtectedSpans(in: protected.modelText), protected.originalText)
        for segment in segments {
            let start = try XCTUnwrap(Int(segment.locator.payload["startUTF16"] ?? ""))
            let end = try XCTUnwrap(Int(segment.locator.payload["endUTF16"] ?? ""))
            let range = try XCTUnwrap(Range(NSRange(location: start, length: end - start), in: text))
            XCTAssertEqual(String(text[range]), segment.originalText)
            XCTAssertEqual(segment.locator.textQuote?.exact, segment.originalText)
        }
    }

    func testSelectionUsesSourceRangeNotRenderedOffsetsAndBoundsChapter() throws {
        let text = "# First\n\nHello **world** 👨‍👩‍👧.\n\n# Next\n\nUnrelated."
        let range = (text as NSString).range(of: "**world**")
        let selected = Locator(sourceID: locator.sourceID, snapshotID: locator.snapshotID,
            adapterID: locator.adapterID, payload: ["path": "book.md", "startUTF16": String(range.location),
                "endUTF16": String(NSMaxRange(range)), "renderedStartUTF16": "1"],
            textQuote: TextQuote(prefix: nil, exact: "**world**", suffix: nil))
        let segments = try TranslationSourceBuilder.textSegments(text, locator: locator,
            selection: ReaderSelection(text: "world", locator: selected), markdown: true)
        XCTAssertEqual(segments.map(\.originalText), ["**world**"])
        XCTAssertEqual(segments[0].locator.payload["startUTF16"], String(range.location))
        XCTAssertNil(segments[0].locator.payload["renderedStartUTF16"])
        let next = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: locator.adapterID,
            payload: ["startLine": "5"])
        let chapter = try TranslationSourceBuilder.textSegments(text, locator: locator, nextLocator: next, markdown: true)
        XCTAssertFalse(chapter.contains { $0.originalText.contains("Unrelated") || $0.originalText.contains("# Next") })
    }

    func testPlainTextBudgetIsGraphemeSafe() throws {
        let text = String(repeating: "👩🏽‍💻é中文", count: 3_000)
        let segments = try TranslationSourceBuilder.textSegments(text, locator: locator, markdown: false)
        XCTAssertLessThanOrEqual(segments.count, 12)
        XCTAssertLessThanOrEqual(segments.reduce(0) { $0 + $1.originalText.utf16.count }, 12_000)
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.originalText.utf16.count, 4_000)
            XCTAssertFalse(segment.originalText.hasSuffix("\u{200D}"))
        }
    }

    func testPartialInlineCodeSelectionIsNeverSentUnprotected() throws {
        let text = "Use `dangerous()` safely."
        let range = (text as NSString).range(of: "dangerous")
        let selected = Locator(sourceID: locator.sourceID, snapshotID: locator.snapshotID,
            adapterID: locator.adapterID, payload: ["startUTF16": String(range.location), "endUTF16": String(NSMaxRange(range))],
            textQuote: TextQuote(prefix: nil, exact: "dangerous", suffix: nil))
        let segments = try TranslationSourceBuilder.textSegments(text, locator: locator,
            selection: ReaderSelection(text: "dangerous", locator: selected), markdown: true)
        XCTAssertFalse(segments[0].modelText.contains("dangerous"))
        XCTAssertEqual(try segments[0].restoringProtectedSpans(in: segments[0].modelText), "dangerous")
    }

    func testViewportChangesDoNotChangeParagraphIdentity() throws {
        let first = Locator(sourceID: "s", snapshotID: "v", adapterID: PDFAdapter.id,
            payload: ["pageIndex": "2", "positionKind": "viewport", "viewportY": "0.1", "rect": "0,0,10,10"])
        let second = Locator(sourceID: "s", snapshotID: "v", adapterID: PDFAdapter.id,
            payload: ["pageIndex": "2", "positionKind": "viewport", "viewportY": "0.8", "rect": "0,10,10,10"])
        let a = try TranslationSourceBuilder.textSegments("Original paragraph", locator: first, markdown: false, pageRelative: true)
        let b = try TranslationSourceBuilder.textSegments("Original paragraph", locator: second, markdown: false, pageRelative: true)
        XCTAssertEqual(a, b)
        XCTAssertNil(a[0].locator.payload["rect"])
    }

    func testHTMLKeepsDOMOrderSkipsCodeAndNeverSendsTargetsOrScript() throws {
        let html = "<html><body><h1>Title</h1><p>A <a href='https://private.invalid'>link</a> and <code>let x = 1</code>.</p><pre>code()</pre><p>Later</p><script>steal()</script></body></html>"
        let segments = try TranslationSourceBuilder.htmlSegments(html, locator: locator, selection: nil)
        XCTAssertEqual(segments.count, 4)
        XCTAssertTrue(segments[2].isVerbatim)
        XCTAssertTrue(segments.allSatisfy { $0.locator.payload["domPath"]?.hasPrefix("body > ") == true })
        XCTAssertFalse(segments.map(\.modelText).joined().contains("private.invalid"))
        XCTAssertFalse(segments.map(\.modelText).joined().contains("steal()"))
        XCTAssertFalse(segments[1].modelText.contains("let x"))
    }

    func testHTMLNestedSelectionResolvesItsOwningParagraphWithRepeatedText() throws {
        let html = "<body><p><em>Repeat</em> here.</p><p><em>Repeat</em> here.</p></body>"
        let base = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: HTMLAdapter.id)
        let selected = Locator(sourceID: base.sourceID, snapshotID: base.snapshotID, adapterID: base.adapterID,
            payload: ["domPath": "body > p:nth-of-type(2) > em:nth-of-type(1)"],
            textQuote: TextQuote(prefix: nil, exact: "Repeat", suffix: nil))
        let result = try TranslationSourceBuilder.htmlSegments(html, locator: base,
            selection: ReaderSelection(text: "Repeat", locator: selected))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].locator.payload["domPath"], "body > p:nth-of-type(2)")
        XCTAssertEqual(result[0].originalText, "Repeat")
    }

    func testHTMLSelectionFailsClosedForMissingOrNonOwningDOMPaths() throws {
        let html = "<body><p><em>Repeat</em> here.</p><p>Repeat here.</p></body>"
        let base = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: HTMLAdapter.id,
            payload: ["domPath": "body > p:nth-of-type(1)"])
        for path in [nil, "body", "#missing", "body > p:nth-of-type(2) > em:nth-of-type(1)", "p"] as [String?] {
            let selected = Locator(sourceID: base.sourceID, snapshotID: base.snapshotID, adapterID: base.adapterID,
                payload: path.map { ["domPath": $0] } ?? [:],
                textQuote: TextQuote(prefix: nil, exact: "Repeat", suffix: nil))
            XCTAssertThrowsError(try TranslationSourceBuilder.htmlSegments(html, locator: base,
                selection: ReaderSelection(text: "Repeat", locator: selected))) {
                XCTAssertEqual($0 as? TranslationError, .selectionNotGrounded)
            }
        }
    }

    func testHTMLAmbiguousTextWithinOwnerDoesNotFallThroughToAnotherParagraph() throws {
        let html = "<body><p><em>Repeat</em> Repeat</p><p>Repeat</p></body>"
        let base = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: HTMLAdapter.id)
        let selected = Locator(sourceID: base.sourceID, snapshotID: base.snapshotID, adapterID: base.adapterID,
            payload: ["domPath": "body > p:nth-of-type(1) > em:nth-of-type(1)"],
            textQuote: TextQuote(prefix: nil, exact: "Repeat", suffix: nil))
        XCTAssertThrowsError(try TranslationSourceBuilder.htmlSegments(html, locator: base,
            selection: ReaderSelection(text: "Repeat", locator: selected))) {
            XCTAssertEqual($0 as? TranslationError, .selectionNotGrounded)
        }
    }

    func testHTMLNestedListSelectionUsesNearestIncludedBlock() throws {
        let html = "<body><ul><li>Same <a><strong>word</strong></a></li><li>Same <a><strong>word</strong></a></li></ul></body>"
        let base = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: HTMLAdapter.id)
        let selected = Locator(sourceID: base.sourceID, snapshotID: base.snapshotID, adapterID: base.adapterID,
            payload: ["domPath": "body > ul:nth-of-type(1) > li:nth-of-type(2) > a:nth-of-type(1) > strong:nth-of-type(1)"],
            textQuote: TextQuote(prefix: nil, exact: "word", suffix: nil))
        let result = try TranslationSourceBuilder.htmlSegments(html, locator: base,
            selection: ReaderSelection(text: "word", locator: selected))
        XCTAssertEqual(result[0].locator.payload["domPath"], "body > ul:nth-of-type(1) > li:nth-of-type(2)")
    }

    func testBilingualRestorePrefersExactAndHalfOpenPDFOffsetsOverPage() {
        let segments = [mappedSegment("first", adapter: PDFAdapter.id, payload: ["pageIndex": "4", "pageTextStartUTF16": "0", "pageTextEndUTF16": "40"]),
                        mappedSegment("target", adapter: PDFAdapter.id, payload: ["pageIndex": "4", "pageTextStartUTF16": "40", "pageTextEndUTF16": "45"]),
                        mappedSegment("last", adapter: PDFAdapter.id, payload: ["pageIndex": "4", "pageTextStartUTF16": "45", "pageTextEndUTF16": "70"])]
        XCTAssertEqual(BilingualAnchorResolver.segmentID(for: segments[1].locator, among: segments), "target")
        for (offset, expected) in [(40, "target"), (42, "target"), (45, "last")] {
            let current = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: PDFAdapter.id,
                payload: ["pageIndex": "4", "pageTextStartUTF16": String(offset), "pageTextEndUTF16": String(offset)])
            XCTAssertEqual(BilingualAnchorResolver.segmentID(for: current, among: segments), expected)
        }
        let outside = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: PDFAdapter.id,
            payload: ["pageIndex": "4", "pageTextStartUTF16": "80"])
        XCTAssertNil(BilingualAnchorResolver.segmentID(for: outside, among: segments))
        let coarse = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: PDFAdapter.id, payload: ["pageIndex": "4"])
        XCTAssertNil(BilingualAnchorResolver.segmentID(for: coarse, among: segments))
        XCTAssertEqual(BilingualAnchorResolver.segmentID(for: coarse, among: [segments[1]]), "target")
    }

    func testBilingualRestoreDistinguishesSegmentsOnSameTextLine() {
        let first = mappedSegment("first", payload: ["path": "book.md", "startLine": "40", "endLine": "40", "startUTF16": "0", "endUTF16": "40"])
        let target = mappedSegment("target", payload: ["path": "book.md", "startLine": "40", "endLine": "40", "startUTF16": "40", "endUTF16": "45"])
        let current = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: MarkdownAdapter.id,
            payload: ["path": "book.md", "startLine": "40", "startUTF16": "42"])
        XCTAssertEqual(BilingualAnchorResolver.segmentID(for: current, among: [first, target]), "target")
        let coarse = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: MarkdownAdapter.id,
            payload: ["path": "book.md", "startLine": "40"])
        XCTAssertNil(BilingualAnchorResolver.segmentID(for: coarse, among: [first, target]))
        let otherFile = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: MarkdownAdapter.id,
            payload: ["path": "another.md", "startUTF16": "42"])
        XCTAssertNil(BilingualAnchorResolver.segmentID(for: otherFile, among: [first, target]))
    }

    func testBilingualRestorePrefersExactLineRangeAndPreservedOCRRectangle() {
        let broad = mappedSegment("broad", payload: ["path": "book.md", "startLine": "1", "endLine": "50"])
        let target = mappedSegment("target", payload: ["path": "book.md", "startLine": "40", "endLine": "45"])
        let current = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: MarkdownAdapter.id,
            payload: ["path": "book.md", "startLine": "40", "endLine": "45", "positionKind": "textViewport"])
        XCTAssertEqual(BilingualAnchorResolver.segmentID(for: current, among: [broad, target]), "target")
        let firstOCR = mappedSegment("first-ocr", adapter: "onereader.ocr", payload: ["pageIndex": "4", "rect": "0.1,0.2,0.2,0.1", "ocrSpanID": "a"])
        let targetOCR = mappedSegment("target-ocr", adapter: "onereader.ocr", payload: ["pageIndex": "4", "rect": "0.3,0.6,0.2,0.1", "ocrSpanID": "b"])
        let native = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: PDFAdapter.id,
            payload: ["pageIndex": "4", "rect": "0.3,0.6,0.2,0.1"])
        XCTAssertEqual(BilingualAnchorResolver.segmentID(for: native, among: [firstOCR, targetOCR]), "target-ocr")
    }

    private func mappedSegment(_ id: String, adapter: String = MarkdownAdapter.id,
                               payload: [String: String]) -> TranslationSegment {
        let text = "Repeated source text"
        let anchor = Locator(sourceID: "source", snapshotID: "snapshot", adapterID: adapter,
            payload: payload, textQuote: TextQuote(prefix: nil, exact: text, suffix: nil))
        return TranslationSegment(id: id, order: 0,
            fragment: SourceFragment(id: id, sourceID: "source", locator: anchor, role: .primary, label: id),
            originalText: text, originalDigest: AdapterUtilities.sha256(text), modelText: text,
            protectedSpans: [], isVerbatim: false)
    }

    func testOCRProgressMapsToNativePageWithoutPretendingRecognizedTextIsOriginal() {
        let ocr = Locator(sourceID: "scan", snapshotID: "snapshot", adapterID: "onereader.ocr",
            payload: ["derivedText": "ocr", "ocrRevisionID": "r1", "ocrSchema": "1", "ocrSpanID": "s1", "pageIndex": "4", "rect": "0.1,0.2,0.3,0.4"],
            textQuote: TextQuote(prefix: nil, exact: "recognized text", suffix: nil), fingerprint: "digest")
        let progress = BilingualProgressMapping.sourceLocator(ocr, surface: .pdfKit)
        XCTAssertEqual(progress.adapterID, PDFAdapter.id)
        XCTAssertEqual(progress.pdfPageIndex, 4)
        XCTAssertEqual(progress.payload["rect"], ocr.payload["rect"])
        XCTAssertNil(progress.payload["ocrRevisionID"])
        XCTAssertNil(progress.textQuote)
        XCTAssertNil(progress.fingerprint)
        XCTAssertEqual(ocr.payload["ocrRevisionID"], "r1", "Cache/reference anchor stays unchanged")
    }

    func testValidatorRejectsMissingDuplicateOutOfOrderForgedAndOversizedOutput() async throws {
        let f = try await TranslationFixture.make()
        defer { f.remove() }
        let request = TranslationRequest(settings: f.settings, segments: Array(f.segments.prefix(2)))
        let good = request.segments.map { TranslationDraft.Segment(id: $0.id, originalDigest: $0.originalDigest, translatedText: $0.modelText) }
        let variants: [[TranslationDraft.Segment]] = [[], [good[0], good[0]], Array(good.reversed()),
            good + [good[0]], [TranslationDraft.Segment(id: "forged", originalDigest: good[0].originalDigest, translatedText: "x")],
            [TranslationDraft.Segment(id: good[0].id, originalDigest: "wrong", translatedText: "x"), good[1]],
            [TranslationDraft.Segment(id: good[0].id, originalDigest: good[0].originalDigest, translatedText: String(repeating: "x", count: 17_000)), good[1]]]
        for variant in variants {
            XCTAssertThrowsError(try TranslationDraft(schemaVersion: 1, segments: variant)
                .validated(for: request, database: f.database, manifest: f.manifest))
        }
        XCTAssertThrowsError(try TranslationDraft(schemaVersion: 99, segments: good)
            .validated(for: request, database: f.database, manifest: f.manifest))
        let validated = try TranslationDraft(schemaVersion: 1, segments: good)
            .validated(for: request, database: f.database, manifest: f.manifest)
        XCTAssertEqual(validated.map(\.segment.locator), request.segments.map(\.locator))
    }

    func testCacheIdentityIncludesLanguageProviderRevisionPromptAndSnapshot() async throws {
        let f = try await TranslationFixture.make()
        defer { f.remove() }
        let first = f.segments[0]
        let key = try first.cacheKey(settings: f.settings)
        var changed = f.profile; changed.modelID = "different"
        XCTAssertNotEqual(key, try first.cacheKey(settings: TranslationSettings(sourceLanguage: .automatic, targetLanguage: .simplifiedChinese, profile: changed)))
        changed = f.profile; changed.endpoint = URL(string: "http://localhost:11435")
        XCTAssertNotEqual(key, try first.cacheKey(settings: TranslationSettings(sourceLanguage: .automatic, targetLanguage: .simplifiedChinese, profile: changed)))
        XCTAssertNotEqual(key, try first.cacheKey(settings: TranslationSettings(sourceLanguage: .automatic, targetLanguage: .english, profile: f.profile)))
        XCTAssertNotEqual(key, try first.cacheKey(settings: TranslationSettings(sourceLanguage: .english, targetLanguage: .simplifiedChinese, profile: f.profile)))
        let newLocator = Locator(sourceID: first.locator.sourceID, snapshotID: "new", adapterID: first.locator.adapterID)
        let new = try TranslationSourceBuilder.textSegments(first.originalText, locator: newLocator, markdown: false)[0]
        XCTAssertNotEqual(key, try new.cacheKey(settings: f.settings))
        let encoded = String(decoding: try JSONEncoder.translation.encode(f.settings), as: UTF8.self)
        XCTAssertFalse(encoded.contains("keychainReference"))
        XCTAssertFalse(encoded.contains("test-secret"))
    }

    func testTypedRuntimeCommitsCacheAndReopeningReadsWithoutProvider() async throws {
        let f = try await TranslationFixture.make()
        defer { f.remove() }
        let trace = TranslationTrace()
        let runtime = f.runtime(trace: trace)
        let session = try await runtime.session(forSpaceID: f.imported.space.id)
        let handle = try await session.start(f.request(segments: [f.segments[0]]))
        for try await _ in handle.events {}
        XCTAssertEqual(try f.database.agentRunState(runID: handle.runID), .completed)
        let cached = try XCTUnwrap(f.database.cachedTranslation(segment: f.segments[0], settings: f.settings))
        XCTAssertEqual(cached.segment.locator, f.segments[0].locator)
        let reopened = try LibraryDatabase(rootURL: f.root.appendingPathComponent("Library"))
        XCTAssertEqual(try reopened.cachedTranslation(segment: f.segments[0], settings: f.settings), cached)
        let controller = BilingualReadingModel()
        controller.configure(database: f.database, coordinator: f.coordinator, runtime: runtime)
        controller.prepare(spaceID: f.imported.space.id, document: f.document,
            locator: f.document.locator, nextLocator: nil,
            selection: ReaderSelection(text: f.segments[0].originalText, locator: f.segments[0].locator),
            plan: f.plan, profile: f.profile)
        try await waitUntil { !controller.isBusy }
        controller.translate()
        try await waitUntil { !controller.isBusy }
        let count = await trace.count
        XCTAssertEqual(count, 1, "Offline cache hit must not create another model call")
        XCTAssertEqual(controller.completedCount, 1)
        controller.deleteCurrentCache()
        try await waitUntil { !controller.isBusy }
        XCTAssertNil(try f.database.cachedTranslation(segment: f.segments[0], settings: f.settings))
        XCTAssertNotNil(try f.database.fetchSources().first)
    }

    func testRemoteDisclosureWaitsAndDenialMakesZeroCalls() async throws {
        let f = try await TranslationFixture.make(remote: true)
        defer { f.remove() }
        let trace = TranslationTrace()
        let controlledRuntime = f.runtime(trace: trace)
        let session = try await controlledRuntime.session(forSpaceID: f.imported.space.id)
        let handle = try await session.start(f.request(segments: [f.segments[0]]))
        for try await _ in handle.events {}
        XCTAssertEqual(try f.database.agentRunState(runID: handle.runID), .waitingForUser)
        await session.cancel(runID: handle.runID)
        let count = await trace.count
        XCTAssertEqual(count, 0)
        XCTAssertNil(try f.database.cachedTranslation(segment: f.segments[0], settings: f.settings))
    }

    func testCancelledLateModelResultCannotPublishCache() async throws {
        let f = try await TranslationFixture.make()
        defer { f.remove() }
        let trace = TranslationTrace()
        let session = try await f.runtime(trace: trace, delay: true).session(forSpaceID: f.imported.space.id)
        let handle = try await session.start(f.request(segments: [f.segments[0]]))
        try await waitUntil { await trace.count > 0 }
        await session.cancel(runID: handle.runID)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(try f.database.agentRunState(runID: handle.runID), .cancelled)
        XCTAssertNil(try f.database.cachedTranslation(segment: f.segments[0], settings: f.settings))
    }

    func testControllerRetriesOnlyUncommittedSegments() async throws {
        let f = try await TranslationFixture.make()
        defer { f.remove() }
        let trace = TranslationTrace()
        let runtime = f.runtime(trace: trace, failCall: 2)
        let controller = BilingualReadingModel()
        controller.configure(database: f.database, coordinator: f.coordinator, runtime: runtime)
        controller.prepare(spaceID: f.imported.space.id, document: f.document,
            locator: f.document.locator, nextLocator: nil, selection: nil, plan: f.plan, profile: f.profile)
        try await waitUntil { !controller.isBusy }
        controller.translate()
        try await waitUntil { !controller.isBusy }
        XCTAssertEqual(controller.completedCount, 1)
        controller.translate()
        try await waitUntil { !controller.isBusy }
        XCTAssertEqual(controller.completedCount, controller.rows.count)
        let ids = await trace.ids
        XCTAssertEqual(ids.filter { $0 == f.segments[0].id }.count, 1)
        XCTAssertEqual(ids.filter { $0 == f.segments[1].id }.count, 2)
    }

    func testTypedPromptOnlyContainsDeclaredSegments() async throws {
        let f = try await TranslationFixture.make()
        defer { f.remove() }
        let request = f.request(segments: [f.segments[0]])
        let prompt = ReadingAgentPrompt.prompt(for: AgentModelRequest(runID: "run", generation: 1, request: request, correction: nil))
        XCTAssertTrue(prompt.contains(f.segments[0].modelText))
        XCTAssertFalse(prompt.contains(f.segments[1].originalText))
        XCTAssertFalse(prompt.contains(f.profile.keychainReference ?? "keychainReference"))
        XCTAssertTrue(prompt.contains("no tools"))
    }

    func testBilingualViewSettingsDoNotMoveSourceButUserReadingRestoresOriginalAnchor() async throws {
        let f = try await TranslationFixture.make()
        defer { f.remove() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TranslationProgress.\(UUID().uuidString)"))
        let model = AppModel(libraryRootURL: f.root.appendingPathComponent("Library"), defaults: defaults,
            secretStore: f.secrets, agentDriverFactory: TranslationFakeFactory(trace: TranslationTrace(), failCall: nil, delay: false), automaticBootstrap: false)
        await model.bootstrap()
        model.openSpace(f.imported.space.id)
        try await waitUntil { model.presentationDocument != nil }
        let original = try f.database.fetchReadingProgress(spaceID: f.imported.space.id)
        model.prepareBilingualReading(useSelection: false)
        try await waitUntil { !model.bilingualReading.isBusy }
        model.bilingualReading.layout = .translation
        model.bilingualReading.targetLanguage = .english
        XCTAssertEqual(try f.database.fetchReadingProgress(spaceID: f.imported.space.id), original)
        let segment = try XCTUnwrap(model.bilingualReading.rows.last?.segment)
        model.updateBilingualReadingPosition(segment.locator)
        model.flushReadingPosition()
        XCTAssertEqual(try f.database.fetchReadingProgress(spaceID: f.imported.space.id).sourcePositions[f.imported.source.id]?.locator, segment.locator)
        let reopened = try LibraryDatabase(rootURL: f.root.appendingPathComponent("Library"))
        XCTAssertEqual(try reopened.fetchReadingProgress(spaceID: f.imported.space.id).sourcePositions[f.imported.source.id]?.locator, segment.locator)
        XCTAssertEqual(try f.database.fetchSnapshots(sourceID: f.imported.source.id).first?.digest, f.imported.snapshot.digest)
    }

    private func waitUntil(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while try await !predicate() {
            if ContinuousClock.now >= deadline { throw ReadingAgentError.interrupted }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor TranslationTrace {
    var ids: [String] = []
    var count: Int { ids.count }
    func record(_ id: String) -> Int { ids.append(id); return ids.count }
}

private struct TranslationFakeFactory: ReadingAgentDriverFactory {
    let trace: TranslationTrace
    let failCall: Int?
    let delay: Bool
    func makeDriver(context: AgentDriverContext) -> any ReadingAgentModelDriver {
        TranslationFakeDriver(trace: trace, failCall: failCall, delay: delay, context: context)
    }
}

private struct TranslationFakeDriver: ReadingAgentModelDriver {
    let trace: TranslationTrace
    let failCall: Int?
    let delay: Bool
    let context: AgentDriverContext
    func generate(_ request: AgentModelRequest, runtime: ReadingToolRuntime, previousTranscript: Data?) async throws -> AgentModelResult {
        _ = try await context.budget.consumeModelRound()
        let values = try XCTUnwrap(request.request.translation?.segments)
        let call = await trace.record(values[0].id)
        if delay { try? await Task.sleep(for: .milliseconds(120)) }
        if call == failCall { throw ReadingAgentError.providerUnavailable("fake-disconnect") }
        return AgentModelResult(output: .translation(TranslationDraft(schemaVersion: 1, segments: values.map {
            TranslationDraft.Segment(id: $0.id, originalDigest: $0.originalDigest, translatedText: "译文 " + $0.modelText)
        })), usage: nil)
    }
}

private struct TranslationFixture {
    let root: URL
    let database: LibraryDatabase
    let imported: ManagedImportResult
    let coordinator: AdapterCoordinator
    let registry: AdapterRegistry
    let plan: AdapterPlan
    let document: PresentationDocument
    let segments: [TranslationSegment]
    let profile: ProviderProfile
    let settings: TranslationSettings
    let secrets: InMemoryProviderSecretStore
    var manifest: [String: String] { [imported.source.id: imported.snapshot.id] }

    static func make(remote: Bool = false) async throws -> TranslationFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OneReader-Translation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("Fixture.md")
        try Data("# Fixture\n\nDo not send private notes.\n\nNumbers: 42 and 3.14, not 41.\n".utf8).write(to: input)
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: LibraryStoragePolicy(largeImportThreshold: .max, minimumFreeCapacity: 0, capacityProvider: { _ in .max }))
        let imported = try await library.importLocalSource(at: input)
        let registry = try AdapterRegistry.standard(), coordinator = AdapterCoordinator(database: database, registry: registry)
        let plan = try await coordinator.prepare(sourceID: imported.source.id, snapshotID: imported.snapshot.id)
        let document = try await coordinator.render(plan: plan)
        let segments = try await TranslationSourceBuilder.prepare(document: document, locator: document.locator,
            nextLocator: nil, selection: nil, plan: plan, coordinator: coordinator, database: database)
        let secrets = InMemoryProviderSecretStore()
        let reference = remote ? await secrets.save(secret: "test-secret", reference: nil) : nil
        let profile = ProviderProfile(displayName: "Fake model", kind: remote ? .openAIResponses : .ollama,
            endpoint: URL(string: remote ? "https://example.invalid/v1" : "http://127.0.0.1:11434"),
            modelID: "fixture", keychainReference: reference, isDefault: true)
        try database.saveProviderProfile(profile)
        return TranslationFixture(root: root, database: database, imported: imported,
            coordinator: coordinator, registry: registry, plan: plan, document: document, segments: segments,
            profile: profile, settings: try TranslationSettings(sourceLanguage: .automatic, targetLanguage: .simplifiedChinese, profile: profile), secrets: secrets)
    }
    func request(segments: [TranslationSegment]) -> AgentRunRequest {
        AgentRunRequest(spaceID: imported.space.id, task: .translateFragments,
            targetSourceID: imported.source.id, targetSnapshotID: imported.snapshot.id,
            expectedSnapshotIDs: Set(manifest.values), snapshotManifest: manifest,
            translation: TranslationRequest(settings: settings, segments: segments))
    }
    func runtime(trace: TranslationTrace, failCall: Int? = nil, delay: Bool = false) -> ReadingAgentRuntime {
        ReadingAgentRuntime(database: database, toolHost: ReadingToolHost(database: database, coordinator: coordinator, registry: registry),
            validator: AgentOutputValidator(database: database, registry: registry), secretStore: secrets,
            driverFactory: TranslationFakeFactory(trace: trace, failCall: failCall, delay: delay))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
