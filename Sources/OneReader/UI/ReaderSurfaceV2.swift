import SwiftUI

struct ReaderSurfaceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.readingPositionCaptureTargetID) private var captureTargetID

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
            if !usesCompactLayout {
                readerHeader
                Divider()
            }
            presentation
#if DEBUG && os(iOS)
            if ProcessInfo.processInfo.environment["ONEREADER_UI_TEST_RECOVERY_ID"] != nil {
                Text("Recovery test")
                    .font(.system(size: 8))
                    .accessibilityIdentifier("reader-persisted-position")
                    .accessibilityValue(model.recoveryUITestPersistenceMetrics)
            }
#endif
            if !usesCompactLayout {
                Divider()
                readerFooter
            }
        }
        .background(ReaderTheme.paper)
        .navigationTitle(model.presentationDocument?.title ?? model.selectedSpace?.title ?? "OneReader")
#if os(iOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if usesCompactLayout {
                compactReaderBar
            }
        }
#endif
    }

    private var readerHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.presentationDocument?.title ?? model.selectedSource?.displayName ?? "选择一个来源")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    if let document = model.presentationDocument {
                        Text(document.surface.displayName)
                    }
                    if let limitation = model.presentationDescriptor?.limitation {
                        Text("·")
                        Label(limitation, systemImage: "info.circle")
                            .help(limitation)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 10)
            if model.canOpenOriginalSource {
                Button {
                    model.openOriginalSource()
                } label: {
                    Label("打开原始来源", systemImage: "arrow.up.right.square")
                        .labelStyle(.iconOnly)
                }
                .help("明确在外部应用中打开原始来源")
                .accessibilityLabel("打开原始来源")
            }
            Menu {
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
            }
            .accessibilityLabel("阅读外观")
            .help("阅读外观")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
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
                }
            )
            .id(presentationToken)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var readerFooter: some View {
        footerControls
        .padding(.horizontal, 17)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var footerControls: some View {
        HStack(spacing: 12) {
            Button {
                model.selectPreviousNode()
            } label: {
                Label("上一项", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("上一项")
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(!model.canSelectPreviousNode)

            Button {
                model.selectNextNode()
            } label: {
                Label("下一项", systemImage: "chevron.right")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下一项")
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(!model.canSelectNextNode)

            if let position = model.currentPositionDescription {
                Label("已记录 · \(position)", systemImage: "bookmark.circle")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("阅读位置已记录，\(position)")
            }

            Spacer(minLength: 0)

            if let unitID = model.currentProgress.currentUnitID {
                Button {
                    model.markReadingUnitComplete(unitID)
                } label: {
                    Label(
                        model.currentProgress.state(for: unitID) == .completed
                            ? "当前单元已完成"
                            : "完成当前单元",
                        systemImage: model.currentProgress.state(for: unitID) == .completed
                            ? "checkmark.circle.fill"
                            : "checkmark.circle"
                    )
                }
                .disabled(model.currentProgress.state(for: unitID) == .completed)
                .accessibilityLabel("完成当前阅读单元")
            }

            if let selection = model.currentSelection {
                Text("已选择 \(selection.text.count) 个字符")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                model.addBookmark()
            } label: {
                Label("书签", systemImage: "bookmark")
            }
            .accessibilityLabel("添加书签")
            .disabled(model.presentationDocument == nil)

            Button {
                model.addHighlight()
            } label: {
                Label("高亮", systemImage: "highlighter")
            }
            .accessibilityLabel("高亮所选文本")
            .disabled(!model.canCreateHighlight)
            .help(highlightHelp)

            Button {
                model.inspectorTab = .annotations
                model.isInspectorPresented = true
            } label: {
                Label("笔记", systemImage: "note.text.badge.plus")
            }
            .accessibilityLabel("添加笔记")
            .disabled(model.presentationDocument == nil)
            .help("编写带当前位置的笔记")
        }
    }

#if os(iOS)
    private var compactReaderBar: some View {
        HStack(spacing: 0) {
            CompactReaderAction(title: "目录", systemImage: "list.bullet") {
                onShowNavigation?()
            }
            CompactReaderAction(
                title: "上一项",
                systemImage: "chevron.left",
                isDisabled: !model.canSelectPreviousNode
            ) {
                model.selectPreviousNode()
            }
            CompactReaderAction(
                title: "下一项",
                systemImage: "chevron.right",
                isDisabled: !model.canSelectNextNode
            ) {
                model.selectNextNode()
            }
            CompactReaderAction(title: "笔记", systemImage: "note.text") {
                onShowAssistance?()
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 5)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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

private extension PresentationSurface {
    var displayName: String {
        switch self {
        case .pdfKit: "PDF"
        case .nativeMarkdown: "富文本"
        case .nativeText: "纯文本"
        case .nativeCode: "代码"
        case .sanitizedWeb: "网页"
        case .quickLook: "系统预览"
        }
    }
}

#if os(iOS)
private struct CompactReaderAction: View {
    let title: String
    let systemImage: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .disabled(isDisabled)
    }
}
#endif
