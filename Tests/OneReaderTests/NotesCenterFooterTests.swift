import AppKit
import SwiftUI
import XCTest
@testable import OneReader

@MainActor
final class NotesCenterFooterTests: XCTestCase {
    func testExportIsAccessibleWithoutSelectingNotes() async throws {
        try await verify(total: 1, selected: 0, exportEnabled: true)
    }

    func testEmptyLibraryStillShowsDisabledExportAction() async throws {
        try await verify(total: 0, selected: 0, exportEnabled: false)
    }

    func testSelectionKeepsExportVisible() async throws {
        try await verify(total: 1, selected: 1, exportEnabled: true)
    }

    func testAsyncReloadEnablesExportAndUsesLatestAction() async throws {
        var oldCount = 0; var newCount = 0
        let host = NSHostingView(rootView: NotesCenterFooter(totalCount: 0, selectedCount: 0,
            onExport: { oldCount += 1 }, onDelete: {}))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 660, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = window.contentView!.bounds; host.layoutSubtreeIfNeeded()
        XCTAssertFalse(try XCTUnwrap(exportButton(in: host)).isEnabled)
        host.rootView = NotesCenterFooter(totalCount: 1, selectedCount: 0,
            onExport: { newCount += 1 }, onDelete: {})
        host.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while exportButton(in: host)?.isEnabled != true {
            guard ContinuousClock.now < deadline else { XCTFail("Loaded notes did not enable export"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try XCTUnwrap(exportButton(in: host)).performClick(nil)
        XCTAssertEqual(oldCount, 0)
        XCTAssertEqual(newCount, 1)
    }

    private func verify(total: Int, selected: Int, exportEnabled: Bool) async throws {
        var exportCount = 0
        let host = NSHostingView(rootView: NotesCenterFooter(totalCount: total, selectedCount: selected,
            onExport: { exportCount += 1 }, onDelete: {}))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 660, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = CGRect(x: 0, y: 0, width: 660, height: 100); host.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while exportButton(in: host) == nil {
            guard ContinuousClock.now < deadline else {
                XCTFail("Persistent export button is missing from the mounted native view hierarchy")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let export = try XCTUnwrap(exportButton(in: host))
        XCTAssertEqual(export.accessibilityRole(), .button)
        XCTAssertEqual(export.isEnabled, exportEnabled)
        XCTAssertEqual(export.keyEquivalent, "e")
        XCTAssertEqual(export.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertGreaterThan(export.frame.width, 0)
        XCTAssertGreaterThan(export.frame.height, 0)
        export.performClick(nil)
        XCTAssertEqual(exportCount, exportEnabled ? 1 : 0)
    }

    private func exportButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == "notes-export" { return button }
        return view.subviews.lazy.compactMap { self.exportButton(in: $0) }.first
    }
}
