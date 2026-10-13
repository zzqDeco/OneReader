import SwiftUI

struct NotesCenterView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: NotesCenterModel
    @State private var editing: NotesEntry?
    @State private var pendingDeletion: NotesDeletion?
    @State private var showsTags = false
    @State private var showsExport = false
    @State private var actionError: String?
    @State private var isRebuilding = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filters
                Divider()
                if let error = model.errorMessage ?? actionError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .padding()
                }
                if model.entries.isEmpty, !model.isLoading {
                    ContentUnavailableView("没有匹配的标注", systemImage: "note.text", description: Text("搜索仅包含摘录与用户笔记，不会搜索或外发来源正文。"))
                } else {
                    List {
                        ForEach(model.entries) { entry in
                            NotesEntryRow(entry: entry, isSelected: selection(entry.id), onOpen: { Task { await model.open(entry) } }, onEdit: { editing = entry }, onDelete: { pendingDeletion = NotesDeletion(entries: [entry]) })
                        }
                        if model.nextCursor != nil {
                            Button("载入更多") { Task { await model.loadMore() } }
                                .disabled(model.isLoading)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("notes-load-more")
                        }
                    }
                    .listStyle(.plain)
                }
                if model.isLoading || isRebuilding { ProgressView(isRebuilding ? "正在重建笔记搜索…" : "正在载入笔记…").padding(8) }
                HStack {
                    Text("共 \(model.totalCount) 条 · 已选 \(model.selectedIDs.count) 条")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("删除所选", role: .destructive) {
                        pendingDeletion = NotesDeletion(entries: model.entries.filter { model.selectedIDs.contains($0.id) })
                    }.disabled(model.selectedIDs.isEmpty)
                }.padding(12)
            }
            .background(ReaderTheme.grouped)
            .navigationTitle("笔记中心")
            .searchable(text: $model.query.search, prompt: "搜索摘录与用户笔记")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("管理标签", systemImage: "tag") { showsTags = true }
                        Button("重建笔记搜索索引", systemImage: "arrow.clockwise") {
                            isRebuilding = true
                            Task {
                                do { try await model.database.rebuildNotesSearch(); model.invalidate() }
                                catch { actionError = error.localizedDescription }
                                isRebuilding = false
                            }
                        }.disabled(isRebuilding)
                    } label: { Label("笔记选项", systemImage: "tag") }
                    Button { showsExport = true } label: { Label("导出", systemImage: "square.and.arrow.up") }
                        .disabled(model.totalCount == 0)
                }
            }
            .task(id: NotesRefreshKey(query: model.query, revision: model.revision)) {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                await model.reload()
            }
            .onDisappear { model.cancelOpening() }
            .sheet(item: $editing) { entry in NotesAnnotationEditor(entry: entry, model: model) }
            .sheet(isPresented: $showsTags) { NotesTagManager(model: model) }
            .sheet(isPresented: $showsExport) {
                NotesExportView(model: model, spaces: app.spaces)
            }
            .alert(item: $pendingDeletion) { request in
                Alert(title: Text("删除 \(request.entries.count) 条原始标注？"), message: Text(request.summary + "\n此操作直接删除资料库中的标注及标签关系，不删除来源文件。"), primaryButton: .destructive(Text("确认删除")) {
                    Task {
                        do { try await model.delete(request.entries) } catch { actionError = error.localizedDescription }
                    }
                }, secondaryButton: .cancel(Text("取消")))
            }
        }
#if os(macOS)
        .frame(minWidth: 660, idealWidth: 900, minHeight: 500, idealHeight: 720)
#endif
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { scopePickers }
                VStack(alignment: .leading) { scopePickers }
            }
            HStack {
                Menu {
                    if model.tags.isEmpty { Text("暂无标签") }
                    ForEach(model.tags) { tag in
                        Toggle(tag.name, isOn: Binding(get: { model.query.tagIDs.contains(tag.id) }, set: { selected in
                            if selected { model.query.tagIDs.insert(tag.id) } else { model.query.tagIDs.remove(tag.id) }
                        }))
                    }
                } label: {
                    Label(model.query.tagIDs.isEmpty ? "全部标签" : "同时包含 \(model.query.tagIDs.count) 个标签", systemImage: "tag")
                }
                Menu {
                    Button("全部时间") { model.query.createdAfter = nil; model.query.createdBefore = nil }
                    Button("最近 7 天") { model.query.createdAfter = Calendar.current.date(byAdding: .day, value: -7, to: .now); model.query.createdBefore = nil }
                    Button("最近 30 天") { model.query.createdAfter = Calendar.current.date(byAdding: .day, value: -30, to: .now); model.query.createdBefore = nil }
                    DatePicker("起始日期", selection: Binding(get: { model.query.createdAfter ?? .now }, set: { model.query.createdAfter = Calendar.current.startOfDay(for: $0) }), displayedComponents: .date)
                    DatePicker("结束日期（含当天）", selection: Binding(get: { (model.query.createdBefore ?? .now).addingTimeInterval(-1) }, set: { model.query.createdBefore = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: $0)) }), displayedComponents: .date)
                } label: {
                    Label(model.query.createdAfter == nil && model.query.createdBefore == nil ? "全部时间" : "已筛选时间", systemImage: "calendar")
                }
                Spacer()
                Button("重置") { model.query = NotesQuery() }
            }
            Text("多标签采用“同时包含”；按创建时间与稳定 ID 排序，编辑不会让条目跳页。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12)
    }

    @ViewBuilder private var scopePickers: some View {
        Picker("空间", selection: $model.query.spaceID) {
            Text("全部空间").tag(nil as String?)
            ForEach(app.spaces) { Text($0.title).tag(Optional($0.id)) }
        }
        Picker("来源", selection: $model.query.sourceID) {
            Text("全部来源").tag(nil as String?)
            ForEach(app.sources) { Text($0.displayName).tag(Optional($0.id)) }
        }
        Picker("类型", selection: $model.query.kind) {
            Text("全部类型").tag(nil as AnnotationKind?)
            ForEach(AnnotationKind.allCases, id: \.self) { Text($0.notesTitle).tag(Optional($0)) }
        }
        Picker("排序", selection: $model.query.sort) {
            ForEach(NotesSort.allCases) { Text($0.title).tag($0) }
        }
    }

    private func selection(_ id: String) -> Binding<Bool> {
        Binding(get: { model.selectedIDs.contains(id) }, set: { selected in
            if selected { model.selectedIDs.insert(id) } else { model.selectedIDs.remove(id) }
        })
    }
}

