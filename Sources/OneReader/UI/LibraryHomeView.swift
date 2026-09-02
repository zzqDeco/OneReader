import SwiftUI

struct LibraryHomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compactLayout ? 24 : 30) {
                if !model.spaces.isEmpty || !model.pendingImports.isEmpty {
                    libraryHeader
                }

                if !model.pendingImports.isEmpty {
                    pendingSection
                }

                if model.spaces.isEmpty && model.pendingImports.isEmpty {
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
            .padding(.horizontal, compactLayout ? 18 : 32)
            .padding(.top, compactLayout ? 18 : 30)
            .padding(.bottom, 56)
            .frame(maxWidth: .infinity)
        }
        .background(ReaderTheme.grouped)
        .navigationTitle(model.selectedCollection.title)
    }

    private var libraryHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .lastTextBaseline, spacing: 20) {
                headerCopy
                Spacer()
                addMaterialButton
            }
            VStack(alignment: .leading, spacing: 14) {
                headerCopy
                if !compactLayout { addMaterialButton }
            }
        }
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !compactLayout {
                Text(model.selectedCollection.title)
                    .font(.system(size: 32, weight: .semibold))
            }
            Text(libraryDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addMaterialButton: some View {
        Button {
            model.isImportSheetPresented = true
        } label: {
            Label("添加材料", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var libraryDescription: String {
        compactLayout
            ? "从上次停下的位置继续，或打开一本资料。"
            : "PDF、电子书、网页和代码，都在同一个安静的阅读空间里。"
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("正在整理", systemImage: "arrow.triangle.2.circlepath")
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
                .padding(13)
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
            sectionTitle("继续阅读", systemImage: "bookmark")
            Button {
                model.openSpace(space.id)
            } label: {
                HStack(spacing: compactLayout ? 16 : 20) {
                    EditorialCover(
                        title: space.title,
                        symbol: leadingSymbol(for: space),
                        color: ReaderTheme.coverColor(for: space.id),
                        progress: model.progressFraction(for: space.id)
                    )
                    .frame(width: compactLayout ? 78 : 86, height: compactLayout ? 106 : 116)

                    VStack(alignment: .leading, spacing: 7) {
                        Text(space.title)
                            .font(compactLayout ? .headline : .title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let resume = model.resumeDescription(for: space.id) {
                            Text(resume)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(compactLayout ? 2 : 1)
                                .multilineTextAlignment(.leading)
                        }
                        HStack(spacing: 8) {
                            Text("\(Int(model.progressFraction(for: space.id) * 100))%")
                                .font(.caption.monospacedDigit().weight(.semibold))
                            ProgressView(value: model.progressFraction(for: space.id))
                                .tint(ReaderTheme.accent)
                                .frame(maxWidth: 190)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ReaderTheme.accent)
                }
                .padding(compactLayout ? 14 : 17)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ReaderTheme.raised, in: RoundedRectangle(cornerRadius: ReaderTheme.panelRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: ReaderTheme.panelRadius)
                        .stroke(.separator.opacity(0.38), lineWidth: 0.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: ReaderTheme.panelRadius))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: compactLayout ? .infinity : 820, alignment: .leading)
            .accessibilityLabel("继续阅读 \(space.title)，进度 \(Int(model.progressFraction(for: space.id) * 100))%")
        }
    }

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(model.selectedCollection == .allSpaces ? "书架" : model.selectedCollection.title)
            LazyVGrid(columns: shelfColumns, alignment: .leading, spacing: compactLayout ? 24 : 30) {
                ForEach(model.visibleSpaces) { space in
                    SpaceBookCard(space: space)
                        .environmentObject(model)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, systemImage: String? = nil) -> some View {
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(ReaderTheme.accent)
            }
            Text(title)
                .font(.headline)
        }
        .accessibilityAddTraits(.isHeader)
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
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: compactLayout ? 430 : 520)
        .padding(30)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var emptyActions: some View {
        Button {
            model.presentLocalSourceImporter()
        } label: {
            Label("选择文件或目录", systemImage: "folder")
        }
        .buttonStyle(.borderedProminent)

        Button {
            model.isImportSheetPresented = true
        } label: {
            Label("粘贴 URL", systemImage: "link")
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
        if compactLayout {
            return [
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14),
            ]
        }
        return [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 24)]
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

    private var sources: [Source] {
        model.sourceIDs(in: space.id).compactMap(model.source(id:))
    }

    var body: some View {
        Button {
            model.openSpace(space.id)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                EditorialCover(
                    title: space.title,
                    symbol: leadingSymbol,
                    color: ReaderTheme.coverColor(for: space.id),
                    progress: model.progressFraction(for: space.id),
                    isFavorite: space.isFavorite
                )
                .aspectRatio(0.72, contentMode: .fit)

                VStack(alignment: .leading, spacing: 4) {
                    Text(space.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(cardDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(space.isFavorite ? "取消收藏" : "收藏") {
                model.toggleSpaceFavorite(space.id)
            }
        }
        .accessibilityLabel(
            "\(space.title)，\(sources.count) 个来源，进度 \(Int(model.progressFraction(for: space.id) * 100))%"
        )
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

private struct EditorialCover: View {
    let title: String
    let symbol: String
    let color: Color
    let progress: Double
    var isFavorite = false

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: ReaderTheme.coverRadius)
                .fill(color)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: symbol)
                    Spacer()
                    if isFavorite { Image(systemName: "star.fill") }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(title)
                    .font(.system(.headline, design: .serif, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)

            if progress > 0 {
                GeometryReader { geometry in
                    VStack {
                        Spacer()
                        Rectangle()
                            .fill(.white.opacity(0.72))
                            .frame(width: geometry.size.width * min(max(progress, 0), 1), height: 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .clipShape(RoundedRectangle(cornerRadius: ReaderTheme.coverRadius))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: ReaderTheme.coverRadius)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
    }
}
