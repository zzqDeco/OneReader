import AppKit
import SwiftUI
import XCTest
import GRDB
@testable import OneReader

@MainActor
final class NotesPresentationTests: XCTestCase {
    func testInitialAndDebouncedQueriesCannotClaimEmptyResults() {
        var state = NotesRefreshPresentation()
        let first = key()
        XCTAssertEqual(state.phase(current: first, isLoading: false,
            entryCount: 0), .loading)
        XCTAssertTrue(state.complete(first, current: first, cancelled: false))
        XCTAssertEqual(state.phase(current: first, isLoading: false,
            entryCount: 0), .empty)
        let changed = key(search: "new query", revision: first.revision)
        XCTAssertEqual(state.phase(current: changed, isLoading: false,
            entryCount: 0), .loading)
        XCTAssertTrue(state.isUpdating(current: changed, isLoading: false))
    }

    func testCancelledAndOldRevisionCompletionsDoNotSettleCurrentResults() {
        var state = NotesRefreshPresentation()
        let first = key()
        XCTAssertFalse(state.complete(first, current: first, cancelled: true))
        XCTAssertFalse(state.complete(first, current: first, cancelled: false,
            outcome: .superseded))
        XCTAssertNil(state.settledKey)
        let replacement = key()
        XCTAssertFalse(state.complete(first, current: replacement, cancelled: false))
        XCTAssertNil(state.settledKey)
        XCTAssertTrue(state.complete(replacement, current: replacement, cancelled: false))
        XCTAssertEqual(state.settledKey, replacement)
        XCTAssertFalse(state.complete(first, current: replacement, cancelled: false))
        XCTAssertEqual(state.settledKey, replacement)
    }

    func testLoadErrorIsFailureNotEmptyAndOldErrorDoesNotMaskPendingQuery() {
        var state = NotesRefreshPresentation()
        let first = key()
        state.complete(first, current: first, cancelled: false, outcome: .failed("read failed"))
        XCTAssertEqual(state.phase(current: first, isLoading: false,
            entryCount: 0), .failed)
        XCTAssertEqual(state.loadError(current: first), "read failed")
        XCTAssertEqual(state.phase(current: first, isLoading: true,
            entryCount: 0), .loading)
        let changed = key(search: "changed", revision: first.revision)
        XCTAssertEqual(state.phase(current: changed, isLoading: false,
            entryCount: 0), .loading)
        XCTAssertNil(state.loadError(current: changed))
        XCTAssertEqual(state.phase(current: changed, isLoading: false,
            entryCount: 3), .loading)
    }

    func testPaginationRetainsSettledResultsWhileLoadingMore() {
        var state = NotesRefreshPresentation()
        let current = key()
        state.complete(current, current: current, cancelled: false)
        XCTAssertEqual(state.phase(current: current, isLoading: true,
            entryCount: 4), .results)
        XCTAssertEqual(state.phase(current: current, isLoading: false,
            entryCount: 4), .results)
    }

    func testFailedChangedQueryCannotExposePreviousCountOrNativeExport() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = NotesCenterModel(database: fixture.database, onMutation: {}, onOpen: { _ in })
        var state = NotesRefreshPresentation()
        let first = NotesRefreshKey(query: model.query, revision: model.revision)
        let loaded = await model.reload()
        XCTAssertEqual(loaded, .loaded)
        state.complete(first, current: first, cancelled: false, outcome: loaded)
        XCTAssertEqual(state.visibleTotalCount(current: first, totalCount: model.totalCount), 1)

        // Close only this test-owned pool, never delete/corrupt a production table.
        try fixture.database.pool.close()
        model.query.search = "a different query"
        let changed = NotesRefreshKey(query: model.query, revision: model.revision)
        let failed = await model.reload()
        guard case .failed = failed else { return XCTFail("Closed-pool read must fail") }
        state.complete(changed, current: changed, cancelled: false, outcome: failed)
        XCTAssertEqual(model.totalCount, 1, "The legacy model count is not an authoritative read receipt")
        XCTAssertEqual(state.visibleTotalCount(current: changed, totalCount: model.totalCount), 0)
        XCTAssertEqual(state.phase(current: changed, isLoading: model.isLoading,
            entryCount: model.entries.count), .failed)

