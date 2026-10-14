import SwiftUI

struct ReaderSurfaceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.readingPositionCaptureTargetID) private var captureTargetID
    @State private var pdfZoomRequest: PDFZoomRequest?
    @State private var pdfZoomRequestToken: UUID?
    @State private var pdfZoomFactor = 1.0

    let onShowNavigation: (() -> Void)?
    let onShowAssistance: (() -> Void)?

    init(
        onShowNavigation: (() -> Void)? = nil,
        onShowAssistance: (() -> Void)? = nil
    ) {
        self.onShowNavigation = onShowNavigation
        self.onShowAssistance = onShowAssistance
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isAnnotationPreview {
                ReaderSurfaceAdaptiveActions(horizontalSpacing: 12) {
                    Label("原快照回看 · 不改变阅读进度", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: model.openNotesCenter) {
                        ReaderActionLabel(title: "返回笔记", systemImage: "arrow.uturn.backward")
                    }
                    .font(.caption)
                }
                .padding(12)
                .background(ReaderTheme.teal.opacity(0.1))
            }
            if !usesCompactLayout {
                readerHeader
                Divider()
            }
            presentation
#if DEBUG && os(iOS)
            if ProcessInfo.processInfo.environment["ONEREADER_UI_TEST_RECOVERY_ID"] != nil {
                ReadingPositionPersistenceReceipt(state: model.readingPositionDisplayState)
            }
#endif
            if !usesCompactLayout {
                Divider()
                readerFooter
            }
        }
        .background(ReaderTheme.paper)
        .navigationTitle(model.presentationDocument?.title ?? model.selectedSpace?.title ?? "OneReader")
        .sheet(isPresented: $model.isOCRPanelPresented) {
            OCRReaderPanel(controller: model.ocrController).environmentObject(model)
        }
#if os(iOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if usesCompactLayout {
                VStack(spacing: 0) {
                    if model.presentationDocument?.surface == .pdfKit {
                        pdfZoomControls
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(.bar)
                            .overlay(alignment: .top) { Divider() }
                    }
                    compactReaderBar
                }
            }
        }
