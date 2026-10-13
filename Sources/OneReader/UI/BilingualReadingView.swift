import SwiftUI

struct BilingualReadingView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: BilingualReadingModel
    @State private var annotationCandidate: TranslationSegment?
    @State private var isUserScrolling = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if controller.rows.isEmpty {
                            ContentUnavailableView("双语对照", systemImage: "character.bubble",
                                description: Text("加载选区或当前章节；不会自动翻译整本书。扫描件需先完成 OCR。"))
                        }
                        ForEach(controller.rows) { row in
                            segmentRow(row)
                                .id(row.id)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: BilingualPositionKey.self,
                                        value: [row.id: geometry.frame(in: .named("bilingual-scroll")).minY])
                                })
                        }
                    }
                    .padding(14)
                }
                .coordinateSpace(name: "bilingual-scroll")
                .onScrollPhaseChange { _, phase in
                    isUserScrolling = phase == .interacting || phase == .decelerating
                }
                .onPreferenceChange(BilingualPositionKey.self) { positions in
                    guard isUserScrolling,
                          let id = positions.min(by: { abs($0.value) < abs($1.value) })?.key,
                          let row = controller.rows.first(where: { $0.id == id }) else { return }
                    // Only real user scrolling saves a source anchor, never a translated offset.
                    model.updateBilingualReadingPosition(row.segment.locator)
                }
                .onChange(of: controller.rows.map(\.id)) { _, _ in
                    guard let locator = model.currentPositionLocator,
                          let row = controller.rows.first(where: { matches($0.segment.locator, locator) }) else { return }
                    proxy.scrollTo(row.id, anchor: .top)
                }
                .onChange(of: model.currentPositionLocator?.stableID) { _, _ in
                    guard controller.followsSource, !isUserScrolling,
                          let locator = model.currentPositionLocator,
                          let row = controller.rows.first(where: { matches($0.segment.locator, locator) }) else { return }
                    proxy.scrollTo(row.id, anchor: .top)
                }
            }
            Divider()
            footer
        }
        .background(ReaderTheme.paper)
        .alert("先定位并确认原文", isPresented: Binding(
            get: { annotationCandidate != nil }, set: { if !$0 { annotationCandidate = nil } }
        )) {
            Button("定位原文并打开标注") {
                if let segment = annotationCandidate { model.returnToBilingualOriginal(segment, prepareAnnotation: true) }
                annotationCandidate = nil
            }
            Button("取消", role: .cancel) { annotationCandidate = nil }
        } message: {
            Text("标注只能绑定原文。确认后请检查原文选区，再选择高亮或保存笔记；译文偏移不会被写入原文位置。")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("当前章节 / 页") { model.prepareBilingualReading(useSelection: false) }
                    .disabled(model.presentationDocument == nil || controller.isBusy)
                Button("选中片段") { model.prepareBilingualReading(useSelection: true) }
                    .disabled(model.currentSelection == nil || controller.isBusy)
            }
            ViewThatFits(in: .horizontal) {
                HStack { sourcePicker; targetPicker }
                VStack(alignment: .leading) { sourcePicker; targetPicker }
            }
            if let suggestion = controller.sourceLanguageSuggestion {
                Text(suggestion).font(.caption2).foregroundStyle(.secondary)
            }
            Picker("对照显示方式", selection: $controller.layout) {
                ForEach(BilingualLayout.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("跟随原文位置（不自动生成）", isOn: $controller.followsSource)
                .font(.caption)
        }
        .controlSize(.small)
        .padding(12)
    }

    private var sourcePicker: some View {
        Picker("原文", selection: $controller.sourceLanguage) {
            ForEach(TranslationLanguage.allCases) { Text($0.title).tag($0) }
        }
    }

    private var targetPicker: some View {
        Picker("译为", selection: $controller.targetLanguage) {
            ForEach(TranslationLanguage.allCases.filter { $0 != .automatic }) { Text($0.title).tag($0) }
        }
    }

    private func segmentRow(_ row: BilingualRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("第 \(row.segment.order + 1) 段 · \(row.state.title)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button { model.returnToBilingualOriginal(row.segment) } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回第 \(row.segment.order + 1) 段原文")
            }
            if controller.layout != .translation {
                Text(row.segment.originalText)
                    .font(.system(size: model.preferences.fontSize))
                    .textSelection(.enabled)
            }
            if controller.layout != .original {
                if controller.layout == .interleaved { Divider() }
                if row.segment.isVerbatim {
                    if controller.layout == .translation { Text(row.segment.originalText).textSelection(.enabled) }
                } else if let cached = row.cached {
                    Text(cached.translatedText)
                        .font(.system(size: model.preferences.fontSize))
                        .textSelection(.enabled)
                    Text("机器生成 · \(cached.settings.providerName) / \(cached.settings.modelID) · \(cached.generatedAt.formatted(date: .abbreviated, time: .shortened)) · v\(cached.promptVersion)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("在对应原文上标注…") { annotationCandidate = row.segment }
                        .font(.caption)
                } else if row.state == .working {
                    ProgressView("正在生成")
                } else {
                    Text(row.state.title).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(controller.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !controller.rows.isEmpty {
                ProgressView(value: Double(controller.completedCount), total: Double(controller.rows.count))
                    .accessibilityLabel("已完成 \(controller.completedCount)，共 \(controller.rows.count) 段")
                Text("预计发送：\(controller.remainingCount) 段 / \(controller.sendCharacterCount) 字符 · \(controller.settings?.providerName ?? "未配置模型")")
                    .font(.caption2).foregroundStyle(.secondary)
                if controller.pendingDisclosureRunID != nil {
                    Text("仅用于翻译所列原文；不包含笔记、其他来源或历史问答。")
                        .font(.caption)
                    Button("确认外发并翻译") { controller.confirmRemoteDisclosure() }
                        .buttonStyle(.borderedProminent)
                    Button("拒绝外发") { controller.cancel() }
                } else {
                    HStack {
                        Button(controller.completedCount > 0 ? "翻译缺失段落" : "翻译") { controller.translate() }
                            .buttonStyle(.borderedProminent)
                            .disabled(controller.isBusy || controller.settings == nil || controller.remainingCount == 0)
                        Button("取消") { controller.cancel() }.disabled(!controller.isBusy)
                        Menu {
                            Button("删除当前译文缓存", role: .destructive) { controller.deleteCurrentCache() }
                            Button("重新翻译") { controller.deleteCurrentCache(retranslate: true) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("译文缓存操作")
                        .disabled(controller.isBusy || controller.settings == nil)
                    }
                }
                Text("机器译文不是原文证据；请核对术语、数字和否定。离线无缓存时原文仍可阅读。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func matches(_ anchor: Locator, _ current: Locator) -> Bool {
        guard anchor.sourceID == current.sourceID, anchor.snapshotID == current.snapshotID else { return false }
        if let page = anchor.pdfPageIndex { return page == current.pdfPageIndex }
        if let line = current.lineRange?.lowerBound { return anchor.lineRange?.contains(line) == true }
        return anchor.payload["domPath"] == current.payload["domPath"]
    }
}

private struct BilingualPositionKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
