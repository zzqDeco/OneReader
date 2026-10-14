import AppKit
import SwiftUI
import XCTest
@testable import OneReader

@MainActor
final class ReaderChromeLayoutTests: XCTestCase {
    func testTouchActionsHaveAtLeast44PointTargets() {
        XCTAssertGreaterThanOrEqual(ReaderChromeMetrics.minimumActionHeight(touch: true), 44)
        XCTAssertGreaterThanOrEqual(ReaderChromeMetrics.minimumActionHeight(touch: false), 28)
    }

    func testAccessibilityShelfUsesWiderCardsThanCompactShelf() {
        let compact = ReaderChromeMetrics.shelfMinimumWidth(compact: true, accessibilitySize: false)
        let accessible = ReaderChromeMetrics.shelfMinimumWidth(compact: true, accessibilitySize: true)
        XCTAssertGreaterThan(accessible, compact)
        XCTAssertLessThanOrEqual(accessible, 280)
    }

    @MainActor
    func testPersistentExportFitsNarrowFooterAtAccessibilitySize() async throws {
        var exports = 0
        let host = NSHostingView(rootView: NotesCenterFooter(totalCount: 120, selectedCount: 4,
            onExport: { exports += 1 }, onDelete: {})
            .environment(\.dynamicTypeSize, .accessibility3))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 240),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 240)
        host.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (exportButton(in: host)?.frame.width ?? 0) <= 0 {
            guard ContinuousClock.now < deadline else {
                XCTFail("Narrow footer lost its persistent native export action")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        let button = try XCTUnwrap(exportButton(in: host))
        XCTAssertEqual(exportButtons(in: host).count, 1, "Adaptive layout must not duplicate the native export action")
        let rect = host.convert(button.bounds, from: button)
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThanOrEqual(rect.minX, -1)
        XCTAssertLessThanOrEqual(rect.maxX, host.bounds.maxX + 1)
        XCTAssertEqual(button.accessibilityIdentifier(), "notes-export")
        XCTAssertTrue(button.isEnabled)
        button.performClick(nil)
        XCTAssertEqual(exports, 1)
    }

    private func exportButton(in view: NSView) -> NSButton? {
        exportButtons(in: view).first
    }

    private func exportButtons(in view: NSView) -> [NSButton] {
        let own: [NSButton]
        if let button = view as? NSButton, button.accessibilityIdentifier() == "notes-export" {
            own = [button]
        } else { own = [] }
        return own + view.subviews.flatMap { self.exportButtons(in: $0) }
    }
}
