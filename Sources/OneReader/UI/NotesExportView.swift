import SwiftUI
import UniformTypeIdentifiers

struct NotesExportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: NotesCenterModel
    let spaces: [ReadingSpace]
    @State private var scope = NotesExportScope.filtered
    @State private var spaceID: String?
    @State private var options = NotesExportOptions()
    @State private var snapshot: NotesExportSnapshot?
    @State private var isPreparing = false
    @State private var showsDirectoryPicker = false
    @State private var task: Task<Void, Never>?
    @State private var progress: NotesMarkdownExporter.Progress?
    @State private var errorMessage: String?
    @State private var completion: URL?
    @State private var generation = UUID()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ReaderPanelHeading(title: "带走你的阅读笔记",
                        subtitle: "生成独立的 Markdown 副本，按来源整理；不会覆盖已有文件。",
                        systemImage: "square.and.arrow.up")
                }
                Section("导出范围") {
                    Picker("范围", selection: $scope) {
                        Text("当前筛选结果").tag(NotesExportScope.filtered)
                        Text("所选 \(model.selectedIDs.count) 条").tag(NotesExportScope.selected)
                        Text("指定空间的全部标注").tag(NotesExportScope.space)
                    }
                    if scope == .space {
                        Picker("阅读空间", selection: $spaceID) {
                            Text("请选择").tag(nil as String?)
                            ForEach(spaces) { Text($0.title).tag(Optional($0.id)) }
                        }
                    }
                }
                Section("内容与隐私") {
                    Toggle("用户笔记", isOn: $options.includeNotes)
                    Toggle("原始网页地址", isOn: $options.includeWebURLs)
                    Text("网页地址会移除查询参数与片段。不导出原始书籍、附件、Provider 配置或对话。")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("固定包含的字段") {
                        Text("摘录、标签、时间、来源/空间/快照、人可读位置、定位状态及仅适用于本机原资料库的回链。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("预览") {
                    Button { prepare() } label: {
                        ReaderActionLabel(title: "生成导出预览", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparing || invalidScope)
                    .accessibilityIdentifier("notes-export-preview")
                    if let snapshot {
                        Text("\(snapshot.entries.count) 条标注 · \(Set(snapshot.entries.map { $0.annotation.sourceID }).count) 个来源")
                            .font(.headline)
                        Text("预览捕获于 \(snapshot.capturedAt.formatted(date: .numeric, time: .standard))；后续编辑不会改变这个导出快照。")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("查看 Markdown 索引") {
                            Text(NotesMarkdownExporter.renderIndex(snapshot))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        Text("输出为 index.md + 按来源分组的 Markdown 文件。导出是静态副本，不会同步覆盖编辑器中的改动；目标同名时自动创建新副本。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { showsDirectoryPicker = true } label: {
                            ReaderActionLabel(title: "选择文件夹并导出…", systemImage: "folder")
                        }
                            .buttonStyle(.bordered)
                            .disabled(isPreparing || snapshot.entries.isEmpty)
                            .accessibilityIdentifier("notes-export-directory")
                    }
                    if isPreparing {
                        if let progress {
                            ProgressView("正在写入 \(progress.completed)/\(progress.total) 条", value: Double(progress.completed), total: Double(max(1, progress.total)))
                        } else { ProgressView("正在捕获一致的导出快照…") }
                        Button("取消导出", role: .cancel) { cancel() }
                    }
                    if let completion {
                        Label("导出完成：\(completion.lastPathComponent)", systemImage: "checkmark.circle")
                            .foregroundStyle(ReaderTheme.accent)
                            .textSelection(.enabled)
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped).navigationTitle("导出 Markdown")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { cancel(); dismiss() } } }
            .onChange(of: scope) { _, _ in invalidate() }
            .onChange(of: spaceID) { _, _ in invalidate() }
            .onChange(of: options) { _, _ in invalidate() }
            .onDisappear { cancel() }
            .fileImporter(isPresented: $showsDirectoryPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { export(to: url) }
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 500, idealWidth: 620, minHeight: 480, idealHeight: 720)
#endif
    }

    private var invalidScope: Bool { scope == .selected && model.selectedIDs.isEmpty || scope == .space && spaceID == nil }

    private func invalidate() { cancel(); snapshot = nil; completion = nil }

    private func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isPreparing = false
        progress = nil
    }

    private func prepare() {
        cancel()
        let token = generation
        let query = scope == .space ? NotesQuery(spaceID: spaceID) : model.query
        let selected = scope == .selected ? model.selectedIDs : nil
        let capturedOptions = options
        isPreparing = true
        errorMessage = nil
        completion = nil
        task = Task {
            do {
                let result = try await model.database.captureNotesExport(query: query, selectedIDs: selected, options: capturedOptions)
                try Task.checkCancellation()
                guard generation == token else { return }
                snapshot = result
            } catch is CancellationError {
            } catch { if generation == token { errorMessage = error.localizedDescription } }
            if generation == token { isPreparing = false; task = nil }
        }
    }

    private func export(to directory: URL) {
        guard let snapshot else { return }
        cancel()
        let token = generation
        isPreparing = true
        errorMessage = nil
        task = Task {
            let accessed = directory.startAccessingSecurityScopedResource()
            defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await NotesMarkdownExporter.write(snapshot, to: directory, progress: { value in
                        await MainActor.run { if generation == token { progress = value } }
                    })
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                // A successful atomic commit is reported even if cancellation
                // arrived immediately after the rename; never hide a written copy.
                if generation == token { completion = result }
            } catch is CancellationError {
                if generation == token { errorMessage = "已取消；未提交部分导出。" }
            } catch { if generation == token { errorMessage = "导出失败：\(error.localizedDescription)" } }
            if generation == token { isPreparing = false; task = nil; progress = nil }
        }
    }
}

private enum NotesExportScope: Hashable { case filtered, selected, space }
