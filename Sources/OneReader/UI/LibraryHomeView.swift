import SwiftUI

struct LibraryHomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let columns = [
        GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 18),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !model.spaces.isEmpty || !model.pendingImports.isEmpty {
                    header
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
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(model.visibleSpaces) { space in
                            SpaceCard(space: space)
                                .environmentObject(model)
                        }
                    }
                }
            }
            .padding(.horizontal, horizontalSizeClass == .compact ? 18 : 28)
            .padding(.top, 24)
            .padding(.bottom, 52)
        }
        .background(ReaderTheme.paper)
        .navigationTitle(model.selectedCollection.title)
    }

    private var header: some View {
        Group {
            if horizontalSizeClass == .compact {
                Text(libraryDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 16) {
                        headerTitle
                        Spacer()
                        addMaterialButton
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        headerTitle
                        addMaterialButton
                    }
                }
            }
        }
    }

    private var headerTitle: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.selectedCollection.title)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(libraryDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
    }

    private var addMaterialButton: some View {
        Button {
            model.isImportSheetPresented = true
        } label: {
            Label("添加材料", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
    }

    private var libraryDescription: String {
        "每个空间可以组合 PDF、EPUB、网页、代码和目录；基础阅读不依赖模型。"
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("处理中")
                .font(.headline)
            ForEach(model.pendingImports) { item in
                HStack(spacing: 12) {
                    if item.state.isActive {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "xmark.circle.fill")
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
                        Button("移除") {
                            model.dismissPendingImport(item.id)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("移除失败的导入记录")
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(ReaderTheme.teal.opacity(0.1))
                    .frame(width: 116, height: 116)
                Image(systemName: "books.vertical")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(ReaderTheme.teal)
            }
            VStack(spacing: 7) {
                Text("建立你的阅读资料库")
                    .font(.title2.weight(.semibold))
                Text(emptyLibraryDescription)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
            }
            HStack(spacing: 12) {
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
            Text("支持 PDF、EPUB、Markdown、文本、HTML、代码、网页、目录和公开 GitHub 仓库")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 480)
        .padding(30)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [7, 7]))
        )
        .accessibilityElement(children: .contain)
    }

    private var emptyLibraryDescription: String {
#if os(macOS)
        "拖入材料、按 ⌘O，或粘贴网页和公开 GitHub URL。OneReader 会先让内容可读，再在后台建立索引和阅读结构。"
#else
        "选择材料、从其他 App 打开文件，或粘贴网页和公开 GitHub URL。OneReader 会先让内容可读，再在后台建立索引和阅读结构。"
#endif
    }

    private func label(for state: PendingImport.State) -> String {
        switch state {
        case .queued: "等待导入"
        case .copying: "正在创建托管快照"
        case .adapting: "正在探测阅读能力"
        case .indexing: "已可阅读，正在后台建索引"
        case .failed(let message): "失败：\(message)"
        }
    }
}

private struct SpaceCard: View {
    @EnvironmentObject private var model: AppModel
    let space: ReadingSpace

    private var sources: [Source] {
        model.sourceIDs(in: space.id).compactMap(model.source(id:))
    }

    var body: some View {
        Button {
            model.openSpace(space.id)
        } label: {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(cardColor.gradient)
                        Image(systemName: leadingSymbol)
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 58, height: 68)

                    Spacer()
                    if space.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(ReaderTheme.orange)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(space.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(sourceSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: model.progressFraction(for: space.id))
                        .tint(ReaderTheme.teal)
                    HStack {
                        Label("\(sources.count) 个来源", systemImage: "square.stack.3d.up")
                        Spacer()
                        if let lastOpenedAt = space.lastOpenedAt {
                            Text(lastOpenedAt, style: .relative)
                        } else {
                            Text("未开始")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(17)
            .frame(maxWidth: .infinity, minHeight: 236, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.separator.opacity(0.55))
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
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

    private var sourceSummary: String {
        let names = sources.prefix(3).map(\.displayName)
        return names.isEmpty ? "等待添加来源" : names.joined(separator: " · ")
    }

    private var leadingSymbol: String {
        if sources.contains(where: { $0.originKind == .githubRepository }) { return "chevron.left.forwardslash.chevron.right" }
        if sources.count > 1 { return "books.vertical.fill" }
        return "book.closed.fill"
    }

    private var cardColor: Color {
        sources.contains(where: { $0.originKind == .githubRepository })
            ? ReaderTheme.teal
            : ReaderTheme.orange
    }
}
