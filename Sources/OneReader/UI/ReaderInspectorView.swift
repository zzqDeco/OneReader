import SwiftUI

struct ReaderInspectorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var noteDraft = ""
    @State private var question = ""
    @State private var notesEditing: NotesEntry?
    @State private var pendingNoteDeletion: Annotation?

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider()
            inspectorContent
        }
        .background(ReaderTheme.window)
        .sheet(item: $notesEditing) { entry in
            if let notes = model.notesCenter { NotesAnnotationEditor(entry: entry, model: notes) }
        }
        .alert(item: $pendingNoteDeletion) { annotation in
            Alert(title: Text("删除这条\(annotation.kind.notesTitle)？"),
                  message: Text("将删除原始标注及其标签关系。来源文件不会删除。"),
                  primaryButton: .destructive(Text("确认删除")) {
                    Task {
                        do {
                            if var entry = try await model.notesEntry(for: annotation) {
                                entry.annotation = annotation
                                try await model.notesCenter?.delete([entry])
                            }
                        } catch { model.notice = AppNotice(title: "无法删除标注", message: error.localizedDescription) }
                    }
                  }, secondaryButton: .cancel(Text("取消")))
        }
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("阅读辅助")
                    .font(.headline)
                Spacer()
                Button {
                    model.isInspectorPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭阅读辅助")
            }
            Picker("阅读辅助视图", selection: $model.inspectorTab) {
                ForEach(model.availableInspectorTabs) { tab in
                    Image(systemName: tab.systemImage)
                        .tag(tab)
                        .help(tab.title)
                        .accessibilityLabel(tab.title)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(14)
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch model.inspectorTab {
        case .annotations: annotationsView
        case .evidence: evidenceView
        case .activity: activityView
        case .ask: askView
        case .translation:
            if model.isBilingualReadingAvailable {
                BilingualReadingView(controller: model.bilingualReading)
            } else {
                ContentUnavailableView("双语阅读暂未开放", systemImage: "character.bubble")
            }
        }
    }

    private var annotationsView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                if let selection = model.currentSelection {
                    Text("“\(selection.text)”")
                        .font(.callout)
                        .lineLimit(3)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ReaderTheme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                TextEditor(text: $noteDraft)
                    .font(.body)
                    .frame(minHeight: 72, maxHeight: 110)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.separator)
                    }
                    .accessibilityLabel("新笔记正文")
                HStack {
                    Button("添加书签") { model.addBookmark() }
                        .disabled(model.presentationDocument == nil)
                    Button("高亮") { model.addHighlight() }
                        .disabled(!model.canCreateHighlight)
                    Spacer()
                    Button("保存笔记") {
                        model.addNote(noteDraft)
                        noteDraft = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
            Divider()

            Button("打开全局笔记中心", action: model.openNotesCenter)
                .font(.caption).padding(.vertical, 8)

            if model.annotations.isEmpty {
                ContentUnavailableView(
                    "还没有标注",
                    systemImage: "highlighter",
                    description: Text("书签、带原文位置的高亮和笔记会保存在阅读空间中。")
                )
            } else {
                List(model.annotations) { annotation in
                    Button {
                        Task {
                            do {
                                if let entry = try await model.notesEntry(for: annotation) {
                                    await model.notesCenter?.open(entry)
                                }
                            } catch { model.notice = AppNotice(title: "无法打开标注", message: error.localizedDescription) }
                        }
                    } label: {
                        AnnotationRow(annotation: annotation)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("编辑笔记与标签", systemImage: "pencil") {
                            Task {
                                do { notesEditing = try await model.notesEntry(for: annotation) }
                                catch { model.notice = AppNotice(title: "无法读取标注", message: error.localizedDescription) }
                            }
                        }
                        Button("删除", role: .destructive) {
                            pendingNoteDeletion = annotation
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var evidenceView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let observation = model.currentObservation {
                    InspectorSection(title: "当前位置", systemImage: "doc.text.magnifyingglass") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(observation.locator.conciseDescription)
                                .font(.subheadline.weight(.medium))
                            if observation.truncated {
                                Label("引用只显示了节选，完整内容仍保留在来源中", systemImage: "scissors")
                            }
                            DisclosureGroup("引用详情") {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("版本 \(String(observation.snapshotID.prefix(9)))")
                                    Text("内容指纹 \(String(observation.contentDigest.prefix(12)))")
                                    Text(observation.mediaType)
                                }
                                .padding(.top, 4)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let graph = model.currentGraph {
                    InspectorSection(title: "阅读脉络", systemImage: "point.3.filled.connected.trianglepath.dotted") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(graph.units.count) 个有原文依据的阅读单元")
                            ForEach(graph.units.prefix(8)) { unit in
                                Button {
                                    model.selectReadingUnit(unit.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(unit.title)
                                            .foregroundStyle(.primary)
                                        Text("\(unit.fragments.count) 条证据 · \(Int(unit.confidence * 100))%")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "尚未生成阅读脉络",
                        systemImage: "link",
                        description: Text("现有目录仍可使用；智能整理的每条结论都必须回到原文。")
                    )
                    .frame(minHeight: 250)
                }
            }
            .padding(13)
        }
    }

    private var activityView: some View {
        VStack(spacing: 0) {
            if model.waitingAgentRun != nil {
                VStack(alignment: .leading, spacing: 9) {
                    Label(
                        attentionTitle,
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.headline)
                    Text(attentionDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        if model.waitingAgentAttentionKind == .adapterCandidate {
                            Button("保留基础方案") { model.dismissWaitingAgentRun() }
                        }
                        if model.waitingAgentAttentionKind == .interrupted {
                            Button("放弃任务") { model.abandonInterruptedAgentRun() }
                        }
                        Spacer()
                        Button(
                            model.waitingAgentAttentionKind == .interrupted
                                ? "恢复任务"
                                : "确认并继续"
                        ) { model.confirmWaitingAgentRun() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                .background(ReaderTheme.orange.opacity(0.1))
                Divider()
            }

            if model.activity.isEmpty {
                ContentUnavailableView(
                    "还没有运行活动",
                    systemImage: "waveform.path",
                    description: Text("这里记录来源整理、索引、引用验证和阅读路线的执行结果。")
                )
            } else {
                List(model.activity) { item in
                    ActivityRow(item: item)
                }
                .listStyle(.inset)
            }

            Divider()
            if model.spaceSupportsAgentEvidence {
                HStack {
                    Button("生成阅读结构") { model.launchAgentPipeline() }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("取消") { model.cancelAgentRun() }
                        .disabled(!model.agentRuns.contains {
                            $0.state == .running || $0.state == .queued
                        })
                }
                .padding(12)
            } else {
                Label(
                    "系统预览只提供来源级书签和笔记，不支持正文引用或智能问答",
                    systemImage: "eye"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
            }
        }
    }

    private var attentionTitle: String {
        switch model.waitingAgentAttentionKind {
        case .disclosure: "需要确认数据外发"
        case .adapterCandidate: "需要确认适配器候选"
        case .interrupted: "整理任务已中断"
        case nil: "整理任务需要处理"
        }
    }

    private var attentionDescription: String {
        switch model.waitingAgentAttentionKind {
        case .disclosure:
            "远程模型将读取运行详情中列出的原文片段；确认后才会继续。"
        case .adapterCandidate:
            "候选置信度未达到自动采用阈值，基础适配器会继续工作。"
        case .interrupted:
            "应用重启或任务中断后不会自动重放网络操作；请确认是否恢复。"
        case nil:
            "请查看运行详情后决定是否继续。"
        }
    }

    private var askView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let currentQA = model.currentEvidenceQA {
                        EvidenceQACard(
                            qa: currentQA,
                            onOpenCitation: { model.openEvidenceCitation($0) },
                            onSaveAsNote: { model.saveEvidenceQAAsNote(currentQA, citationIndex: $0) }
                        )

                        let previousItems = model.evidenceQAHistory.filter { $0.id != currentQA.id }
                        if !previousItems.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 10) {
                                Label("历史问答记录", systemImage: "clock.arrow.circlepath")
                                    .font(.headline)
                                ForEach(previousItems) { item in
                                    EvidenceQACard(
                                        qa: item,
                                        onOpenCitation: { model.openEvidenceCitation($0) },
                                        onSaveAsNote: { model.saveEvidenceQAAsNote(item, citationIndex: $0) }
                                    )
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "带证据问答",
                            systemImage: "sparkles",
                            description: Text("回答只会引用当前版本中已经验证、可以跳转的原文。")
                        )
                        .frame(minHeight: 300)
                    }
                }
                .padding(13)
            }
            Divider()
            VStack(spacing: 9) {
                TextEditor(text: $question)
                    .frame(minHeight: 58, maxHeight: 100)
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
                    .accessibilityLabel("向阅读助手提问")
                HStack {
                    Text(model.activeProvider?.displayName ?? "未配置模型")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("提问") {
                        model.askAgent(question)
                        question = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
        }
    }
}

private struct EvidenceQACard: View {
    let qa: CompletedEvidenceQA
    let onOpenCitation: (Locator) -> Void
    let onSaveAsNote: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(qa.question)
                        .font(.subheadline.weight(.semibold))
                    Text(qa.createdAt, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Button("存为笔记") {
                    onSaveAsNote(0)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(qa.answer.citations.isEmpty)
            }

            Text(qa.answer.answer)
                .font(.callout)
                .textSelection(.enabled)

            if !qa.answer.citations.isEmpty {
                Divider()
                Text("证据")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(qa.answer.citations.enumerated()), id: \.element.id) { index, citation in
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            onOpenCitation(citation.locator)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("“\(citation.quote)”")
                                    .foregroundStyle(.primary)
                                    .lineLimit(4)
                                Text(citation.locator.conciseDescription)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        if qa.answer.citations.count > 1 {
                            HStack {
                                Spacer()
                                Button("按此引证存为笔记") {
                                    onSaveAsNote(index)
                                }
                                .buttonStyle(.plain)
                                .font(.caption2)
                                .foregroundStyle(ReaderTheme.teal)
                            }
                        }
                    }
                    .padding(9)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                }
            }

            ForEach(qa.answer.limitations, id: \.self) { limitation in
                Label(limitation, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct AnnotationRow: View {
    let annotation: Annotation

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(3)
                if let note = annotation.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                HStack {
                    Text(annotation.locator.conciseDescription)
                    Spacer()
                    if let badge = annotation.anchorState.localizedBadgeTitle {
                        Text(badge)
                            .foregroundStyle(annotation.anchorState == .orphaned ? ReaderTheme.orange : .secondary)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        annotation.selectedText ?? annotation.note ?? kindTitle
    }

    private var kindTitle: String {
        switch annotation.kind {
        case .bookmark: "书签"
        case .highlight: "高亮"
        case .note: "笔记"
        }
    }

    private var symbol: String {
        switch annotation.kind {
        case .bookmark: "bookmark.fill"
        case .highlight: "highlighter"
        case .note: "note.text"
        }
    }

    private var color: Color {
        annotation.kind == .highlight ? ReaderTheme.orange : ReaderTheme.teal
    }
}

private struct ActivityRow: View {
    let item: ReaderActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.phase)
                    .font(.subheadline.weight(.medium))
                Text(item.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !auditSummary.isEmpty {
                    DisclosureGroup("运行详情") {
                        Text(auditSummary)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .padding(.top, 3)
                    }
                    .font(.caption2)
                }
                Text(item.date, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var auditSummary: String {
        let labels: [(String, String)] = [
            ("sourceID", "来源"),
            ("snapshotID", "版本"),
            ("adapterID", "阅读方式"),
            ("locatorDigest", "位置"),
            ("sentByteRange", "字节范围"),
        ]
        return labels.compactMap { key, label in
            guard let value = item.metadata[key], !value.isEmpty else { return nil }
            let displayed = key == "locatorDigest" ? String(value.prefix(12)) : value
            return "\(label): \(displayed)"
        }.joined(separator: "  ·  ")
    }

    private var symbol: String {
        switch item.state {
        case .pending: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle"
        case .failed: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch item.state {
        case .pending, .running: ReaderTheme.orange
        case .completed: ReaderTheme.teal
        case .attention: .yellow
        case .failed: .red
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
    }
}
