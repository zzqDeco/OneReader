import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 310)
        } detail: {
            detail
        }
        .toolbar { toolbar }
        .sheet(isPresented: $model.isImportSheetPresented) {
            ImportSourceSheet()
                .environmentObject(model)
        }
        .alert(item: $model.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .confirmationDialog(
            "确认大型导入",
            isPresented: Binding(
                get: { model.largeImportConfirmation != nil },
                set: { if !$0 { model.largeImportConfirmation = nil } }
            ),
            presenting: model.largeImportConfirmation
        ) { _ in
            Button("继续导入") { model.confirmLargeImport() }
            Button("取消", role: .cancel) { model.largeImportConfirmation = nil }
        } message: { confirmation in
            Text("\(confirmation.request.displayName) 约 \(ByteCountFormatter.string(fromByteCount: confirmation.byteCount, countStyle: .file))。OneReader 会保留至少 2 GiB 可用空间。")
        }
        .confirmationDialog(
            "从资料库移除来源？",
            isPresented: Binding(
                get: { model.pendingSourceRemoval != nil },
                set: { if !$0 { model.pendingSourceRemoval = nil } }
            ),
            presenting: model.pendingSourceRemoval
        ) { _ in
            Button("移到废纸篓并移除", role: .destructive) {
                model.confirmSourceRemoval()
            }
            Button("取消", role: .cancel) { model.pendingSourceRemoval = nil }
        } message: { source in
            Text("将移除“\(source.displayName)”及其本地阅读记录；独占的托管副本会进入 macOS 废纸篓，原始文件不会被修改。")
        }
        .onOpenURL { model.handleOpenURL($0) }
        .dropDestination(for: URL.self) { urls, _ in
            model.importLocalURLs(urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                isDropTargeted = isTargeted
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(ReaderTheme.teal, style: StrokeStyle(lineWidth: 3, dash: [9, 7]))
                    .background(ReaderTheme.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                    .padding(12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .tint(ReaderTheme.teal)
    }

    @ViewBuilder
    private var detail: some View {
        if model.isReadingWorkspaceOpen {
            GeometryReader { geometry in
                let compact = geometry.size.width < 920
                ZStack(alignment: .trailing) {
                    HStack(spacing: 0) {
                        ReaderNavigationSidebar()
                            .frame(width: compact ? 210 : 245)
                        Divider()
                        ReaderSurfaceView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)

                        if model.isInspectorPresented, !compact {
                            Divider()
                            ReaderInspectorView()
                                .frame(width: 338)
                        }
                    }

                    if model.isInspectorPresented, compact {
                        Color.black.opacity(0.12)
                            .contentShape(Rectangle())
                            .onTapGesture { model.isInspectorPresented = false }
                            .accessibilityHidden(true)
                        ReaderInspectorView()
                            .frame(width: min(338, geometry.size.width * 0.62))
                            .shadow(color: .black.opacity(0.18), radius: 18, x: -5)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.18),
                    value: model.isInspectorPresented
                )
                .task(id: compact) {
                    if compact, model.isInspectorPresented {
                        model.isInspectorPresented = false
                    }
                }
            }
        } else {
            LibraryHomeView()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if model.isReadingWorkspaceOpen, let snapshot = model.selectedSnapshot {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ReaderTheme.teal)
                        .frame(width: 7, height: 7)
                    Text(String(snapshot.revision.prefix(9)))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("当前 Snapshot \(String(snapshot.revision.prefix(9)))")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("选择文件或目录…", systemImage: "folder") {
                    model.presentLocalSourceImporter()
                }
                Button("粘贴 URL…", systemImage: "link") {
                    model.isImportSheetPresented = true
                }
                if model.isReadingWorkspaceOpen {
                    Divider()
                    Button("加入当前 Reading Space…", systemImage: "rectangle.stack.badge.plus") {
                        model.presentLocalSourceImporter(destination: .currentSpace)
                    }
                }
            } label: {
                Label("添加材料", systemImage: "plus")
            }
            .help("添加任意支持的来源")

            if model.isReadingWorkspaceOpen {
                Button {
                    model.navigationTab = .search
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .help("搜索 Reading Space")

                Button {
                    model.isInspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(model.isInspectorPresented ? "隐藏 Inspector" : "显示 Inspector")
            }
        }
    }
}
