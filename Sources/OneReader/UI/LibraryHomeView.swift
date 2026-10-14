import SwiftUI

struct LibraryHomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isSelectingSpaces = false
    @State private var selectedSpaceIDs: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                libraryHeader

                if !model.visibleCaptureJobs.isEmpty || model.isReceivingCaptures > 0 {
                    CaptureInboxSection()
                }

                if !model.pendingImports.isEmpty {
                    pendingSection
                }

                if model.spaces.isEmpty && model.pendingImports.isEmpty && model.captureJobs.isEmpty {
                    emptyLibrary
                } else if model.visibleSpaces.isEmpty {
                    ContentUnavailableView(
                        "这里还没有内容",
                        systemImage: model.selectedCollection.systemImage,
                        description: Text("切换资料库分类，或添加新的阅读材料。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    if let recentSpace {
                        continueReading(space: recentSpace)
                    }
                    shelf
                }
            }
            .frame(maxWidth: 1_180, alignment: .leading)
            .padding(.horizontal, compactLayout ? 16 : 32)
            .padding(.top, compactLayout ? 16 : 24)
            .padding(.bottom, 56)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("library-scroll-view")
        .background(ReaderTheme.grouped)
        .navigationTitle(model.selectedCollection.title)
        .searchable(text: $model.librarySearchText, prompt: "搜索空间或收集任务")
    }

    private var libraryHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                headerCopy
                Spacer()
                libraryActions
            }
            VStack(alignment: .leading, spacing: 12) {
                headerCopy
                libraryActions
            }
        }
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !compactLayout {
                Text(model.selectedCollection.title)
                    .font(.title2.weight(.semibold))
            }
            Text(libraryDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var libraryActions: some View {
        ReaderAdaptiveActions {
            Button(action: model.openNotesCenter) {
                ReaderActionLabel(title: "笔记中心", systemImage: "note.text")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("library-open-notes-center")
            if !compactLayout { addMaterialButton }
        }
    }

    private var addMaterialButton: some View {
        Button {
            model.isImportSheetPresented = true
        } label: {
            ReaderActionLabel(title: "添加材料", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("library-add-materials")
    }

    private var libraryDescription: String {
        if model.selectedCollection == .archived { return "归档只隐藏阅读空间，不删除托管副本、标注、历史或阅读进度。" }
        if model.selectedCollection == .read { return "已读是整理标记，不会把阅读位置改到最后一页。" }
        if model.selectedCollection == .inbox { return "随手保存材料，在这里查看接收状态并整理到阅读空间。" }
        if model.spaces.isEmpty { return "你的材料与阅读记录，保存在本机。" }
        return "\(model.visibleSpaces.count) 个阅读空间 · 从上次停下的位置继续"
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReaderSectionHeading(title: "正在整理", systemImage: "arrow.triangle.2.circlepath", count: model.pendingImports.count)
            ForEach(model.pendingImports) { item in
                HStack(spacing: 12) {
                    if item.state.isActive {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .font(.subheadline.weight(.medium))
                        Text(label(for: item.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !item.state.isActive {
                        Button("移除") { model.dismissPendingImport(item.id) }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(16)
                .background(ReaderTheme.raised, in: RoundedRectangle(cornerRadius: ReaderTheme.panelRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: ReaderTheme.panelRadius)
                        .stroke(.separator.opacity(0.35), lineWidth: 0.5)
                }
            }
        }
    }

    private func continueReading(space: ReadingSpace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ReaderSectionHeading(title: "继续阅读", systemImage: "bookmark")
            Button {
                model.openSpace(space.id)
            } label: {
                LibraryContinuationLabel(title: space.title,
                    resume: model.resumeDescription(for: space.id),
                    symbol: leadingSymbol(for: space),
                    color: ReaderTheme.coverColor(for: space.id),
                    fraction: model.progressFraction(for: space.id), compact: compactLayout)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: compactLayout ? .infinity : 820, alignment: .leading)
            .accessibilityLabel("继续阅读 \(space.title)，进度 \(Int(model.progressFraction(for: space.id) * 100))%")
            .accessibilityIdentifier("library-continue-reading")
        }
    }

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ReaderSectionHeading(title: model.selectedCollection == .allSpaces ? "书架" : model.selectedCollection.title,
                    count: model.visibleSpaces.count)
                Spacer()
                if isSelectingSpaces && !selectedSpaceIDs.isEmpty {
                    Menu("整理 \(selectedSpaceIDs.count) 项") {
                        SpaceOrganizationMenu(spaceIDs: selectedSpaceIDs)
                    }
                }
                Button {
                    isSelectingSpaces.toggle()
                    if !isSelectingSpaces { selectedSpaceIDs.removeAll() }
                } label: {
                    ReaderActionLabel(title: isSelectingSpaces ? "完成" : "选择", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isSelectingSpaces ? "完成选择空间" : "选择空间")
            }
            LazyVGrid(columns: shelfColumns, alignment: .leading, spacing: 24) {
                ForEach(model.visibleSpaces) { space in
                    SpaceBookCard(
                        space: space,
                        isSelecting: isSelectingSpaces,
                        isSelected: selectedSpaceIDs.contains(space.id),
                        onSelect: {
                            if !selectedSpaceIDs.insert(space.id).inserted {
                                selectedSpaceIDs.remove(space.id)
                            }
                        }
                    )
                        .environmentObject(model)
                }
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 22) {
            Image(systemName: "books.vertical")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(ReaderTheme.accent)
            VStack(spacing: 8) {
                Text("建立你的阅读资料库")
                    .font(.title2.weight(.semibold))
                Text(emptyLibraryDescription)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 500)
            }
            ViewThatFits {
                HStack(spacing: 12) { emptyActions }
                VStack(spacing: 10) { emptyActions }
            }
            Text("支持 PDF、EPUB、Markdown、文本、HTML、代码、网页、目录和公开 GitHub 仓库")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: compactLayout ? 430 : 520)
        .padding(compactLayout ? 16 : 24)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var emptyActions: some View {
        Button {
            model.presentLocalSourceImporter()
        } label: {
            ReaderActionLabel(title: "选择文件或目录", systemImage: "folder")
        }
        .buttonStyle(.borderedProminent)

        Button {
            model.isImportSheetPresented = true
        } label: {
            ReaderActionLabel(title: "粘贴 URL", systemImage: "link")
        }
        .buttonStyle(.bordered)
    }

    private var recentSpace: ReadingSpace? {
        guard model.selectedCollection == .allSpaces || model.selectedCollection == .recent else {
            return nil
        }
        return model.visibleSpaces
            .filter { $0.lastOpenedAt != nil }
            .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    private var shelfColumns: [GridItem] {
        [GridItem(.adaptive(
            minimum: ReaderChromeMetrics.shelfMinimumWidth(compact: compactLayout,
                accessibilitySize: dynamicTypeSize >= .xxLarge),
            maximum: dynamicTypeSize >= .xxLarge ? 320 : 220
        ), spacing: compactLayout ? 16 : 24)]
    }

    private var compactLayout: Bool {
#if os(iOS)
        horizontalSizeClass == .compact
#else
        false
#endif
    }

    private func leadingSymbol(for space: ReadingSpace) -> String {
        let sources = model.sourceIDs(in: space.id).compactMap(model.source(id:))
        if sources.contains(where: { $0.originKind == .githubRepository }) {
            return "chevron.left.forwardslash.chevron.right"
        }
        return sources.count > 1 ? "books.vertical.fill" : "book.closed.fill"
    }

    private var emptyLibraryDescription: String {
#if os(macOS)
        "拖入材料、按 ⌘O，或粘贴网页和公开 GitHub URL。内容会先变得可读，再在后台完成索引。"
#else
        "选择材料、从其他 App 打开文件，或粘贴网页和公开 GitHub URL。内容会先变得可读，再在后台完成索引。"
#endif
    }

    private func label(for state: PendingImport.State) -> String {
        switch state {
        case .queued: "等待导入"
        case .copying: "正在保存副本"
        case .adapting: "正在准备阅读视图"
        case .indexing: "已可阅读，正在建立索引"
        case .failed(let message): "失败：\(message)"
        }
    }
}

private struct SpaceBookCard: View {
    @EnvironmentObject private var model: AppModel
    let space: ReadingSpace
    var isSelecting = false
    var isSelected = false
    var onSelect: () -> Void = {}

    private var sources: [Source] {
        model.sourceIDs(in: space.id).compactMap(model.source(id:))
    }

    var body: some View {
        Button {
            if isSelecting { onSelect() } else { model.openSpace(space.id) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                EditorialCover(
                    title: space.title,
                    symbol: leadingSymbol,
                    color: ReaderTheme.coverColor(for: space.id),
                    progress: model.progressFraction(for: space.id),
                    isFavorite: space.isFavorite
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(cardDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ReaderStatusBadge(title: space.organizationState.title,
                        systemImage: space.organizationState.systemImage)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? ReaderTheme.accent : Color.secondary)
                        .padding(8)
                        .background(.regularMaterial, in: Circle())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(space.isFavorite ? "取消收藏" : "收藏") {
                model.toggleSpaceFavorite(space.id)
            }
            Divider()
            SpaceOrganizationMenu(spaceIDs: [space.id])
        }
        .accessibilityLabel(
            "\(space.title)，\(sources.count) 个来源，进度 \(Int(model.progressFraction(for: space.id) * 100))%"
        )
        .accessibilityIdentifier("space-card-\(space.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var cardDetail: String {
        let progress = Int(model.progressFraction(for: space.id) * 100)
        return progress > 0 ? "\(sources.count) 个来源 · \(progress)%" : "\(sources.count) 个来源"
    }

    private var leadingSymbol: String {
        if sources.contains(where: { $0.originKind == .githubRepository }) {
            return "chevron.left.forwardslash.chevron.right"
        }
        return sources.count > 1 ? "books.vertical.fill" : "book.closed.fill"
    }
}

/// Presentation only; opening the Space and its action identity stay in LibraryHomeView.
struct LibraryContinuationLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let resume: String?
    let symbol: String
    let color: Color
    let fraction: Double
    let compact: Bool

    var body: some View {
        LibraryContinuationLayout(spacing: compact ? 16 : 20,
            stacksVertically: dynamicTypeSize.isAccessibilitySize) {
            EditorialCover(title: title, symbol: symbol, color: color,
                progress: fraction, showsTitle: false)
                .frame(width: compact ? 64 : 72, height: compact ? 84 : 96)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(compact ? .headline : .title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let resume {
                    Text(resume)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ReaderProgressSummary(fraction: fraction)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(ReaderTheme.accent)
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderTheme.raised, in: RoundedRectangle(cornerRadius: ReaderTheme.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ReaderTheme.panelRadius)
                .stroke(.separator.opacity(0.38), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: ReaderTheme.panelRadius))
    }
}

/// A narrow card gives the copy the full width below a small cover/action header.
/// Measuring with an unspecified height lets long titles grow instead of clipping.
struct LibraryContinuationLayout: Layout {
    var spacing: CGFloat
    var stacksVertically: Bool

    private struct Measurement {
        let size: CGSize
        let cover: CGSize
        let copy: CGSize
        let arrow: CGSize
        let copyWidth: CGFloat
        let stacked: Bool
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measurement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let measured = measurement(width: bounds.width, subviews: subviews)
        let headerHeight = measured.stacked
            ? max(measured.cover.height, measured.arrow.height) : measured.size.height
        subviews[0].place(at: CGPoint(x: bounds.minX,
            y: bounds.minY + (headerHeight - measured.cover.height) / 2),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: measured.cover.width, height: measured.cover.height))
        subviews[1].place(at: CGPoint(
            x: bounds.minX + (measured.stacked ? 0 : measured.cover.width + spacing),
            y: bounds.minY + (measured.stacked
                ? headerHeight + spacing : (headerHeight - measured.copy.height) / 2)),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: measured.copyWidth, height: measured.copy.height))
        subviews[2].place(at: CGPoint(x: bounds.minX + measured.size.width - measured.arrow.width,
            y: bounds.minY + (headerHeight - measured.arrow.height) / 2),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: measured.arrow.width, height: measured.arrow.height))
    }

    private func measurement(width proposedWidth: CGFloat?, subviews: Subviews) -> Measurement {
        guard subviews.count == 3 else {
            return Measurement(size: .zero, cover: .zero, copy: .zero,
                arrow: .zero, copyWidth: 0, stacked: true)
        }
        let cover = subviews[0].sizeThatFits(.unspecified)
        let arrow = subviews[2].sizeThatFits(.unspecified)
        let minimumCopy = subviews[1].sizeThatFits(ProposedViewSize(width: 0, height: nil))
        let horizontalMinimum = cover.width + arrow.width + spacing * 2
            + ReaderChromeMetrics.continuationMinimumCopyWidth
        // A finite ideal proposal also keeps a long filename from defining window width.
        let idealWidth = max(horizontalMinimum, 440)
        let offeredWidth = proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth
        let width = max(offeredWidth, max(cover.width + arrow.width + spacing, minimumCopy.width))
        let stacked = stacksVertically || width < horizontalMinimum
        let copyWidth = stacked ? width : width - cover.width - arrow.width - spacing * 2
        let copy = subviews[1].sizeThatFits(ProposedViewSize(width: copyWidth, height: nil))
        let headerHeight = max(cover.height, arrow.height)
        let height = stacked ? headerHeight + spacing + copy.height : max(headerHeight, copy.height)
        return Measurement(size: CGSize(width: width, height: height), cover: cover, copy: copy,
            arrow: arrow, copyWidth: copyWidth, stacked: stacked)
    }
}

/// The shelf keeps its familiar minimum cover ratio, but the title may make it taller.
private struct LibraryShelfCoverLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 172
        let width = max(1, proposedWidth)
        let contentSize = content.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: max(width, contentSize.width), height: max(width / 0.82, contentSize.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

struct EditorialCover: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let symbol: String
    let color: Color
    let progress: Double
    var isFavorite = false
    var showsTitle = true

    var body: some View {
        if showsTitle {
            LibraryShelfCoverLayout { coverContent }
        } else {
            coverContent
        }
    }

    private var coverContent: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: ReaderTheme.coverRadius)
                .fill(ReaderTheme.raised)
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 5)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: ReaderTheme.coverRadius))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: symbol)
                    Spacer()
                    if isFavorite { Image(systemName: "star.fill") }
                }
                // The title-free thumbnail is decorative, not a text-size control.
                .font(showsTitle ? .body : .system(size: 24))
                .foregroundStyle(ReaderTheme.accent)
                Spacer()
                if showsTitle {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 4)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)

            if progress > 0 {
                GeometryReader { geometry in
                    VStack {
                        Spacer()
                        Rectangle()
                            .fill(color.opacity(0.7))
                            .frame(width: geometry.size.width * min(max(progress, 0), 1), height: 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .clipShape(RoundedRectangle(cornerRadius: ReaderTheme.coverRadius))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: ReaderTheme.coverRadius)
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
    }
}
