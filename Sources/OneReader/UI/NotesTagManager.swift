import SwiftUI

struct NotesTagManager: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: NotesCenterModel
    @State private var newName = ""
    @State private var names: [String: String] = [:]
    @State private var errorMessage: String?
    @State private var pendingDelete: AnnotationTag?
    @State private var pendingMerge: TagMerge?

    var body: some View {
        NavigationStack {
            Form {
                Section("创建标签") {
                    HStack {
                        TextField("标签名称", text: $newName)
                        Button("创建") {
                            Task {
                                do {
                                    _ = try await model.database.createNotesTag(name: newName)
                                    newName = ""
                                    try await refresh()
                                } catch { errorMessage = error.localizedDescription }
                            }
                        }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("去除首尾空白并合并连续空白；不区分大小写及全半角。同名创建复用原标签，不复制标注。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("现有标签") {
                    ForEach(model.tags) { tag in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("标签名称", text: Binding(get: { names[tag.id] ?? tag.name }, set: { names[tag.id] = $0 }))
                            HStack {
                                Text("\(tag.annotationCount) 条标注").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("重命名") { rename(tag) }
                                Button("删除…", role: .destructive) { pendingDelete = tag }
                            }
                        }
                    }
                    if model.tags.isEmpty { Text("暂无标签").foregroundStyle(.secondary) }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped).navigationTitle("管理标签")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { do { try await model.refreshTags() } catch { errorMessage = error.localizedDescription } }
            .alert(item: $pendingDelete) { tag in
                Alert(title: Text("删除标签“\(tag.name)”？"), message: Text("将移除 \(tag.annotationCount) 条标注上的此标签关系。标注、摘录、用户笔记和来源不会删除。"), primaryButton: .destructive(Text("仅删除标签")) {
                    Task {
                        do { try await model.database.deleteNotesTag(id: tag.id); try await refresh() }
                        catch { errorMessage = error.localizedDescription }
                    }
                }, secondaryButton: .cancel(Text("取消")))
            }
            .confirmationDialog("合并同名标签？", isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }), presenting: pendingMerge) { merge in
                Button("确认合并到“\(merge.target.name)”") {
                    Task {
                        do {
                            try await model.database.renameNotesTag(id: merge.source.id, name: merge.name, confirmedMergeTargetID: merge.target.id)
                            try await refresh()
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: { merge in
                Text("“\(merge.source.name)”的 \(merge.source.annotationCount) 条标签关系将转移到“\(merge.target.name)”并去重；不会合并或删除任何标注。")
            }
        }
#if os(macOS)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 400, idealHeight: 640)
#endif
    }

    private func refresh() async throws {
        try await model.refreshTags()
        model.invalidate()
    }

    private func rename(_ tag: AnnotationTag) {
        let name = names[tag.id] ?? tag.name
        do {
            let normalized = try AnnotationTag.normalized(name)
            if let target = model.tags.first(where: { $0.id != tag.id && $0.normalizedName == normalized.key }) {
                pendingMerge = TagMerge(source: tag, target: target, name: normalized.name)
                return
            }
        } catch { errorMessage = error.localizedDescription; return }
        Task {
            do { try await model.database.renameNotesTag(id: tag.id, name: name); try await refresh() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct TagMerge {
    let source: AnnotationTag
    let target: AnnotationTag
    let name: String
}
