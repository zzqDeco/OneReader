import AppKit
import SwiftUI
import XCTest
@testable import OneReader

@MainActor
final class NotesPresentationTests: XCTestCase {
    func testInitialAndDebouncedQueriesCannotClaimEmptyResults() {
        var state = NotesRefreshPresentation()
        let first = key()
        XCTAssertEqual(state.phase(current: first, isLoading: false,
            entryCount: 0, loadError: nil), .loading)
        XCTAssertTrue(state.complete(first, current: first, cancelled: false))
        XCTAssertEqual(state.phase(current: first, isLoading: false,
            entryCount: 0, loadError: nil), .empty)
        let changed = key(search: "new query", revision: first.revision)
        XCTAssertEqual(state.phase(current: changed, isLoading: false,
            entryCount: 0, loadError: nil), .loading)
        XCTAssertTrue(state.isUpdating(current: changed, isLoading: false))
    }

    func testCancelledAndOldRevisionCompletionsDoNotSettleCurrentResults() {
        var state = NotesRefreshPresentation()
        let first = key()
        XCTAssertFalse(state.complete(first, current: first, cancelled: true))
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
        state.complete(first, current: first, cancelled: false)
        XCTAssertEqual(state.phase(current: first, isLoading: false,
            entryCount: 0, loadError: "read failed"), .failed)
        XCTAssertEqual(state.phase(current: first, isLoading: true,
            entryCount: 0, loadError: "old failure"), .loading)
        let changed = key(search: "changed", revision: first.revision)
        XCTAssertEqual(state.phase(current: changed, isLoading: false,
            entryCount: 0, loadError: "old failure"), .loading)
        XCTAssertEqual(state.phase(current: changed, isLoading: false,
            entryCount: 3, loadError: "old failure"), .loading)
    }

    func testPaginationRetainsSettledResultsWhileLoadingMore() {
        var state = NotesRefreshPresentation()
        let current = key()
        state.complete(current, current: current, cancelled: false)
        XCTAssertEqual(state.phase(current: current, isLoading: true,
            entryCount: 4, loadError: nil), .results)
        XCTAssertEqual(state.phase(current: current, isLoading: false,
            entryCount: 4, loadError: "pagination failed"), .results)
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
