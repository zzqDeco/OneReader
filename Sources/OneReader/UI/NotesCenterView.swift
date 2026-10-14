import SwiftUI
#if os(macOS)
import AppKit
#endif

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
    @State private var showsMoreFilters = false
    @State private var refreshPresentation = NotesRefreshPresentation()

    var body: some View {
        let requestedKey = refreshKey
        NavigationStack {
            VStack(spacing: 0) {
                filters
                Divider()
                if let error = currentLoadError ?? currentOperationError ?? actionError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .padding()
                }
                if resultsPhase == .results {
                    List {
                        ForEach(model.entries) { entry in
                            NotesEntryRow(entry: entry, isSelected: selection(entry.id), onOpen: { Task { await model.open(entry) } }, onEdit: { editing = entry }, onDelete: { pendingDeletion = NotesDeletion(entries: [entry]) })
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                        if model.nextCursor != nil {
                            Button("载入更多") { Task { await model.loadMore() } }
                                .disabled(model.isLoading)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("notes-load-more")
                        }
                    }
                    .listStyle(.plain)
                } else {
                    NotesResultsPlaceholder(phase: resultsPhase, onRetry: model.invalidate)
                }
                if isRebuilding || (model.isLoading && resultsPhase == .results) {
                    ProgressView(isRebuilding ? "正在重建笔记搜索…" : "正在载入更多笔记…").padding(8)
                }
                NotesCenterFooter(totalCount: currentTotalCount, selectedCount: model.selectedIDs.count,
                    isUpdating: isUpdatingResults, isUnavailable: resultsPhase == .failed,
                    onExport: { showsExport = true }, onDelete: {
                        pendingDeletion = NotesDeletion(entries: model.entries.filter { model.selectedIDs.contains($0.id) })
                    })
            }
            .background(ReaderTheme.grouped)
            .navigationTitle("笔记中心")
            .searchable(text: $model.query.search, prompt: "搜索摘录与用户笔记")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
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
                }
#if !os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button { showsExport = true } label: { Label("导出", systemImage: "square.and.arrow.up") }
                        .disabled(currentTotalCount == 0 || isUpdatingResults)
                        .accessibilityIdentifier("notes-export")
                }
