#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import OneReader

@MainActor
final class ReaderSurfaceChromeLayoutTests: XCTestCase {
    func testSharedFooterKeepsIndependentTargetsWithLongPositionAtWideNarrowAndAccessibleSizes() async throws {
        let position = ReadingPositionDisplayState()
        position.update(String(repeating: "很长的已记录阅读位置说明", count: 12))
        let host = NSHostingView(rootView: sharedFooter(position: position, size: .large, revision: 0))
        let window = mount(host, width: 520, height: 360)
        defer { window.contentView = nil; window.close() }
        guard try await waitForLayout(in: host, stage: "shared-footer/wide-long-position", condition: {
            nativeButtonViews(in: $0).count == 5 && probeViews(in: $0).count == 5
                && probes(in: $0).values.allSatisfy { $0.frame.height >= 27 }
                && distinctRows(Array(probes(in: $0).values), in: $0) == 1
        }) else { return }
        let originalButtons = nativeButtons(in: host)
        let originalTargets = probes(in: host)
        XCTAssertEqual(Set(originalButtons.keys), ["previous", "next", "bookmark", "highlight", "note"])
        XCTAssertTrue(originalButtons.values.allSatisfy { !$0.isEnabled })
        assertContained(Array(originalTargets.values), in: host, minimumHeight: 28)

        resize(host, in: window, width: 300, height: 360)
        guard try await waitForLayout(in: host, stage: "shared-footer/narrow-long-position", condition: {
            nativeButtonViews(in: $0).count == 5 && probeViews(in: $0).count == 5
                && distinctRows(Array(probes(in: $0).values), in: $0) == 2
        }) else { return }
        assertContained(Array(probes(in: host).values), in: host, minimumHeight: 28)
        host.rootView = sharedFooter(position: position, size: .accessibility3, revision: 1)
        guard try await waitForLayout(in: host, stage: "shared-footer/accessibility3-current-receipt", condition: {
            let controls = nativeButtons(in: $0)
            return probeViews(in: $0).count == 5 && distinctRows(Array(probes(in: $0).values), in: $0) == 5
                && nativeButtonViews(in: $0).count == 5 && controls.count == 5
                && controls.values.allSatisfy { $0.currentRevision == 1 }
        }) else { return }
        for (identifier, button) in nativeButtons(in: host) {
            let original = try XCTUnwrap(originalButtons[identifier])
            XCTAssertTrue(button === original, "The shared footer must retain each independent native action")
        }
        for (identifier, target) in probes(in: host) {
            let original = try XCTUnwrap(originalTargets[identifier])
            XCTAssertTrue(target === original, "Reflow must retain each action's label-sized receipt")
        }
        assertContained(Array(probes(in: host).values), in: host, minimumHeight: 28)
    }

    func testAdaptiveActionsKeepOneNativeControlAcrossWidthAndTypeChanges() async throws {
        var firstActions = 0
        var replacementActions = 0
        let host = NSHostingView(rootView: nativeActions(size: .large, revision: 0) { firstActions += 1 })
        let window = mount(host, width: 680, height: 320)
        defer { window.contentView = nil; window.close() }
        guard try await waitForLayout(in: host, stage: "native-actions/initial-wide", condition: {
            nativeButtonViews(in: $0).count == 6 && probeViews(in: $0).count == 6
                && nativeButtonViews(in: $0).allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 }
                && probes(in: $0).values.allSatisfy { $0.frame.height >= 27 }
        }) else { return }
        let original = nativeButtons(in: host)
        assertContained(Array(probes(in: host).values), in: host, minimumHeight: 28)
        try XCTUnwrap(original["bookmark"]).performClick(nil)
        XCTAssertEqual(firstActions, 1)

