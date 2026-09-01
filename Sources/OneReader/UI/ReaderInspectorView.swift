import SwiftUI

struct ReaderInspectorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var noteDraft = ""
    @State private var question = ""

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider()
            inspectorContent
        }
        .background(.ultraThinMaterial)
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Inspector")
                    .font(.headline)
                Spacer()
                Button {
                    model.isInspectorPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭 Inspector")
            }
            Picker("Inspector 视图", selection: $model.inspectorTab) {
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

            if model.annotations.isEmpty {
                ContentUnavailableView(
                    "还没有标注",
                    systemImage: "highlighter",
                    description: Text("书签、带锚点高亮和笔记会保存在 Reading Space 中。")
                )
            } else {
                List(model.annotations) { annotation in
                    Button {
                        model.openLocator(annotation.locator)
                    } label: {
                        AnnotationRow(annotation: annotation)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("删除", role: .destructive) {
                            model.deleteAnnotation(annotation)
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
                    InspectorSection(title: "当前观察", systemImage: "doc.text.magnifyingglass") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(observation.locator.conciseDescription)
                                .font(.subheadline.weight(.medium))
                            Text("Snapshot \(String(observation.snapshotID.prefix(9)))")
                            Text("Digest \(String(observation.contentDigest.prefix(12)))")
                            Text(observation.mediaType)
                            if observation.truncated {
                                Label("当前观察已截断；完整内容仍保留在来源中", systemImage: "scissors")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let graph = model.currentGraph {
                    InspectorSection(title: "Reading Graph", systemImage: "point.3.filled.connected.trianglepath.dotted") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(graph.units.count) 个带证据阅读单元")
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
                        "尚未生成 Reading Graph",
                        systemImage: "link",
                        description: Text("确定性目录仍可使用；AI 结论必须引用真实 Fragment。")
                    )
                    .frame(minHeight: 250)
                }
            }
            .padding(13)
        }
    }

    private var activityView: some View {
        VStack(spacing: 0) {
            if let waiting = model.waitingAgentRun {
                VStack(alignment: .leading, spacing: 9) {
                    Label(
                        waiting.errorCategory == "disclosure-required"
                            ? "需要确认数据外发"
                            : "需要确认适配器候选",
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.headline)
                    Text(waiting.errorCategory == "disclosure-required"
                         ? "远程 Provider 将读取 Activity 中列出的 Source Fragment；确认后才会继续。"
                         : "候选置信度未达到自动采用阈值，基础适配器会继续工作。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("保留基础方案") { model.dismissWaitingAgentRun() }
                            .disabled(waiting.errorCategory == "disclosure-required")
                        Spacer()
                        Button("确认并继续") { model.confirmWaitingAgentRun() }
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
                    description: Text("这里只显示探测、工具、验证和提交事件，不显示隐藏思维过程。")
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
                    "Quick Look 兜底不提供正文搜索、结构化引用或 AI 问答",
                    systemImage: "eye"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
            }
        }
    }

    private var askView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let answer = model.evidenceAnswer {
                        Text(answer.answer)
                            .textSelection(.enabled)
                        if !answer.citations.isEmpty {
                            Divider()
                            Text("证据")
                                .font(.headline)
                            ForEach(answer.citations) { citation in
                                Button {
                                    model.openLocator(citation.locator)
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
                                    .padding(9)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        ForEach(answer.limitations, id: \.self) { limitation in
                            Label(limitation, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ContentUnavailableView(
                            "带证据问答",
                            systemImage: "sparkles",
                            description: Text("回答只能引用当前 Snapshot 中已验证、可跳转的证据。")
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
                    .accessibilityLabel("向 Reading Agent 提问")
                HStack {
                    Text(model.activeProvider?.displayName ?? "未配置 Provider")
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
                    Text(annotation.anchorState.rawValue)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        annotation.selectedText ?? annotation.note ?? annotation.kind.rawValue
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
                    Text(auditSummary)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(4)
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
            ("sourceID", "Source"),
            ("snapshotID", "Snapshot"),
            ("adapterID", "Adapter"),
            ("locatorDigest", "Locator"),
            ("sentByteRange", "Bytes"),
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
