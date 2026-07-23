import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 278, max: 340)
        } detail: {
            ReaderSurfaceView()
        }
        .inspector(isPresented: $model.isRouteInspectorPresented) {
            RouteInspectorView()
                .inspectorColumnWidth(min: 286, ideal: 326, max: 380)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                sourceRevisionPill
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("GitHub Repo…", systemImage: "point.3.connected.trianglepath.dotted") {
                        model.isImportSheetPresented = true
                    }
                    Button("本地 PDF…", systemImage: "doc.richtext") {
                        model.presentLocalPDFImporter()
                    }
                    Divider()
                    Button("恢复示例书籍", systemImage: "arrow.counterclockwise") {
                        model.restoreDemo()
                    }
                } label: {
                    Label("导入材料", systemImage: "plus")
                }
                .help("导入 GitHub Repo 或本地 PDF")

                Button {
                    model.isRouteInspectorPresented.toggle()
                } label: {
                    Label(
                        "阅读路线",
                        systemImage: model.isRouteInspectorPresented
                            ? "sidebar.trailing"
                            : "sidebar.trailing"
                    )
                }
                .help(model.isRouteInspectorPresented ? "隐藏阅读路线" : "显示阅读路线")
            }
        }
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
        .tint(ReaderTheme.teal)
        .background(ReaderTheme.paper)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .allowsHitTesting(false)
                    .onAppear {
                        collapseInspectorIfNeeded(for: geometry.size.width)
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        collapseInspectorIfNeeded(for: width)
                    }
            }
        }
    }

    private var sourceRevisionPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(
                    model.isResolvingRepository
                        ? Color.orange
                        : ReaderTheme.teal
                )
                .frame(width: 7, height: 7)
            Text(model.activeSourceRevisionLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前来源版本 \(model.activeSourceRevisionLabel)")
    }

    private func collapseInspectorIfNeeded(for width: CGFloat) {
        guard width <= 1_000, model.isRouteInspectorPresented else {
            return
        }
        model.isRouteInspectorPresented = false
    }
}
