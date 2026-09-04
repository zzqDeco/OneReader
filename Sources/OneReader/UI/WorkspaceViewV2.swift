import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private struct ReadingPositionCaptureTargetKey: EnvironmentKey {
    static let defaultValue = UUID()
}

extension EnvironmentValues {
    var readingPositionCaptureTargetID: UUID {
        get { self[ReadingPositionCaptureTargetKey.self] }
        set { self[ReadingPositionCaptureTargetKey.self] = newValue }
    }
}

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isDropTargeted = false
    @State private var isMobileNavigationPresented = false
    @State private var isSettingsPresented = false
    @State private var readingPositionCaptureTargetID = UUID()

    var body: some View {
        rootWorkspace
        .environment(
            \.readingPositionCaptureTargetID,
            readingPositionCaptureTargetID
        )
        .background {
            ReadingPositionCaptureWindowObserver {
                model.activateReadingPositionCaptureTarget(
                    readingPositionCaptureTargetID
                )
            }
            .frame(width: 0, height: 0)
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
            Button(removalButtonTitle, role: .destructive) {
                model.confirmSourceRemoval()
            }
            Button("取消", role: .cancel) { model.pendingSourceRemoval = nil }
        } message: { source in
            Text(removalMessage(for: source))
        }
        .onOpenURL { model.handleOpenURL($0) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                model.flushReadingPosition()
            }
        }
        .onChange(of: model.readerNavigationRequestID) { _, _ in
            guard model.isReadingWorkspaceOpen else { return }
            if usesCompactReader {
                isMobileNavigationPresented = true
            } else {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    columnVisibility = .all
                }
            }
        }
#if os(macOS)
        // A window-sized drop destination installs a drag interaction over every
        // descendant. That is useful on macOS, but on iPhone it competes with
        // the vertical pan recognizers owned by Library and reader scroll views.
        // iOS keeps the document picker / Open In entry points instead.
        .dropDestination(for: URL.self) { urls, _ in
            model.importLocalURLs(urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                isDropTargeted = isTargeted
            }
        }
#endif
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
#if os(iOS)
        .fileImporter(
            isPresented: Binding(
                get: { model.platformFileImportPurpose != nil },
                set: { if !$0 { model.platformFileImportPurpose = nil } }
            ),
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: model.platformFileImportPurpose?.allowsMultipleSelection ?? true
        ) { result in
            model.completePlatformFileImport(result)
        }
        .sheet(isPresented: $isMobileNavigationPresented) {
            NavigationStack {
                ReaderNavigationSidebar(showsLibraryBackButton: false)
                    .environmentObject(model)
                    .navigationTitle("阅读导航")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") { isMobileNavigationPresented = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                ReaderSettingsView()
                    .environmentObject(model)
                    .navigationTitle("设置")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { isSettingsPresented = false }
                        }
                    }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { usesCompactReader && model.isInspectorPresented },
                set: { model.isInspectorPresented = $0 }
            )
        ) {
            NavigationStack {
                ReaderInspectorView()
                    .environmentObject(model)
                    .navigationTitle("阅读辅助")
            }
            .presentationDetents([.medium, .large])
        }