        var exports = 0
        // Defense in depth: unavailable state is inert even if a caller supplies an old count.
        let host = NSHostingView(rootView: NotesCenterFooter(totalCount: model.totalCount,
            selectedCount: 1, isUnavailable: true, onExport: { exports += 1 }, onDelete: {}))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 660, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = CGRect(x: 0, y: 0, width: 660, height: 120)
        try await waitForExport(in: host, enabled: false)
        try XCTUnwrap(exportButton(in: host)).performClick(nil)
        XCTAssertEqual(exports, 0)
    }

    func testDelayedOpenErrorCannotReplaceSuccessfulEmptyQueryOutcome() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = NotesOpenFailureGate()
        let model = NotesCenterModel(database: fixture.database, onMutation: {}, onOpen: { _ in
            await gate.pause()
            throw NotesOpenFixtureError.expected
        })
        await model.reload()
        let entry = try XCTUnwrap(model.entries.first)
        let opening = Task { await model.open(entry) }
        await gate.waitUntilPaused()
        model.query.search = "no matching annotations"
        let current = NotesRefreshKey(query: model.query, revision: model.revision)
        let outcome = await model.reload()
        XCTAssertEqual(outcome, .loaded)
        var state = NotesRefreshPresentation()
        state.complete(current, current: current, cancelled: false, outcome: outcome)
        await gate.release()
        await opening.value
        XCTAssertNil(model.errorMessage, "An old navigation error must not overwrite a new query")
        XCTAssertNil(state.loadError(current: current))
        XCTAssertEqual(state.phase(current: current, isLoading: model.isLoading,
            entryCount: model.entries.count), .empty)
        XCTAssertEqual(state.visibleTotalCount(current: current, totalCount: model.totalCount), 0)
    }

    func testCurrentOpenFailureIsActionErrorNotReloadFailure() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = NotesCenterModel(database: fixture.database, onMutation: {}, onOpen: { _ in
            throw NotesOpenFixtureError.expected
        })
        let current = NotesRefreshKey(query: model.query, revision: model.revision)
        let outcome = await model.reload()
        var state = NotesRefreshPresentation()
        state.complete(current, current: current, cancelled: false, outcome: outcome)
        await model.open(try XCTUnwrap(model.entries.first))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(state.loadError(current: current))
        XCTAssertEqual(state.phase(current: current, isLoading: model.isLoading,
            entryCount: model.entries.count), .results)
        XCTAssertEqual(state.visibleTotalCount(current: current, totalCount: model.totalCount), 1)
    }

    func testCancelledOpeningDiscardsNonCooperativeLateError() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = NotesOpenFailureGate()
        let model = NotesCenterModel(database: fixture.database, onMutation: {}, onOpen: { _ in
            await gate.pause()
            throw NotesOpenFixtureError.expected
        })
        await model.reload()
        let entry = try XCTUnwrap(model.entries.first)
        let opening = Task { await model.open(entry) }
        await gate.waitUntilPaused()
        model.cancelOpening()
        await gate.release()
        await opening.value
        XCTAssertNil(model.errorMessage)
    }

    func testSharedReloadPublishesMatchingReceiptForBothMountedQueryOwners() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = NotesCenterModel(database: fixture.database, onMutation: {}, onOpen: { _ in })
        let current = NotesRefreshKey(query: model.query, revision: model.revision)
        let first = Task { await model.reload() }
        let second = Task { await model.reload() }
        let outcomes = await (first.value, second.value)
        XCTAssertTrue(outcomes.0 == .loaded || outcomes.1 == .loaded)
        let receipt = try XCTUnwrap(model.lastReloadReceipt)
        XCTAssertEqual(receipt.query, current.query)
        XCTAssertEqual(receipt.revision, current.revision)
        XCTAssertEqual(receipt.outcome, .loaded)
        for _ in 0..<2 {
            var presentation = NotesRefreshPresentation()
            presentation.complete(NotesRefreshKey(query: receipt.query, revision: receipt.revision),
                current: current, cancelled: false, outcome: receipt.outcome)
            XCTAssertEqual(presentation.phase(current: current, isLoading: model.isLoading,
                entryCount: model.entries.count), .results)
            XCTAssertEqual(presentation.visibleTotalCount(current: current, totalCount: model.totalCount), 1)
        }
    }

    func testLocalizedStatusesRetainHistoricalAndOrphanedDistinctions() {
        XCTAssertEqual(ReaderAnnotationStatus(anchorState: .current).title, "当前版本")
        XCTAssertEqual(ReaderAnnotationStatus(anchorState: .relocated).title, "已重定位")
        XCTAssertEqual(ReaderAnnotationStatus(anchorState: .orphaned).title, "位置待恢复")
        XCTAssertEqual(ReaderAnnotationStatus(anchorState: .current,
            isLatestSnapshot: false).title, "历史版本")
        XCTAssertEqual(ReaderAnnotationStatus(anchorState: .relocated,
            isLatestSnapshot: false).title, "历史版本 · 已重定位")
        XCTAssertEqual(ReaderAnnotationStatus(anchorState: .orphaned,
            isLatestSnapshot: false).title, "历史版本 · 位置待恢复")
        let unavailable = ReaderAnnotationStatus(anchorState: .current,
            sourceAvailable: false)
        XCTAssertEqual(unavailable.title, "来源不可用")
        XCTAssertTrue(unavailable.isWarning)
        XCTAssertTrue(ReaderAnnotationStatus(anchorState: .current,
            isLatestSnapshot: false).isWarning)
        XCTAssertTrue(ReaderAnnotationStatus(anchorState: .orphaned).isWarning)
        XCTAssertFalse(ReaderAnnotationStatus(anchorState: .relocated).isWarning)
        XCTAssertEqual(AnnotationAnchorState.current.rawValue, "current")
        XCTAssertEqual(AnnotationAnchorState.relocated.rawValue, "relocated")
        XCTAssertEqual(AnnotationAnchorState.orphaned.rawValue, "orphaned")
    }

    func testRefreshingFooterKeepsNativeExportVisibleButInertUntilSettled() async throws {
        var exports = 0
        let host = NSHostingView(rootView: NotesCenterFooter(totalCount: 4, selectedCount: 1,
            isUpdating: true, onExport: { exports += 1 }, onDelete: {}))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 660, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = CGRect(x: 0, y: 0, width: 660, height: 120)
        try await waitForExport(in: host, enabled: false)
        let disabled = try XCTUnwrap(exportButton(in: host))
        XCTAssertGreaterThan(disabled.frame.width, 0)
        XCTAssertEqual(disabled.keyEquivalent, "e")
        disabled.performClick(nil)
        XCTAssertEqual(exports, 0)
        host.rootView = NotesCenterFooter(totalCount: 4, selectedCount: 1,
            isUpdating: false, onExport: { exports += 1 }, onDelete: {})
        try await waitForExport(in: host, enabled: true)
        try XCTUnwrap(exportButton(in: host)).performClick(nil)
        XCTAssertEqual(exports, 1)
    }

    private func key(search: String = "", revision: UUID = UUID()) -> NotesRefreshKey {
        NotesRefreshKey(query: NotesQuery(search: search), revision: revision)
    }

    private func fixture() async throws -> (root: URL, database: LibraryDatabase) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesPresentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Notes UI State.txt")
        try Data("Generated local state fixture.".utf8).write(to: source)
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy:
            LibraryStoragePolicy(largeImportThreshold: .max, minimumFreeCapacity: 0,
                capacityProvider: { _ in .max }))
        let imported = try await library.importLocalSource(at: source)
        let locator = Locator(sourceID: imported.source.id, snapshotID: imported.snapshot.id,
            adapterID: "text", payload: [:])
        try database.saveAnnotation(Annotation(id: UUID().uuidString, spaceID: imported.space.id,
            sourceID: imported.source.id, snapshotID: imported.snapshot.id, kind: .note,
            locator: locator, anchorState: .current, selectedText: nil, note: "Retained note",
            color: nil, createdAt: .now, updatedAt: .now))
        return (root, database)
    }

    private func waitForExport(in host: NSView, enabled: Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let button = exportButton(in: host), button.frame.width > 0,
               button.isEnabled == enabled { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Export button did not reflect the current refresh state")
    }

    private func exportButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == "notes-export" {
            return button
        }
        return view.subviews.lazy.compactMap { self.exportButton(in: $0) }.first
    }
}

private enum NotesOpenFixtureError: LocalizedError {
    case expected
    var errorDescription: String? { "Generated original-opening failure" }
}

private actor NotesOpenFailureGate {
    private var paused = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        paused = true
        waiters.forEach { $0.resume() }
        waiters = []
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
