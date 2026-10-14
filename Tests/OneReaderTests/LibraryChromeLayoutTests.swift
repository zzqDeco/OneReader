import AppKit
import SwiftUI
import XCTest
@testable import OneReader

@MainActor
final class LibraryChromeLayoutTests: XCTestCase {
    private let chineseTitle = "在漫长的阅读旅程中重新理解知识、时间与个人成长：一份包含详细来源和研究记录的阅读材料"
    private let mixedTitle = "阅读研究笔记 · SwiftUI Layout and Accessibility — 从原始资料到可追溯的长期知识整理记录"
    private let resumeCopy = "上次读到：第二部分／重新思考阅读与知识的关系，继续查看原始材料中的详细讨论。"

    func testMounted320PointContinuationKeepsLongTitlesAndLinearProgressAfterReplacement() async throws {
        for compact in [true, false] {
            for typeSize in [DynamicTypeSize.xxxLarge, .accessibility3, .accessibility5] {
                let store = LibraryChromeFrameStore()
                let host = NSHostingView(rootView: continuation(title: "阅读", fraction: 0.5,
                    compact: compact, typeSize: typeSize, width: 320, identity: "short", store: store))
                let window = mount(host, width: 320)
                defer { window.contentView = nil; window.close() }
                try await waitForFrames(["card-short", "title-short"], in: host, store: store,
                    fraction: 0.5, progressMaximumX: 120)
                let shortCard = try XCTUnwrap(store.receipts["card-short"])
                let shortTitle = try XCTUnwrap(store.receipts["title-short"])

                host.rootView = continuation(title: chineseTitle, fraction: 0.5,
                    compact: compact, typeSize: typeSize, width: 320, identity: "chinese", store: store)
                try await waitForFrames(["card-chinese", "title-chinese"], in: host, store: store,
                    fraction: 0.5, progressMaximumX: 120)
                try assertFullWidthContinuation(in: host, store: store, identity: "chinese",
                    title: chineseTitle, shortCard: shortCard, shortTitle: shortTitle, fraction: 0.5)

                // The identity-stamped receipt and normalized indicator must both update.
                host.rootView = continuation(title: mixedTitle, fraction: 0,
                    compact: compact, typeSize: typeSize, width: 320, identity: "mixed", store: store)
                try await waitForFrames(["card-mixed", "title-mixed"], in: host, store: store,
                    fraction: 0, progressMaximumX: 120)
                try assertFullWidthContinuation(in: host, store: store, identity: "mixed",
                    title: mixedTitle, shortCard: shortCard, shortTitle: shortTitle, fraction: 0)
            }
        }
    }

    func testMountedWideContinuationStacksOnlyForAccessibilityPolicy() async throws {
        let store = LibraryChromeFrameStore()
        let host = NSHostingView(rootView: continuation(title: mixedTitle, fraction: 0.75,
            compact: false, typeSize: .large, width: 820, identity: "wide-row", store: store))
        let window = mount(host, width: 820)
        defer { window.contentView = nil; window.close() }
        try await waitForFrames(["card-wide-row"], in: host, store: store,
            fraction: 0.75, progressMinimumX: 150)
        let row = try XCTUnwrap(store.receipts["card-wide-row"])
        assertInsideHost(row.frame, host: host)
        XCTAssertGreaterThanOrEqual(try progressFrame(in: host).minX, 150,
            "The real wide card should retain copy beside the cover")
        assertLinearProgress(in: host, fraction: 0.75)

        host.rootView = continuation(title: mixedTitle, fraction: 0.75,
            compact: false, typeSize: .accessibility5, width: 820, identity: "wide-stacked", store: store)
        try await waitForFrames(["card-wide-stacked"], in: host, store: store,
            fraction: 0.75, progressMaximumX: 120)
        let stacked = try XCTUnwrap(store.receipts["card-wide-stacked"])
        XCTAssertEqual(stacked.contentIdentity, mixedTitle)
        assertInsideHost(stacked.frame, host: host)
        XCTAssertLessThanOrEqual(try progressFrame(in: host).minX, 120,
            "Accessibility policy must give the real copy the full width")
        assertLinearProgress(in: host, fraction: 0.75)
    }