private struct NotesRefreshKey: Equatable { let query: NotesQuery; let revision: UUID }
private struct NotesDeletion: Identifiable {
    let id = UUID()
    let entries: [NotesEntry]
    var summary: String { entries.prefix(3).map { "\($0.sourceTitle) · \($0.location)" }.joined(separator: "\n") }
}

private struct NotesEntryRow: View {
    let entry: NotesEntry
    @Binding var isSelected: Bool
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("选择这条\(entry.annotation.kind.notesTitle)", isOn: $isSelected)
                .labelsHidden().toggleStyle(.checkboxIfAvailable)
                .accessibilityLabel("选择 \(entry.sourceTitle) 的\(entry.annotation.kind.notesTitle)")
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Label(entry.annotation.kind.notesTitle, systemImage: entry.annotation.kind.notesSymbol)
                        .font(.caption.weight(.semibold)).foregroundStyle(ReaderTheme.teal)
                    Spacer()
                    Text(entry.statusLabel).font(.caption).foregroundStyle(.secondary)
                }
                Text(entry.preview).font(.body).lineLimit(5).textSelection(.enabled)
                if entry.annotation.selectedText != nil, let note = entry.annotation.note {
                    Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
                Text("\(entry.sourceTitle) · \(entry.location) · \(entry.spaceTitle)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !entry.tags.isEmpty {
                    Text(entry.tags.map { "#\($0.name)" }.joined(separator: "  "))
                        .font(.caption).foregroundStyle(ReaderTheme.teal).textSelection(.enabled)
                }
                HStack {
                    Button("回到原文", systemImage: "arrow.up.forward.app", action: onOpen)
                    Button("编辑", systemImage: "pencil", action: onEdit)
                    Spacer()
                    Text(entry.annotation.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                    Menu { Button("删除标注…", role: .destructive, action: onDelete) } label: {
                        Label("更多操作", systemImage: "ellipsis")
                    }.menuStyle(.borderlessButton).fixedSize()
                }.font(.caption)
            }
        }.padding(.vertical, 6)
    }
}

private struct NotesSelectionToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(configuration.isOn ? ReaderTheme.teal : .secondary)
        }.buttonStyle(.plain).accessibilityLabel("选择标注")
            .accessibilityValue(configuration.isOn ? "已选择" : "未选择")
    }
}
private extension ToggleStyle where Self == NotesSelectionToggleStyle {
    static var checkboxIfAvailable: Self { NotesSelectionToggleStyle() }
}

struct NotesAnnotationEditor: View {
    @Environment(\.dismiss) private var dismiss
    let entry: NotesEntry
    @ObservedObject var model: NotesCenterModel
    @State private var note: String
    @State private var tagIDs: Set<String>
    @State private var newTag = ""
    @State private var error: String?
    @State private var isSaving = false

    init(entry: NotesEntry, model: NotesCenterModel) {
        self.entry = entry
        self.model = model
        _note = State(initialValue: entry.annotation.note ?? "")
        _tagIDs = State(initialValue: Set(entry.tags.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("原文与位置") {
                    Text(entry.sourceTitle).textSelection(.enabled)
                    Text(entry.location).font(.caption).textSelection(.enabled)
                    Text(entry.statusLabel).font(.caption).foregroundStyle(.secondary)
                    if let text = entry.annotation.selectedText { Text(text).textSelection(.enabled) }
                    Button("回到原快照") { Task { await model.open(entry) } }
                }
                Section("用户笔记") {
                    TextEditor(text: $note).frame(minHeight: 130).accessibilityLabel("编辑用户笔记")
                }
                Section("标签") {
                    ForEach(model.tags) { tag in
                        Toggle(tag.name, isOn: Binding(get: { tagIDs.contains(tag.id) }, set: {
                            if $0 { tagIDs.insert(tag.id) } else { tagIDs.remove(tag.id) }
                        }))
                    }
                    HStack {
                        TextField("新标签", text: $newTag)
                        Button("添加") {
                            Task {
                                do {
                                    let id = try await model.database.createNotesTag(name: newTag)
                                    try await model.refreshTags()
                                    tagIDs.insert(id)
                                    newTag = ""
                                } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let message = error ?? model.errorMessage { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped)
                .navigationTitle("编辑\(entry.annotation.kind.notesTitle)")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(isSaving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            isSaving = true
                            Task {
                                do { try await model.save(entry, note: note, tagIDs: tagIDs); dismiss() }
                                catch { self.error = error.localizedDescription }
                                isSaving = false
                            }
                        }.disabled(isSaving).keyboardShortcut("s", modifiers: .command)
                    }
                }
                .task { do { try await model.refreshTags() } catch { self.error = error.localizedDescription } }
                .onChange(of: model.tags) { _, tags in tagIDs.formIntersection(Set(tags.map(\.id))) }
        }
#if os(macOS)
        .frame(minWidth: 480, idealWidth: 580, minHeight: 480, idealHeight: 680)
#endif
    }
}