#endif
            }
            .task(id: requestedKey) {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                await model.reload()
            }
            .onChange(of: model.lastReloadReceipt) { _, receipt in
                // Another mounted Notes sheet may own the same shared reload.
                // Only its matching, completed read may settle this sheet too.
                guard let receipt, receipt == model.lastReloadReceipt else { return }
                refreshPresentation.complete(NotesRefreshKey(query: receipt.query,
                    revision: receipt.revision), current: refreshKey,
                    cancelled: false, outcome: receipt.outcome)
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

    private var refreshKey: NotesRefreshKey {
        NotesRefreshKey(query: model.query, revision: model.revision)
    }

    private var currentLoadError: String? {
        refreshPresentation.loadError(current: refreshKey)
    }

    private var currentOperationError: String? {
        refreshPresentation.settledKey == refreshKey ? model.errorMessage : nil
    }

    private var currentTotalCount: Int {
        refreshPresentation.visibleTotalCount(current: refreshKey, totalCount: model.totalCount)
    }

    private var resultsPhase: NotesResultsPhase {
        refreshPresentation.phase(current: refreshKey, isLoading: model.isLoading,
            entryCount: model.entries.count)
    }

    private var isUpdatingResults: Bool {
        isRebuilding || refreshPresentation.isUpdating(current: refreshKey,
            isLoading: model.isLoading)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReaderAdaptiveActions {
                spacePicker
                kindPicker
            }
            DisclosureGroup(isExpanded: $showsMoreFilters) {
                VStack(alignment: .leading, spacing: 12) {
                    ReaderAdaptiveActions {
                        sourcePicker
                        sortPicker
                    }
                    ReaderAdaptiveActions {
                        tagMenu
                        dateMenu
                        Button("重置筛选") { model.query = NotesQuery() }
                    }
                    Text("多标签同时匹配；按创建时间与稳定 ID 排序，编辑不会让条目跳页。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            } label: {
                Label(extraFilterCount == 0 ? "更多筛选" : "更多筛选 · \(extraFilterCount) 项已启用",
                    systemImage: "line.3.horizontal.decrease")
                    .font(.callout)
            }
        }
        .pickerStyle(.menu)
        .buttonStyle(.borderless)
        .padding(16)
        .background(ReaderTheme.raised)
    }

    private var spacePicker: some View {
        Picker("空间", selection: $model.query.spaceID) {
            Text("全部空间").tag(nil as String?)
            ForEach(app.spaces) { Text($0.title).tag(Optional($0.id)) }
        }
    }

    private var sourcePicker: some View {
        Picker("来源", selection: $model.query.sourceID) {
            Text("全部来源").tag(nil as String?)
            ForEach(app.sources) { Text($0.displayName).tag(Optional($0.id)) }
        }
    }

    private var kindPicker: some View {
        Picker("类型", selection: $model.query.kind) {
            Text("全部类型").tag(nil as AnnotationKind?)
            ForEach(AnnotationKind.allCases, id: \.self) { Text($0.notesTitle).tag(Optional($0)) }
        }
    }

    private var sortPicker: some View {
        Picker("排序", selection: $model.query.sort) {
            ForEach(NotesSort.allCases) { Text($0.title).tag($0) }
        }
    }

    private var tagMenu: some View {
        Menu {
            if model.tags.isEmpty { Text("暂无标签") }
            ForEach(model.tags) { tag in
                Toggle(tag.name, isOn: Binding(get: { model.query.tagIDs.contains(tag.id) }, set: { selected in
                    if selected { model.query.tagIDs.insert(tag.id) } else { model.query.tagIDs.remove(tag.id) }
                }))
            }
        } label: {
            ReaderActionLabel(title: model.query.tagIDs.isEmpty ? "全部标签" : "同时包含 \(model.query.tagIDs.count) 个标签",
                systemImage: "tag")
        }
    }

    private var dateMenu: some View {
        Menu {
            Button("全部时间") { model.query.createdAfter = nil; model.query.createdBefore = nil }
            Button("最近 7 天") { model.query.createdAfter = Calendar.current.date(byAdding: .day, value: -7, to: .now); model.query.createdBefore = nil }
            Button("最近 30 天") { model.query.createdAfter = Calendar.current.date(byAdding: .day, value: -30, to: .now); model.query.createdBefore = nil }
            DatePicker("起始日期", selection: Binding(get: { model.query.createdAfter ?? .now }, set: { model.query.createdAfter = Calendar.current.startOfDay(for: $0) }), displayedComponents: .date)
            DatePicker("结束日期（含当天）", selection: Binding(get: { (model.query.createdBefore ?? .now).addingTimeInterval(-1) }, set: { model.query.createdBefore = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: $0)) }), displayedComponents: .date)
        } label: {
            ReaderActionLabel(title: model.query.createdAfter == nil && model.query.createdBefore == nil ? "全部时间" : "已筛选时间",
                systemImage: "calendar")
        }
    }

    private var extraFilterCount: Int {
        (model.query.sourceID == nil ? 0 : 1) + model.query.tagIDs.count
            + (model.query.createdAfter == nil && model.query.createdBefore == nil ? 0 : 1)
            + (model.query.sort == .newest ? 0 : 1)
    }

    private func selection(_ id: String) -> Binding<Bool> {
        Binding(get: { model.selectedIDs.contains(id) }, set: { selected in
            if selected { model.selectedIDs.insert(id) } else { model.selectedIDs.remove(id) }
        })
    }
}

/// Keep the macOS export action in the content hierarchy. A sheet toolbar can
/// compact or omit grouped items; that must not make the main workflow disappear.
struct NotesCenterFooter: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let totalCount: Int
    let selectedCount: Int
    var isUpdating = false
    var isUnavailable = false
    let onExport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
            layout {
                countLabel
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                actions
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(ReaderTheme.raised)
        .accessibilityElement(children: .contain)
    }

    private var countLabel: some View {
        Text(isUpdating ? "正在更新结果…" : isUnavailable ? "结果暂不可用"
            : "共 \(totalCount) 条 · 已选 \(selectedCount) 条")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        return layout {
#if os(macOS)
            NativeNotesExportButton(enabled: totalCount > 0 && !isUpdating && !isUnavailable, action: onExport)
                .disabled(totalCount == 0 || isUpdating || isUnavailable)
                .fixedSize()
#endif
            Button(role: .destructive, action: onDelete) {
                ReaderActionLabel(title: "删除所选", systemImage: "trash")
            }
                .buttonStyle(.borderless)
                .disabled(selectedCount == 0 || isUpdating || isUnavailable)
                .accessibilityIdentifier("notes-delete-selected")
        }
        .accessibilityElement(children: .contain)
    }
}