        resize(host, in: window, width: 300, height: 320)
        guard try await waitForLayout(in: host, stage: "native-actions/narrow-vertical", condition: {
            nativeButtonViews(in: $0).count == 6 && distinctRows(Array(probes(in: $0).values), in: $0) == 6
        }) else { return }
        assertContained(Array(probes(in: host).values), in: host, minimumHeight: 28)
        resize(host, in: window, width: 680, height: 320)
        guard try await waitForLayout(in: host, stage: "native-actions/wide-horizontal-again", condition: {
            nativeButtonViews(in: $0).count == 6 && distinctRows(Array(probes(in: $0).values), in: $0) == 1
        }) else { return }
        host.rootView = nativeActions(size: .accessibility3, revision: 1) { replacementActions += 1 }
        guard try await waitForLayout(in: host, stage: "native-actions/accessibility3-latest-action", condition: {
            let controls = nativeButtons(in: $0)
            return nativeButtonViews(in: $0).count == 6 && distinctRows(Array(probes(in: $0).values), in: $0) == 6
                && controls.values.allSatisfy { $0.currentRevision == 1 }
        }) else { return }
        let replaced = nativeButtons(in: host)
        for (identifier, button) in replaced {
            let originalButton = try XCTUnwrap(original[identifier])
            XCTAssertTrue(button === originalButton, "Reflow must not replace the native \(identifier) control")
        }
        assertContained(Array(probes(in: host).values), in: host, minimumHeight: 28)
        XCTAssertFalse(try XCTUnwrap(replaced["complete"]).isEnabled)
        try XCTUnwrap(replaced["bookmark"]).performClick(nil)
        XCTAssertEqual(firstActions, 1)
        XCTAssertEqual(replacementActions, 1, "Retained controls must use the latest action")
    }

    func testCompactActionsKeepTouchTargetsAndGainRowsBeforeClipping() async throws {
        let host = NSHostingView(rootView: compactActions(size: .large))
        let window = mount(host, width: 375, height: 360)
        defer { window.contentView = nil; window.close() }
        guard try await waitForLayout(in: host, stage: "compact/375-large", condition: {
            probeViews(in: $0).count == 5 && probes(in: $0).values.allSatisfy { $0.frame.height >= 43 }
        }) else { return }
        let original = probes(in: host)
        XCTAssertEqual(distinctRows(Array(original.values), in: host), 1)
        assertContained(Array(original.values), in: host, minimumHeight: 44, minimumWidth: 44)
        resize(host, in: window, width: 320, height: 360)
        guard try await waitForLayout(in: host, stage: "compact/320-large", condition: {
            probeViews(in: $0).count == 5 && distinctRows(Array(probes(in: $0).values), in: $0) == 2
        }) else { return }
        assertContained(Array(probes(in: host).values), in: host, minimumHeight: 44, minimumWidth: 44)
        host.rootView = compactActions(size: .xxLarge)
        guard try await waitForLayout(in: host, stage: "compact/320-xxLarge", condition: {
            let controls = Array(probes(in: $0).values)
            return probeViews(in: $0).count == 5 && distinctRows(controls, in: $0) == 2
                && distinctColumns(controls, in: $0) == 3
        }) else { return }
        host.rootView = compactActions(size: .accessibility3)
        guard try await waitForLayout(in: host, stage: "compact/320-accessibility3", condition: {
            probeViews(in: $0).count == 5 && distinctRows(Array(probes(in: $0).values), in: $0) == 3
        }) else { return }
        for (identifier, probe) in probes(in: host) {
            let originalProbe = try XCTUnwrap(original[identifier])
            XCTAssertTrue(probe === originalProbe, "Compact reflow must retain the \(identifier) action tree")
        }
        assertContained(Array(probes(in: host).values), in: host, minimumHeight: 44, minimumWidth: 44)
    }

    func testPDFZoomFitWidthMovesBelowUncompressedPercentageAndKeepsTouchHeight() async throws {
        let host = NSHostingView(rootView: pdfZoom(size: .large))
        let window = mount(host, width: 375, height: 220)
        defer { window.contentView = nil; window.close() }
        guard try await waitForLayout(in: host, stage: "pdf-zoom/375-large", condition: {
            probeViews(in: $0).count == 2 && probes(in: $0).values.allSatisfy { $0.frame.height >= 43 }
        }) else { return }
        XCTAssertEqual(distinctRows(Array(probes(in: host).values), in: host), 1)
        resize(host, in: window, width: 200, height: 220)
        guard try await waitForLayout(in: host, stage: "pdf-zoom/200-fit-width-below", condition: {
            probeViews(in: $0).count == 2 && distinctRows(Array(probes(in: $0).values), in: $0) == 2
        }) else { return }
        assertContained(Array(probes(in: host).values), in: host, minimumHeight: 44)
        let adjustment = try XCTUnwrap(probes(in: host)["pdf-adjustments"])
        XCTAssertGreaterThanOrEqual(host.convert(adjustment.bounds, from: adjustment).width, 156,
            "Two 44-point controls, two gaps and the full percentage must remain visible")
        resize(host, in: window, width: 375, height: 220)
        guard try await waitForLayout(in: host, stage: "pdf-zoom/375-horizontal-again", condition: {
            probeViews(in: $0).count == 2 && distinctRows(Array(probes(in: $0).values), in: $0) == 1
        }) else { return }
        host.rootView = pdfZoom(size: .accessibility3)
        guard try await waitForLayout(in: host, stage: "pdf-zoom/375-accessibility3", condition: {
            probeViews(in: $0).count == 2 && distinctRows(Array(probes(in: $0).values), in: $0) == 2
        }) else { return }
        assertContained(Array(probes(in: host).values), in: host, minimumHeight: 44)
    }

    private func nativeActions(size: DynamicTypeSize, revision: Int, onAction: @escaping () -> Void) -> some View {
        ReaderSurfaceAdaptiveActions(horizontalSpacing: 12) {
            ForEach(["previous", "next", "complete", "bookmark", "highlight", "note"], id: \.self) { identifier in
                self.nativeTarget(identifier: identifier, enabled: identifier != "complete",
                    revision: revision, onAction: onAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.dynamicTypeSize, size)
    }

    /// Exercises the exact production grouping and observed position badge.
    /// Actual ReaderSurface button actions/accessibility remain a native-App gate.
    private func sharedFooter(position: ReadingPositionDisplayState, size: DynamicTypeSize, revision: Int) -> some View {
        ReaderSurfaceFooterLayout(positionState: position, navigation: {
            ReaderSurfaceAdaptiveActions(horizontalSpacing: 12) {
                nativeTarget(identifier: "previous", enabled: false, revision: revision, onAction: {})
                nativeTarget(identifier: "next", enabled: false, revision: revision, onAction: {})
            }
        }, actions: {
            ReaderSurfaceAdaptiveActions(horizontalSpacing: 8) {
                nativeTarget(identifier: "bookmark", enabled: false, revision: revision, onAction: {})
                nativeTarget(identifier: "highlight", enabled: false, revision: revision, onAction: {})
                nativeTarget(identifier: "note", enabled: false, revision: revision, onAction: {})
            }
        })
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.dynamicTypeSize, size)
    }

    private func nativeTarget(identifier: String, enabled: Bool, revision: Int,
        onAction: @escaping () -> Void) -> some View {
        ChromeNativeAction(identifier: identifier, enabled: enabled, revision: revision, onAction: onAction)
            .frame(width: identifier == "complete" ? 132 : 64, height: 28)
            .overlay { ChromeLayoutProbe(identifier: "target-\(identifier)", revision: revision).allowsHitTesting(false).accessibilityHidden(true) }
    }

    private func compactActions(size: DynamicTypeSize) -> some View {
        ReaderSurfaceCompactBar {
            ReaderSurfaceCompactAction(title: "目录", systemImage: "list.bullet", action: {})
                .overlay { ChromeLayoutProbe(identifier: "outline").allowsHitTesting(false).accessibilityHidden(true) }
            ReaderSurfaceCompactAction(title: "上一项", systemImage: "chevron.left", isDisabled: true, action: {})
                .overlay { ChromeLayoutProbe(identifier: "previous").allowsHitTesting(false).accessibilityHidden(true) }
            ReaderSurfaceCompactAction(title: "下一项", systemImage: "chevron.right", action: {})
                .overlay { ChromeLayoutProbe(identifier: "next").allowsHitTesting(false).accessibilityHidden(true) }
            ReaderSurfaceCompactAction(title: "笔记", systemImage: "note.text", action: {})
                .overlay { ChromeLayoutProbe(identifier: "notes").allowsHitTesting(false).accessibilityHidden(true) }
            ReaderSurfaceCompactAction(title: "识别", systemImage: "text.viewfinder", action: {})
                .overlay { ChromeLayoutProbe(identifier: "ocr").allowsHitTesting(false).accessibilityHidden(true) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.dynamicTypeSize, size)
    }

    private func pdfZoom(size: DynamicTypeSize) -> some View {
        let controls = ReaderSurfacePDFZoomControls(zoomFactor: 15, onAction: { _ in })
        return ReaderSurfaceAdaptiveActions(horizontalSpacing: 12, verticalSpacing: 4) {
            controls.adjustmentControls.overlay { ChromeLayoutProbe(identifier: "pdf-adjustments").allowsHitTesting(false).accessibilityHidden(true) }
            controls.fitWidthControl.overlay { ChromeLayoutProbe(identifier: "pdf-fit").allowsHitTesting(false).accessibilityHidden(true) }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.dynamicTypeSize, size)
    }

    private func mount<Content: View>(_ host: NSHostingView<Content>, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func resize(_ host: NSView, in window: NSWindow, width: CGFloat, height: CGFloat) {
        window.setContentSize(CGSize(width: width, height: height))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
    }

    private func waitForLayout(in host: NSView, stage: String, file: StaticString = #filePath,
        line: UInt = #line, condition: (NSView) -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if condition(host) { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Reader chrome timed out at \(stage): \(layoutDiagnostics(in: host))", file: file, line: line)
        return false
    }

    private func distinctRows(_ views: [NSView], in host: NSView) -> Int {
        Set(views.map { Int(host.convert($0.bounds, from: $0).midY.rounded()) }).count
    }

    private func distinctColumns(_ views: [NSView], in host: NSView) -> Int {
        Set(views.map { Int(host.convert($0.bounds, from: $0).midX.rounded()) }).count
    }

    private func assertContained(_ views: [NSView], in host: NSView, minimumHeight: CGFloat,
        minimumWidth: CGFloat = 1, file: StaticString = #filePath, line: UInt = #line) {
        for view in views {
            let rect = host.convert(view.bounds, from: view)
            XCTAssertGreaterThanOrEqual(rect.width, minimumWidth - 1, file: file, line: line)
            XCTAssertGreaterThanOrEqual(rect.height, minimumHeight - 1, file: file, line: line)
            XCTAssertGreaterThanOrEqual(rect.minX, -1, file: file, line: line)
            XCTAssertGreaterThanOrEqual(rect.minY, -1, file: file, line: line)
            XCTAssertLessThanOrEqual(rect.maxX, host.bounds.maxX + 1, file: file, line: line)
            XCTAssertLessThanOrEqual(rect.maxY, host.bounds.maxY + 1, file: file, line: line)
        }
    }

    private func nativeButtonViews(in view: NSView) -> [ChromeNativeButton] {
        descendants(of: view).compactMap { $0 as? ChromeNativeButton }
    }

    private func nativeButtons(in view: NSView) -> [String: ChromeNativeButton] {
        var result: [String: ChromeNativeButton] = [:]
        for button in nativeButtonViews(in: view) { result[button.testIdentifier] = button }
        return result
    }

    private func probeViews(in view: NSView) -> [ChromeProbeView] {
        descendants(of: view).compactMap { $0 as? ChromeProbeView }
    }

    private func probes(in view: NSView) -> [String: ChromeProbeView] {
        var result: [String: ChromeProbeView] = [:]
        for probe in probeViews(in: view) { result[probe.probeIdentifier] = probe }
        return result
    }

    private func layoutDiagnostics(in host: NSView) -> String {
        let targets = probeViews(in: host)
        let native = nativeButtonViews(in: host)
        let targetFrames = targets.map {
            "\($0.probeIdentifier)=\(host.convert($0.bounds, from: $0)),revision=\($0.receiptRevision)"
        }.sorted().joined(separator: "; ")
        let nativeFrames = native.map {
            "\($0.testIdentifier)=\(host.convert($0.bounds, from: $0)),enabled=\($0.isEnabled),revision=\($0.currentRevision)"
        }.sorted().joined(separator: "; ")
        return "bounds=\(host.bounds),nativeCount=\(native.count),nativeRows=\(distinctRows(native, in: host)),targetCount=\(targets.count),"
            + "targetRows=\(distinctRows(targets, in: host)),targetColumns=\(distinctColumns(targets, in: host)); "
            + "targets: [\(targetFrames)]; native: [\(nativeFrames)]"
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}

@MainActor
private struct ChromeNativeAction: NSViewRepresentable {
    let identifier: String
    let enabled: Bool
    let revision: Int
    let onAction: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onAction: onAction) }

    func makeNSView(context: Context) -> ChromeNativeButton {
        let titles = ["previous": "上一项", "next": "下一项", "complete": "当前单元已完成",
            "bookmark": "书签", "highlight": "高亮", "note": "笔记"]
        let button = ChromeNativeButton(frame: .zero)
        button.title = titles[identifier] ?? identifier
        button.target = context.coordinator
        button.action = #selector(Coordinator.invokeAction)
        button.bezelStyle = .rounded
        button.testIdentifier = identifier
        button.isEnabled = enabled
        button.currentRevision = revision
        return button
    }

    func updateNSView(_ button: ChromeNativeButton, context: Context) {
        context.coordinator.onAction = onAction
        button.isEnabled = enabled
        button.currentRevision = revision
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChromeNativeButton, context: Context) -> CGSize? {
        // Native bezel alignment/intrinsic heights are not label target heights.
        // Give the fixture an explicit proposal, and measure its wrapping receipt.
        CGSize(width: identifier == "complete" ? 132 : 64, height: 28)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onAction: () -> Void
        init(onAction: @escaping () -> Void) { self.onAction = onAction }
        @objc func invokeAction() { onAction() }
    }
}

@MainActor
private final class ChromeNativeButton: NSButton {
    var testIdentifier = ""
    var currentRevision = 0
}

@MainActor
private struct ChromeLayoutProbe: NSViewRepresentable {
    let identifier: String
    var revision = 0

    func makeNSView(context: Context) -> ChromeProbeView {
        let view = ChromeProbeView()
        view.probeIdentifier = identifier
        view.receiptRevision = revision
        return view
    }

    func updateNSView(_ view: ChromeProbeView, context: Context) {
        view.probeIdentifier = identifier
        view.receiptRevision = revision
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChromeProbeView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

@MainActor
private final class ChromeProbeView: NSView {
    var probeIdentifier = ""
    var receiptRevision = 0
}
#endif
