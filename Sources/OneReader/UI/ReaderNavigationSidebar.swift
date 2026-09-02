import SwiftUI

struct ReaderNavigationSidebar: View {
    @EnvironmentObject private var model: AppModel
    let showsLibraryBackButton: Bool

    init(showsLibraryBackButton: Bool = true) {
        self.showsLibraryBackButton = showsLibraryBackButton
    }

    var body: some View {
        VStack(spacing: 0) {
            spaceHeader
            Divider()
            tabPicker
            Divider()
            tabContent
        }
        .background(ReaderTheme.window)
        .accessibilityElement(children: .contain)
    }

    private var spaceHeader: some View {
        HStack(spacing: 10) {
            if showsLibraryBackButton {
                Button {
                    model.closeReadingWorkspace()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .help("返回资料库")
                .accessibilityLabel("返回资料库")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedSpace?.title ?? "阅读空间")
                    .font(.headline)
                    .lineLimit(1)
                Text("\(model.selectedSpaceSources.count) 个来源")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
    }

    private var tabPicker: some View {
        Picker("导航视图", selection: $model.navigationTab) {
            ForEach(model.availableNavigationTabs) { tab in
                Image(systemName: tab.systemImage)
                    .tag(tab)
                    .help(tab.title)
                    .accessibilityLabel(tab.title)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(10)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.navigationTab {
        case .outline:
            outlineView
        case .sources:
            sourcesView
        case .route:
            routeView
        case .search:
            searchView
        }
    }

    private var outlineView: some View {
        Group {
            if readerOutlineNodes.isEmpty {
                ContentUnavailableView(
                    "没有结构化目录",
                    systemImage: "list.bullet.indent",
                    description: Text("当前来源会直接显示；系统预览等兜底内容可能没有目录。")
                )
            } else {
                List(readerOutlineNodes) { node in
                    Button {
                        model.openNode(node)
                    } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: nodeSymbol(node))
                                .foregroundStyle(node.isReadable ? ReaderTheme.teal : .secondary)
                                .frame(width: 15)
                            Text(node.title)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.leading, CGFloat(min(node.depth, 5) * 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!node.isReadable)
                    .accessibilityHint(node.locator.conciseDescription)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var sourcesView: some View {
        VStack(spacing: 0) {
            List {
                Section("来源") {
                    ForEach(model.selectedSpaceSources) { source in
                        Button {
                            model.openSource(source.id)
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: sourceSymbol(source))
                                    .foregroundStyle(source.id == model.selectedSourceID
                                        ? ReaderTheme.teal : .secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.displayName)
                                        .lineLimit(1)
                                    Text(source.originKind.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 3)
                                if model.refreshingSourceIDs.contains(source.id) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityLabel("正在刷新来源")
                                } else if source.isFavorite {
                                    Image(systemName: "star.fill")
                                        .font(.caption)
                                        .foregroundStyle(ReaderTheme.orange)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("刷新来源") {
                                model.refreshSource(source.id)
                            }
                            .disabled(model.refreshingSourceIDs.contains(source.id))
                            Button(source.isFavorite ? "取消收藏" : "收藏") {
                                model.toggleSourceFavorite(source.id)
                            }
                            Divider()
                            Button(removeSourceTitle, role: .destructive) {
                                model.requestSourceRemoval(source.id)
                            }
                        }
                    }
                }
                if !model.history.isEmpty {
                    Section("最近阅读") {
                        ForEach(Array(model.history.prefix(12))) { entry in
                            if let locator = entry.locator {
                                Button {
                                    model.openLocator(locator)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.source(id: entry.sourceID ?? "")?.displayName ?? "历史来源")
                                            .lineLimit(1)
                                        Text(locator.conciseDescription)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(entry.openedAt, style: .relative)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    "最近阅读，\(model.source(id: entry.sourceID ?? "")?.displayName ?? "历史来源")，\(locator.conciseDescription)"
                                )
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button {
                model.isImportSheetPresented = true
            } label: {
                Label("加入更多来源", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
            }
            .buttonStyle(.plain)
        }
    }

    private var removeSourceTitle: String {
#if os(macOS)
        "移到废纸篓…"
#else
        "从此设备移除…"
#endif
    }

    private var routeView: some View {
        Group {
            if let graph = model.currentGraph, let plan = model.currentPlan {
                List {
                    if let pending = model.pendingPlan {
                        Section("新路线可用") {
                            Text("阅读助手已基于更新后的原文生成“\(pending.goal)”路线。当前路线不会自动替换。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("切换并迁移进度") {
                                model.adoptPendingReadingPlan()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    Section {
                        ForEach(Array(plan.orderedUnitIDs.enumerated()), id: \.element) { index, unitID in
                            if let unit = graph.units.first(where: { $0.id == unitID }) {
                                RouteUnitRow(
                                    index: index + 1,
                                    unit: unit,
                                    reason: plan.reasons[unitID],
                                    state: model.currentProgress.state(for: unitID),
                                    isCurrent: model.currentProgress.currentPlanStepID == unitID
                                ) {
                                    model.selectReadingUnit(unitID)
                                }
                            }
                        }
                    } header: {
                        Text(plan.goal)
                    }
                }
                .listStyle(.sidebar)
            } else {
                VStack(spacing: 14) {
                    ContentUnavailableView(
                        "还没有智能阅读路线",
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        description: Text("基础目录与阅读不受影响。配置模型后可基于真实证据生成冻结路线。")
                    )
                    Button("生成阅读脉络与路线") {
                        model.launchAgentPipeline()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(16)
            }
        }
    }

    private var searchView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                TextField("搜索正文", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.performSearch() }
                    .accessibilityLabel("搜索正文")
                Picker("搜索范围", selection: $model.searchScope) {
                    ForEach(ReaderSearchScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                            .disabled(scope == .source && !model.canSearchCurrentPresentation)
                    }
                }
                .pickerStyle(.menu)
                HStack {
                    if model.isSearching {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在搜索…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("搜索") { model.performSearch() }
                        .disabled(model.searchText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(11)
            Divider()

            if model.searchResults.isEmpty, !model.isSearching {
                ContentUnavailableView(
                    model.searchText.isEmpty ? "搜索阅读空间" : "没有匹配结果",
                    systemImage: "magnifyingglass",
                    description: Text("结果会显示来源、快照与可跳转上下文。")
                )
            } else {
                List(model.searchResults) { hit in
                    Button {
                        model.openSearchHit(hit)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hit.title.isEmpty ? hit.locator.conciseDescription : hit.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(hit.context.replacingOccurrences(of: "[", with: "")
                                .replacingOccurrences(of: "]", with: ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                            Text("\(sourceLabel(hit.sourceID)) · 版本 \(hit.snapshotID.prefix(12))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(hit.title.isEmpty ? hit.locator.conciseDescription : hit.title)，"
                        + "来源 \(sourceLabel(hit.sourceID))，版本 \(hit.snapshotID.prefix(12))，"
                        + hit.context.replacingOccurrences(of: "[", with: "")
                            .replacingOccurrences(of: "]", with: "")
                    )
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func nodeSymbol(_ node: ContentNode) -> String {
        switch node.kind {
        case .directory: "folder"
        case .page: "doc.text"
        case .section: "text.alignleft"
        case .spineItem: "book.pages"
        case .file, .document: "doc"
        case .fallback: "eye"
        }
    }

    private var readerOutlineNodes: [ContentNode] {
        ReaderContentNavigation.outlineNodes(from: model.contentNodes)
    }

    private func sourceSymbol(_ source: Source) -> String {
        switch source.originKind {
        case .localFile: "doc"
        case .localDirectory: "folder"
        case .remoteURL: "globe"
        case .githubRepository: "chevron.left.forwardslash.chevron.right"
        }
    }

    private func sourceLabel(_ sourceID: String) -> String {
        model.source(id: sourceID)?.displayName ?? sourceID
    }
}

private struct RouteUnitRow: View {
    let index: Int
    let unit: ReadingUnit
    let reason: String?
    let state: UnitProgressState
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(state == .completed ? ReaderTheme.teal : isCurrent ? ReaderTheme.orange : .secondary.opacity(0.15))
                        .frame(width: 24, height: 24)
                    if state == .completed {
                        Image(systemName: "checkmark")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                    } else {
                        Text("\(index)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(isCurrent ? .white : .secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(unit.title)
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .multilineTextAlignment(.leading)
                    if let reason, isCurrent {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(index) 步，\(unit.title)，\(state.rawValue)")
    }
}

private extension SourceOriginKind {
    var displayName: String {
        switch self {
        case .localFile: "本地文件"
        case .localDirectory: "本地目录"
        case .remoteURL: "网页快照"
        case .githubRepository: "GitHub 仓库"
        }
    }
}