    func testMountedShelfCoverGrowsToContainLongAccessibilityTitleAt320Points() async throws {
        // Exceed the minimum ratio even with macOS's smaller native headline font.
        let title = String(repeating: chineseTitle + " " + mixedTitle + " ", count: 6)
        let store = LibraryChromeFrameStore()
        let host = NSHostingView(rootView: shelfCover(title: title, typeSize: .large,
            identity: "regular", store: store))
        let window = mount(host, width: 320)
        defer { window.contentView = nil; window.close() }
        try await waitForFrames(["cover-regular", "shelf-title-regular", "symbol-regular"],
            in: host, store: store)
        let regular = try XCTUnwrap(store.receipts["cover-regular"])
        XCTAssertEqual(regular.frame.width, 288, accuracy: 1)
        XCTAssertEqual(regular.frame.height, 288 / 0.82, accuracy: 2)

        host.rootView = shelfCover(title: title, typeSize: .accessibility5,
            identity: "accessible", store: store)
        try await waitForFrames(["cover-accessible", "shelf-title-accessible", "symbol-accessible"],
            in: host, store: store)
        let accessible = try XCTUnwrap(store.receipts["cover-accessible"])
        let fullTitle = try XCTUnwrap(store.receipts["shelf-title-accessible"])
        let symbol = try XCTUnwrap(store.receipts["symbol-accessible"])
        XCTAssertEqual(accessible.contentIdentity, title)
        XCTAssertEqual(fullTitle.contentIdentity, title)
        XCTAssertGreaterThan(accessible.frame.height, regular.frame.height)
        // A four-line or ratio-clipped title cannot satisfy this mounted full-text bound.
        XCTAssertGreaterThanOrEqual(accessible.frame.height,
            fullTitle.frame.height + symbol.frame.height + 32 + 24 - 1)
        assertInsideHost(accessible.frame, host: host)
        XCTAssertEqual(accessible.frame.width, 288, accuracy: 1)
        XCTAssertEqual(fullTitle.frame.width, 256, accuracy: 1)
    }