#endif
        .onChange(of: model.currentPresentationToken) { _, _ in
            pdfZoomRequest = nil
            pdfZoomRequestToken = nil
            pdfZoomFactor = 1
        }
    }

    private var readerHeader: some View {
        ReaderSurfaceAdaptiveActions(minimumHorizontalWidth: 520, horizontalSpacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.presentationDocument?.title ?? model.selectedSource?.displayName ?? "选择一个来源")
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    if let document = model.presentationDocument {
                        Text(document.surface.displayName)
                    }
                    if let limitation = model.presentationDescriptor?.limitation {
                        Label(limitation, systemImage: "info.circle")
                            .help(limitation)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            readerHeaderActions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .tint(ReaderTheme.accent)
        .background(ReaderTheme.raised)
    }

    private var readerHeaderActions: some View {
        ReaderSurfaceAdaptiveActions(horizontalSpacing: 12) {
            readerAppearanceActions
#if os(iOS)
            if model.presentationDocument?.surface == .pdfKit {
                pdfZoomControls
            }
#endif
        }
    }

    private var readerAppearanceActions: some View {
        HStack(spacing: 8) {
            if model.canUseLocalOCR {
                Button { model.showLocalOCR() } label: {
                    Label("识别文字", systemImage: "text.viewfinder").labelStyle(.iconOnly)
                        .frame(minWidth: ReaderChromeMetrics.actionHeight,
                            minHeight: ReaderChromeMetrics.actionHeight)
                        .contentShape(Rectangle())
                }
                .help("在本机识别文字")
                .accessibilityLabel("在本机识别文字")
                .accessibilityIdentifier("reader-ocr")
            }
            if model.canOpenOriginalSource {
                Button {
                    model.openOriginalSource()
                } label: {
                    Label("打开原始来源", systemImage: "arrow.up.right.square")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: ReaderChromeMetrics.actionHeight,
                            minHeight: ReaderChromeMetrics.actionHeight)
                        .contentShape(Rectangle())
                }
                .help("明确在外部应用中打开原始来源")
                .accessibilityLabel("打开原始来源")
            }
            Menu {
                if model.isBilingualReadingAvailable {
                    Button("双语对照") {
                        model.inspectorTab = .translation
                        model.isInspectorPresented = true
                    }
                    Divider()
                }
                Picker("主题", selection: $model.preferences.theme) {
                    ForEach(ReaderThemePreference.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Divider()
                Button("放大文字") {
                    model.preferences.fontSize = min(30, model.preferences.fontSize + 1)
                }
                Button("缩小文字") {
                    model.preferences.fontSize = max(12, model.preferences.fontSize - 1)
                }
            } label: {
                Label("阅读外观", systemImage: "textformat.size")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: ReaderChromeMetrics.actionHeight,
                        minHeight: ReaderChromeMetrics.actionHeight)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("阅读外观")
            .help("阅读外观")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var presentation: some View {
        switch model.presentationState {
        case .empty:
            ContentUnavailableView(
                "选择可阅读内容",
                systemImage: "book.pages",
                description: Text("从左侧目录或来源列表选择内容。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            VStack(spacing: 13) {
                ProgressView()
                Text("正在准备基础阅读视图…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .unavailable(let message):
            ContentUnavailableView(
                "无法呈现当前内容",
                systemImage: "doc.questionmark",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let document):
            let presentationToken = model.currentPresentationToken
            AdapterPresentationView(
                document: document,
                captureTargetID: captureTargetID,
                preferences: model.preferences,
                onSelectionChange: { selection in
                    guard model.currentPresentationToken == presentationToken,
                          model.isActiveReadingPositionCaptureTarget(captureTargetID) else {
                        return
                    }
                    model.currentSelection = selection
                },
                onPositionChange: { update in
                    guard model.isActiveReadingPositionCaptureTarget(captureTargetID) else {
                        return
                    }
                    model.updateReadingPosition(
                        update,
                        presentationToken: presentationToken
                    )
                },
                pdfZoomRequest: pdfZoomRequestToken == presentationToken ? pdfZoomRequest : nil,
                onPDFZoomChange: { zoom in
                    guard model.currentPresentationToken == presentationToken,
                          zoom.isFinite else { return }
                    pdfZoomFactor = zoom
                },
                ocrRevision: model.ocrDisplayRevision,
                ocrTextSelectionEnabled: model.ocrTextSelectionEnabled
            )
            .id(presentationToken)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var readerFooter: some View {
        footerControls
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .controlSize(.small)
        .tint(ReaderTheme.accent)
        .background(.bar)
        .accessibilityIdentifier("reader-footer")
    }

    private var footerControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            ReaderSurfaceFooterLayout(positionState: model.readingPositionDisplayState, navigation: {
                readerNavigationActions
            }, actions: {
                ReaderSurfaceAdaptiveActions(horizontalSpacing: 12) {
                    if let unitID = model.currentProgress.currentUnitID {
                        Button {
                            model.markReadingUnitComplete(unitID)
                        } label: {
                            ReaderActionLabel(
                                title: model.currentProgress.state(for: unitID) == .completed
                                    ? "当前单元已完成"
                                    : "完成当前单元",
                                systemImage: model.currentProgress.state(for: unitID) == .completed
                                    ? "checkmark.circle.fill"
                                    : "checkmark.circle"
                            )
                        }
                        .disabled(model.currentProgress.state(for: unitID) == .completed)
                        .accessibilityLabel("完成当前阅读单元")
                        .accessibilityIdentifier("reader-complete-unit")
                    }
                    readerAnnotationActions
                }
            })

            if let selection = model.currentSelection {
                Text("已选择 \(selection.text.count) 个字符")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var readerNavigationActions: some View {
        ReaderSurfaceAdaptiveActions(horizontalSpacing: 12) {
            Button {
                model.selectPreviousNode()
            } label: {
                ReaderActionLabel(title: "上一项", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("上一项")
            .accessibilityIdentifier("reader-previous")
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(!model.canSelectPreviousNode)

            Button {
                model.selectNextNode()
            } label: {
                ReaderActionLabel(title: "下一项", systemImage: "chevron.right")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下一项")
            .accessibilityIdentifier("reader-next")
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(!model.canSelectNextNode)
        }
    }

    private var readerAnnotationActions: some View {
        ReaderSurfaceAdaptiveActions(horizontalSpacing: 8) {
            Button {
                model.addBookmark()
            } label: {
                ReaderActionLabel(title: "书签", systemImage: "bookmark")
            }
            .accessibilityLabel("添加书签")
            .accessibilityIdentifier("reader-bookmark")
            .disabled(model.presentationDocument == nil)

            Button {
                model.addHighlight()
            } label: {
                ReaderActionLabel(title: "高亮", systemImage: "highlighter")
            }
            .accessibilityLabel("高亮所选文本")
            .accessibilityIdentifier("reader-highlight")
            .disabled(!model.canCreateHighlight)
            .help(highlightHelp)

            Button {
                model.inspectorTab = .annotations
                model.isInspectorPresented = true
            } label: {
                ReaderActionLabel(title: "笔记", systemImage: "note.text.badge.plus")
            }
            .accessibilityLabel("添加笔记")
            .accessibilityIdentifier("reader-add-note")
            .disabled(model.presentationDocument == nil)
            .help("编写带当前位置的笔记")
        }
        .buttonStyle(.bordered)
    }

#if os(iOS)
    private var pdfZoomControls: some View {
        ReaderSurfacePDFZoomControls(zoomFactor: pdfZoomFactor, onAction: requestPDFZoom)
    }

    private func requestPDFZoom(_ action: PDFZoomAction) {
        pdfZoomRequestToken = model.currentPresentationToken
        pdfZoomRequest = PDFZoomRequest(action: action)
    }

    private var compactReaderBar: some View {
        ReaderSurfaceCompactBar {
            ReaderSurfaceCompactAction(title: "目录", systemImage: "list.bullet") {
                onShowNavigation?()
            }
            ReaderSurfaceCompactAction(
                title: "上一项",
                systemImage: "chevron.left",
                isDisabled: !model.canSelectPreviousNode
            ) {
                model.selectPreviousNode()
            }
            ReaderSurfaceCompactAction(
                title: "下一项",
                systemImage: "chevron.right",
                isDisabled: !model.canSelectNextNode
            ) {
                model.selectNextNode()
            }
            ReaderSurfaceCompactAction(title: "笔记", systemImage: "note.text") {
                onShowAssistance?()
            }
            if model.canUseLocalOCR {
                ReaderSurfaceCompactAction(title: "识别", systemImage: "text.viewfinder") { model.showLocalOCR() }
                    .accessibilityIdentifier("reader-ocr")
            }
        }
    }
#endif

    private var highlightHelp: String {
        if model.presentationDocument?.surface == .quickLook {
            return "系统预览只支持来源级书签和笔记"
        }
        if model.currentSelection == nil { return "先在正文中选择文本" }
        return "保存可在版本变化后重新定位的高亮"
    }

    private var usesCompactLayout: Bool {
#if os(iOS)
        horizontalSizeClass == .compact
#else
        false
#endif
    }
}

/// Keep live position text out of the whole reader's observation boundary.
private struct ReadingPositionBadge: View {
    @ObservedObject var state: ReadingPositionDisplayState

    var body: some View {
        if let position = state.positionDescription {
            Label("已记录 · \(position)", systemImage: "bookmark.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("阅读位置已记录，\(position)")
        }
    }
}

#if DEBUG && os(iOS)
/// Observe only successful saves, without invalidating the PDF/reader surface.
private struct ReadingPositionPersistenceReceipt: View {
    @ObservedObject var state: ReadingPositionDisplayState

    var body: some View {
        Text("Recovery test")
            .font(.system(size: 8))
            .accessibilityIdentifier("reader-persisted-position")
            .accessibilityValue(AppModel.recoveryUITestPersistenceMetrics(for: state.durablePosition))
    }
}
#endif

private extension PresentationSurface {
    var displayName: String {
        switch self {
        case .pdfKit: "PDF"
        case .nativeImage: "图像"
        case .nativeMarkdown: "富文本"
        case .nativeText: "纯文本"
        case .nativeCode: "代码"
        case .sanitizedWeb: "网页"
        case .quickLook: "系统预览"
        }
    }
}

/// Platform-neutral chrome lets shared macOS tests exercise the compact layout;
/// its actions still belong to the native iPhone safe-area footer.
struct ReaderSurfaceCompactAction: View {
    let title: String
    let systemImage: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                Text(title)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .disabled(isDisabled)
    }
}

/// One content tree owns every control. Flexible metadata contributes only its
/// reserved width; actionable labels decide whether the group needs to stack.
/// Accessibility sizes always get a vertical action group.
struct ReaderSurfaceAdaptiveActions<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var minimumHorizontalWidth: CGFloat? = nil
    var flexibleSubviewIndex: Int? = nil
    var minimumFlexibleWidth: CGFloat = 0
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        ReaderSurfaceAdaptiveLayout(
            forceVertical: dynamicTypeSize.isAccessibilitySize,
            minimumHorizontalWidth: minimumHorizontalWidth,
            flexibleSubviewIndex: flexibleSubviewIndex,
            minimumFlexibleWidth: minimumFlexibleWidth,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing
        ) {
            content
        }
        .accessibilityElement(children: .contain)
    }
}

/// The source callbacks stay in ReaderSurfaceView; this container owns only
/// chrome layout. Live position remains observed by the small badge alone.
struct ReaderSurfaceFooterLayout<Navigation: View, Actions: View>: View {
    let positionState: ReadingPositionDisplayState
    @ViewBuilder let navigation: Navigation
    @ViewBuilder let actions: Actions

    var body: some View {
        ReaderSurfaceAdaptiveActions(flexibleSubviewIndex: 0, minimumFlexibleWidth: 160,
            horizontalSpacing: 16) {
            ReaderSurfaceAdaptiveActions(flexibleSubviewIndex: 1, horizontalSpacing: 12) {
                navigation
                    .layoutPriority(1)
                ReadingPositionBadge(state: positionState)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
    }
}

/// AnyLayout delegates placement without alternate native control trees.
private struct ReaderSurfaceAdaptiveLayout: Layout {
    let forceVertical: Bool
    let minimumHorizontalWidth: CGFloat?
    let flexibleSubviewIndex: Int?
    let minimumFlexibleWidth: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let layout = layout(for: proposal.width, subviews: subviews)
        var layoutCache = layout.makeCache(subviews: subviews)
        return layout.sizeThatFits(proposal: proposal, subviews: subviews, cache: &layoutCache)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = layout(for: proposal.width, subviews: subviews)
        var layoutCache = layout.makeCache(subviews: subviews)
        layout.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &layoutCache)
    }

    private func layout(for width: CGFloat?, subviews: Subviews) -> AnyLayout {
        let requiredWidth = minimumHorizontalWidth ?? (
            subviews.indices.reduce(CGFloat.zero) { sum, index in
                let isFlexible = flexibleSubviewIndex.map { $0 == index } ?? false
                return sum + (isFlexible ? minimumFlexibleWidth : subviews[index].sizeThatFits(.unspecified).width)
            }
                + CGFloat(max(0, subviews.count - 1)) * horizontalSpacing
        )
        let fitsHorizontally = width.map { $0 >= requiredWidth } ?? true
        if !forceVertical && fitsHorizontally {
            return AnyLayout(HStackLayout(alignment: .center, spacing: horizontalSpacing))
        }
        return AnyLayout(VStackLayout(alignment: .leading, spacing: verticalSpacing))
    }
}

struct ReaderSurfacePDFZoomControls: View {
    let zoomFactor: Double
    let onAction: (PDFZoomAction) -> Void

    var body: some View {
        ReaderSurfaceAdaptiveActions(horizontalSpacing: 12, verticalSpacing: 4) {
            adjustmentControls
            fitWidthControl
        }
        .buttonStyle(.plain)
        .tint(ReaderTheme.accent)
    }

    var adjustmentControls: some View {
        HStack(spacing: 8) {
            Button { onAction(.zoomOut) } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.body)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("缩小 PDF")
            .accessibilityIdentifier("pdf-zoom-out")
            Text("\(Int((zoomFactor * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .fixedSize(horizontal: true, vertical: true)
                .frame(minWidth: 52)
                .accessibilityLabel("PDF 缩放比例")
                .accessibilityValue("\(Int((zoomFactor * 100).rounded()))%")
                .accessibilityIdentifier("pdf-zoom-percentage")
            Button { onAction(.zoomIn) } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.body)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("放大 PDF")
            .accessibilityIdentifier("pdf-zoom-in")
        }
    }

    var fitWidthControl: some View {
        Button { onAction(.fitWidth) } label: {
            Text("适合宽度")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("pdf-fit-width")
    }
}

/// Compact controls can gain rows instead of clipping their text or shrinking
/// the hit area. Larger sizes reduce the column cap, not the text scale.
struct ReaderSurfaceCompactBar<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let content: Content

    var body: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        let enlargedSize = dynamicTypeSize >= .xxLarge
        ReaderSurfaceCompactGridLayout(
            maximumColumns: accessibilitySize ? 2 : enlargedSize ? 3 : 5,
            minimumColumnWidth: accessibilitySize ? 132 : enlargedSize ? 80 : 64
        ) {
            content
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .tint(ReaderTheme.accent)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

private struct ReaderSurfaceCompactGridLayout: Layout {
    let maximumColumns: Int
    let minimumColumnWidth: CGFloat
    private let spacing: CGFloat = 8

    private struct Arrangement {
        let width: CGFloat
        let columns: Int
        let columnWidth: CGFloat
        let rowHeights: [CGFloat]

        var height: CGFloat { rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1)) * 8 }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let arrangement = arrangement(for: proposal.width, subviews: subviews)
        return CGSize(width: arrangement.width, height: arrangement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let arrangement = arrangement(for: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in arrangement.rowHeights.indices {
            for column in 0..<arrangement.columns {
                let index = row * arrangement.columns + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (arrangement.columnWidth + spacing), y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: arrangement.columnWidth, height: arrangement.rowHeights[row])
                )
            }
            y += arrangement.rowHeights[row] + spacing
        }
    }

    private func arrangement(for proposedWidth: CGFloat?, subviews: Subviews) -> Arrangement {
        let idealWidth = subviews.compactMap { subview -> CGFloat? in
            let width = subview.sizeThatFits(.unspecified).width
            return width.isFinite ? width : nil
        }.max() ?? minimumColumnWidth
        let minimumWidth = max(minimumColumnWidth, idealWidth)
        let cap = max(1, min(maximumColumns, subviews.count))
        let naturalWidth = minimumWidth * CGFloat(cap) + spacing * CGFloat(cap - 1)
        let width = max(0, proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? naturalWidth)
        let columns = max(1, min(cap, Int((width + spacing) / (minimumWidth + spacing))))
        let columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var rowHeights: [CGFloat] = []
        for index in subviews.indices {
            let row = index / columns
            let height = subviews[index].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            if row == rowHeights.count { rowHeights.append(height) }
            else { rowHeights[row] = max(rowHeights[row], height) }
        }
        return Arrangement(width: width, columns: columns, columnWidth: columnWidth, rowHeights: rowHeights)
    }
}