#if os(macOS)
/// A real AppKit action stays visible and accessible independently of sheet
/// toolbar compaction. Its keyboard equivalent belongs to this testable control.
private struct NativeNotesExportButton: NSViewRepresentable {
    let enabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action, enabled: enabled) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "导出 Markdown", target: context.coordinator, action: #selector(Coordinator.export))
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.keyEquivalent = "e"; button.keyEquivalentModifierMask = [.command, .shift]
        context.coordinator.enabled = enabled && context.environment.isEnabled
        button.isEnabled = context.coordinator.enabled
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("导出 Markdown")
        button.setAccessibilityIdentifier("notes-export")
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        context.coordinator.enabled = enabled && context.environment.isEnabled
        button.isEnabled = context.coordinator.enabled
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? { nsView.intrinsicContentSize }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        var enabled: Bool
        init(action: @escaping () -> Void, enabled: Bool) { self.action = action; self.enabled = enabled }
        @objc func export() { if enabled { action() } }
    }
}
#endif

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
                ReaderAdaptiveActions {
                    Label(entry.annotation.kind.notesTitle, systemImage: entry.annotation.kind.notesSymbol)
                        .font(.caption.weight(.semibold)).foregroundStyle(ReaderTheme.teal)
                    ReaderAnnotationStatusLabel(status: entry.presentationStatus)
                }
                Text(entry.preview).font(.body).lineLimit(5).textSelection(.enabled)
                if entry.annotation.selectedText != nil, let note = entry.annotation.note {
                    Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label(entry.sourceTitle, systemImage: "doc.text")
                    Text("\(entry.location) · \(entry.spaceTitle)")
                }
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !entry.tags.isEmpty {
                    Text(entry.tags.map { "#\($0.name)" }.joined(separator: "  "))
                        .font(.caption).foregroundStyle(ReaderTheme.teal).textSelection(.enabled)
                }
                NotesEntryActions(entryID: entry.id, onOpen: onOpen, onEdit: onEdit, onDelete: onDelete)
                Text(entry.annotation.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderTheme.raised, in: RoundedRectangle(cornerRadius: ReaderTheme.panelRadius))
        .overlay { RoundedRectangle(cornerRadius: ReaderTheme.panelRadius).stroke(.separator.opacity(0.4), lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes-entry-\(entry.id)")
    }
}

/// No combined row action: opening, editing and deletion stay separate controls.
struct NotesEntryActions: View {
    let entryID: String
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ReaderAdaptiveActions {
            Button(action: onOpen) {
                ReaderActionLabel(title: "回到原文", systemImage: "arrow.up.forward.app")
            }
            .accessibilityIdentifier("notes-open-\(entryID)")
            Button(action: onEdit) {
                ReaderActionLabel(title: "编辑", systemImage: "pencil")
            }
            .accessibilityIdentifier("notes-edit-\(entryID)")
            Menu {
                Button("删除标注…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: ReaderChromeMetrics.actionHeight, minHeight: ReaderChromeMetrics.actionHeight)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("更多标注操作")
            .accessibilityIdentifier("notes-more-\(entryID)")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

private struct NotesSelectionToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(configuration.isOn ? ReaderTheme.teal : .secondary)
                .frame(minWidth: ReaderChromeMetrics.actionHeight, minHeight: ReaderChromeMetrics.actionHeight)
                .contentShape(Rectangle())
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
                    ReaderAnnotationStatusLabel(status: entry.presentationStatus)
                    if let text = entry.annotation.selectedText { Text(text).textSelection(.enabled) }
                    Button("回到原快照") { Task { await model.open(entry) } }
                    DisclosureGroup("定位详情") {
                        LabeledContent("定位状态", value: entry.annotation.anchorState.rawValue)
                        Text("快照：\(entry.annotation.snapshotID)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Text("适配器：\(entry.annotation.locator.adapterID)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Text(entry.annotation.locator.conciseDescription)
                            .font(.caption).textSelection(.enabled)
                    }
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