    func testMountedSharedLayoutContainsExplicitlyEnlargedChineseAndMixedCopy() async throws {
        // macOS does not scale system fonts with Dynamic Type. Exercise the same
        // mounted layout with genuinely larger glyphs as well as its policy above.
        let store = LibraryChromeFrameStore()
        let host = NSHostingView(rootView: observe(
            LibraryChromeFrameProbe(identity: "enlarged-card", contentIdentity: mixedTitle) {
                LibraryContinuationLayout(spacing: 16, stacksVertically: true) {
                    LibraryChromeFrameProbe(identity: "enlarged-cover", contentIdentity: mixedTitle) {
                        EditorialCover(title: mixedTitle, symbol: "book.closed.fill", color: .teal,
                            progress: 0.75, showsTitle: false)
                            .frame(width: 64, height: 84)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        LibraryChromeFrameProbe(identity: "enlarged-title", contentIdentity: mixedTitle) {
                            Text(mixedTitle)
                                .font(.system(size: 44, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        LibraryChromeFrameProbe(identity: "enlarged-resume", contentIdentity: resumeCopy) {
                            Text(resumeCopy)
                                .font(.system(size: 32))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ReaderProgressSummary(fraction: 0.75)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").font(.system(size: 44))
                }
                .padding(16)
            }
            .padding(.horizontal, 16), width: 320, store: store))
        let window = mount(host, width: 320)
        defer { window.contentView = nil; window.close() }
        try await waitForFrames(["enlarged-card", "enlarged-cover", "enlarged-title", "enlarged-resume"],
            in: host, store: store, fraction: 0.75, progressMaximumX: 120)
        let title = try XCTUnwrap(store.receipts["enlarged-title"])
        let cover = try XCTUnwrap(store.receipts["enlarged-cover"])
        let resumeReceipt = try XCTUnwrap(store.receipts["enlarged-resume"])
        XCTAssertEqual(title.contentIdentity, mixedTitle)
        XCTAssertGreaterThan(title.frame.height, 200, "Enlarged multi-line copy must grow instead of truncating")
        XCTAssertGreaterThanOrEqual(title.frame.width, 200)
        XCTAssertLessThanOrEqual(title.frame.minX, 40)
        XCTAssertGreaterThanOrEqual(title.frame.minY, cover.frame.maxY + 15)
        XCTAssertGreaterThanOrEqual(resumeReceipt.frame.minY, title.frame.maxY + 7)
        assertInsideHost(title.frame, host: host)
        assertInsideHost(resumeReceipt.frame, host: host)
        assertLinearProgress(in: host, fraction: 0.75)
    }

    private func continuation(title: String, fraction: Double, compact: Bool,
        typeSize: DynamicTypeSize, width: CGFloat, identity: String,
        store: LibraryChromeFrameStore) -> AnyView {
        observe(VStack(alignment: .leading, spacing: 8) {
            LibraryChromeFrameProbe(identity: "card-" + identity, contentIdentity: title) {
                LibraryContinuationLabel(title: title, resume: resumeCopy, symbol: "book.closed.fill",
                    color: ReaderTheme.coverColor(for: "library-layout-regression"),
                    fraction: fraction, compact: compact)
            }
            .padding(.horizontal, 16)
            // This independently mounted Text supplies the unclipped title height.
            // It does not replace, mutate or reach inside the real card above.
            LibraryChromeFrameProbe(identity: "title-" + identity, contentIdentity: title) {
                Text(title)
                    .font(compact ? .headline : .title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: width - 64, alignment: .leading)
            .padding(.horizontal, 32)
        }.environment(\.dynamicTypeSize, typeSize), width: width, store: store)
    }

    private func shelfCover(title: String, typeSize: DynamicTypeSize, identity: String,
        store: LibraryChromeFrameStore) -> AnyView {
        observe(VStack(alignment: .leading, spacing: 8) {
            LibraryChromeFrameProbe(identity: "cover-" + identity, contentIdentity: title) {
                EditorialCover(title: title, symbol: "book.closed.fill",
                    color: ReaderTheme.coverColor(for: "library-layout-regression"), progress: 0.5)
            }
            .padding(.horizontal, 16)
            LibraryChromeFrameProbe(identity: "shelf-title-" + identity, contentIdentity: title) {
                Text(title).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 256, alignment: .leading)
            .padding(.horizontal, 32)
            LibraryChromeFrameProbe(identity: "symbol-" + identity, contentIdentity: "book.closed.fill") {
                Image(systemName: "book.closed.fill").font(.body)
            }
        }.environment(\.dynamicTypeSize, typeSize), width: 320, store: store)
    }

    private func observe<Content: View>(_ content: Content, width: CGFloat,
        store: LibraryChromeFrameStore) -> AnyView {
        AnyView(content
            .frame(width: width, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .coordinateSpace(name: "library-chrome-test")
            .onPreferenceChange(LibraryChromeFrameKey.self) { receipts in
                Task { @MainActor in store.receive(receipts) }
            })
    }

    private func mount(_ host: NSView, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 1_600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: width, height: 1_600)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func waitForFrames(_ identities: [String], in host: NSView, store: LibraryChromeFrameStore,
        fraction: Double? = nil, progressMaximumX: CGFloat? = nil,
        progressMinimumX: CGFloat? = nil) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            let framesReady = identities.allSatisfy {
                guard let receipt = store.receipts[$0] else { return false }
                return receipt.frame.width > 0 && receipt.frame.height > 0
            }
            if framesReady {
                guard let fraction else { return }
                if let indicator = progressIndicator(in: host), indicator.maxValue > indicator.minValue {
                    let rendered = (indicator.doubleValue - indicator.minValue)
                        / (indicator.maxValue - indicator.minValue)
                    let rect = host.convert(indicator.bounds, from: indicator)
                    if abs(rendered - fraction) < 0.000_001,
                       progressMaximumX.map({ rect.minX <= $0 }) ?? true,
                       progressMinimumX.map({ rect.minX >= $0 }) ?? true { return }
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LibraryChromeProbeError.timedOut(identities)
    }

    private func assertFullWidthContinuation(in host: NSView, store: LibraryChromeFrameStore,
        identity: String, title: String, shortCard: LibraryChromeFrameReceipt,
        shortTitle: LibraryChromeFrameReceipt, fraction: Double,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let card = try XCTUnwrap(store.receipts["card-" + identity], file: file, line: line)
        let fullTitle = try XCTUnwrap(store.receipts["title-" + identity], file: file, line: line)
        XCTAssertEqual(card.contentIdentity, title, file: file, line: line)
        XCTAssertEqual(fullTitle.contentIdentity, title, file: file, line: line)
        assertInsideHost(card.frame, host: host, file: file, line: line)
        XCTAssertEqual(card.frame.width, 288, accuracy: 1, file: file, line: line)
        XCTAssertEqual(fullTitle.frame.width, 256, accuracy: 1, file: file, line: line)
        XCTAssertGreaterThan(fullTitle.frame.height, 40,
            "The full long title must have real multi-line height", file: file, line: line)
        let titleGrowth = fullTitle.frame.height - shortTitle.frame.height
        XCTAssertGreaterThan(titleGrowth, 20, file: file, line: line)
        XCTAssertEqual(card.frame.height - shortCard.frame.height, titleGrowth, accuracy: 2,
            "The actual card must contain the full title at the same useful copy width",
            file: file, line: line)
        XCTAssertLessThanOrEqual(try progressFrame(in: host).minX, 120,
            "The actual continuation copy must not be squeezed beside the cover", file: file, line: line)
        assertLinearProgress(in: host, fraction: fraction, file: file, line: line)
    }

    private func assertLinearProgress(in host: NSView, fraction: Double,
        file: StaticString = #filePath, line: UInt = #line) {
        guard let indicator = progressIndicator(in: host) else {
            XCTFail("The real continuation card lost its native track", file: file, line: line)
            return
        }
        XCTAssertEqual(indicator.style, .bar, file: file, line: line)
        XCTAssertFalse(indicator.isIndeterminate, file: file, line: line)
        XCTAssertGreaterThan(indicator.maxValue, indicator.minValue, file: file, line: line)
        let rendered = (indicator.doubleValue - indicator.minValue)
            / (indicator.maxValue - indicator.minValue)
        XCTAssertEqual(rendered, fraction, accuracy: 0.000_001, file: file, line: line)
        let rect = host.convert(indicator.bounds, from: indicator)
        XCTAssertGreaterThanOrEqual(rect.width, 71, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.width, 191, file: file, line: line)
        assertInsideHost(rect, host: host, file: file, line: line)
    }

    private func assertInsideHost(_ rect: CGRect, host: NSView,
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(rect.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minX, -1, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, host.bounds.maxX + 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, -1, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, host.bounds.maxY + 1, file: file, line: line)
    }

    private func progressFrame(in host: NSView) throws -> CGRect {
        let indicator = try XCTUnwrap(progressIndicator(in: host))
        return host.convert(indicator.bounds, from: indicator)
    }

    private func progressIndicator(in view: NSView) -> NSProgressIndicator? {
        if let indicator = view as? NSProgressIndicator { return indicator }
        return view.subviews.lazy.compactMap { self.progressIndicator(in: $0) }.first
    }
}

// These probes exist only in the test target. A background reader cannot change
// its content's proposed size, and identity-stamped preferences reject stale frames.
private struct LibraryChromeFrameReceipt: Equatable, Sendable {
    let contentIdentity: String
    let frame: CGRect
}

private struct LibraryChromeFrameKey: PreferenceKey {
    static let defaultValue: [String: LibraryChromeFrameReceipt] = [:]

    static func reduce(value: inout [String: LibraryChromeFrameReceipt],
        nextValue: () -> [String: LibraryChromeFrameReceipt]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor
private final class LibraryChromeFrameStore {
    private(set) var receipts: [String: LibraryChromeFrameReceipt] = [:]

    func receive(_ values: [String: LibraryChromeFrameReceipt]) {
        receipts.merge(values, uniquingKeysWith: { _, new in new })
    }
}

private struct LibraryChromeFrameProbe<Content: View>: View {
    let identity: String
    let contentIdentity: String
    @ViewBuilder let content: Content

    var body: some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: LibraryChromeFrameKey.self, value: [
                identity: LibraryChromeFrameReceipt(contentIdentity: contentIdentity,
                    frame: geometry.frame(in: .named("library-chrome-test")))
            ])
        })
    }
}

private enum LibraryChromeProbeError: Error {
    case timedOut([String])
}