#endif
    }

    @ViewBuilder
    private var rootWorkspace: some View {
#if os(iOS)
        if usesCompactReader {
            NavigationStack {
                LibraryHomeView()
                    .toolbar { toolbar }
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(isPresented: compactReaderBinding) {
                        ReaderSurfaceView(
                            onShowNavigation: { isMobileNavigationPresented = true },
                            onShowAssistance: {
                                model.inspectorTab = .annotations
                                model.isInspectorPresented = true
                            }
                        )
                            .toolbar { toolbar }
                            .navigationBarTitleDisplayMode(.inline)
                    }
            }
        } else {
            splitWorkspace
        }
#else
        splitWorkspace
#endif
    }

    private var splitWorkspace: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            if model.isReadingWorkspaceOpen {
                ReaderNavigationSidebar()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            } else {
                LibrarySidebarView()
                    .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 310)
            }
        } detail: {
            detail
        }
        .toolbar { toolbar }
    }

    @ViewBuilder
    private var detail: some View {
        if model.isReadingWorkspaceOpen {
            if usesCompactReader {
                ReaderSurfaceView()
                    .task {
                        model.isInspectorPresented = false
                    }
            } else {
                GeometryReader { geometry in
                    let compact = geometry.size.width < 760
                    ZStack(alignment: .trailing) {
                        HStack(spacing: 0) {
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
            }
        } else {
            LibraryHomeView()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
#if os(iOS)
            if usesCompactReader, !model.isReadingWorkspaceOpen {
                Menu {
                    ForEach(LibraryCollection.allCases) { collection in
                        Button {
                            model.selectCollection(collection)
                        } label: {
                            Label(collection.title, systemImage: collection.systemImage)
                        }
                    }
                } label: {
                    Label("资料库分类", systemImage: model.selectedCollection.systemImage)
                }
            }
#endif

            if !model.isReadingWorkspaceOpen || !usesCompactReader {
                Menu {
                    Button("选择文件或目录…", systemImage: "folder") {
                        model.presentLocalSourceImporter()
                    }
                    Button("粘贴 URL…", systemImage: "link") {
                        model.isImportSheetPresented = true
                    }
                    if model.isReadingWorkspaceOpen {
                        Divider()
                        Button("加入当前阅读空间…", systemImage: "rectangle.stack.badge.plus") {
                            model.presentLocalSourceImporter(destination: .currentSpace)
                        }
                    }
                } label: {
                    Label("添加材料", systemImage: "plus")
                }
                .help("添加任意支持的来源")
            }

            if model.isReadingWorkspaceOpen, !usesCompactReader {
                Button {
                    model.revealReaderNavigation(.search)
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .help("搜索阅读空间")

                Button {
                    model.isInspectorPresented.toggle()
                } label: {
                    Label("阅读辅助", systemImage: "sidebar.trailing")
                }
                .help(model.isInspectorPresented ? "隐藏阅读辅助" : "显示阅读辅助")
            }

#if os(iOS)
            if !model.isReadingWorkspaceOpen {
                Button {
                    isSettingsPresented = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .help("阅读与模型设置")
            } else if usesCompactReader {
                Menu {
                    Button("加入当前阅读空间", systemImage: "plus") {
                        model.presentLocalSourceImporter(destination: .currentSpace)
                    }
                    Button("搜索正文", systemImage: "magnifyingglass") {
                        model.revealReaderNavigation(.search)
                    }
                    if model.canOpenOriginalSource {
                        Button("打开原始来源", systemImage: "arrow.up.right.square") {
                            model.openOriginalSource()
                        }
                    }
                    Divider()
                    Button("设置", systemImage: "gearshape") {
                        isSettingsPresented = true
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
            }
#endif
        }
    }

    private var usesCompactReader: Bool {
#if os(iOS)
        horizontalSizeClass == .compact
#else
        false
#endif
    }

    private var compactReaderBinding: Binding<Bool> {
        Binding(
            get: { model.isReadingWorkspaceOpen },
            set: { isPresented in
                if !isPresented {
                    model.closeReadingWorkspace()
                }
            }
        )
    }

    private func removalMessage(for source: Source) -> String {
#if os(macOS)
        "将移除“\(source.displayName)”及其本地阅读记录；独占的托管副本会进入 macOS 废纸篓，原始文件不会被修改。"
#else
        "将移除“\(source.displayName)”及其本地阅读记录；独占的托管副本会从此设备的 App 沙盒移除，原始文件不会被修改。"
#endif
    }

    private var removalButtonTitle: String {
#if os(macOS)
        "移到废纸篓并移除"
#else
        "从此设备移除"
#endif
    }
}

#if os(macOS)
private struct ReadingPositionCaptureWindowObserver: NSViewRepresentable {
    let onBecomeKey: @MainActor () -> Void

    func makeNSView(context: Context) -> KeyWindowObserverView {
        KeyWindowObserverView(onBecomeKey: onBecomeKey)
    }

    func updateNSView(_ view: KeyWindowObserverView, context: Context) {
        view.onBecomeKey = onBecomeKey
        view.activateIfKey()
    }

    final class KeyWindowObserverView: NSView {
        var onBecomeKey: @MainActor () -> Void

        init(onBecomeKey: @escaping @MainActor () -> Void) {
            self.onBecomeKey = onBecomeKey
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            activateIfKey()
        }

        func activateIfKey() {
            guard window?.isKeyWindow == true else { return }
            onBecomeKey()
        }

        @objc private func windowDidBecomeKey(_ notification: Notification) {
            onBecomeKey()
        }
    }
}
#else
private struct ReadingPositionCaptureWindowObserver: UIViewRepresentable {
    let onBecomeKey: @MainActor () -> Void

    func makeUIView(context: Context) -> KeyWindowObserverView {
        KeyWindowObserverView(onBecomeKey: onBecomeKey)
    }

    func updateUIView(_ view: KeyWindowObserverView, context: Context) {
        view.onBecomeKey = onBecomeKey
        view.activateIfKey()
    }

    final class KeyWindowObserverView: UIView {
        var onBecomeKey: @MainActor () -> Void

        init(onBecomeKey: @escaping @MainActor () -> Void) {
            self.onBecomeKey = onBecomeKey
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            NotificationCenter.default.removeObserver(
                self,
                name: UIWindow.didBecomeKeyNotification,
                object: nil
            )
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: UIWindow.didBecomeKeyNotification,
                object: window
            )
            activateIfKey()
        }

        func activateIfKey() {
            guard window?.isKeyWindow == true else { return }
            onBecomeKey()
        }

        @objc private func windowDidBecomeKey(_ notification: Notification) {
            onBecomeKey()
        }
    }
}
#endif
