import Combine
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class OCRReaderController: ObservableObject {
    @Published private(set) var job: OCRJob?
    @Published private(set) var revisions: [OCRRevision] = []
    @Published private(set) var pageCount = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false
    private var database: LibraryDatabase?
    private var context: AdapterContext?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let engine: any LocalOCREngine

    init(engine: any LocalOCREngine = VisionOCREngine()) { self.engine = engine }

    func configure(database: LibraryDatabase) { self.database = database }

    func load(context: AdapterContext) {
        let sameSnapshot = self.context?.source.id == context.source.id
            && self.context?.snapshot.id == context.snapshot.id
        if sameSnapshot, isRunning { return }
        if !sameSnapshot { reset() }
        self.context = context
        do {
            pageCount = try VisionOCREngine.pageCount(context: context)
            revisions = try database?.ocrRevisions(snapshotID: context.snapshot.id) ?? []
            job = try database?.ocrJobs(snapshotID: context.snapshot.id).first
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func start(pages: [Int], settings: OCRSettings, resume: OCRJob? = nil,
               completed: @escaping @MainActor (OCRRevision?) async -> Void) {
        guard let database, let context, !isRunning else { return }
        isRunning = true; errorMessage = nil
        let generation = UUID()
        self.generation = generation
        let engine = engine
        task = Task { [weak self] in
            var message: String?
            do {
                let service = OCRService(database: database, engine: engine)
                let revision = try await service.run(context: context, pages: pages, settings: settings,
                    resuming: resume) { [weak self] job in
                        await MainActor.run {
                            guard self?.generation == generation else { return }
                            self?.job = job
                        }
                    }
                guard self?.generation == generation else { return }
                await completed(revision)
            } catch { message = error.localizedDescription }
            guard self?.generation == generation else { return }
            self?.isRunning = false
            self?.load(context: context)
            self?.errorMessage = message
            self?.task = nil
        }
    }

    func cancel() { task?.cancel() }

    /// Switching sources invalidates UI callbacks, even when native recognition is still ending.
    func reset() {
        task?.cancel(); task = nil; generation = UUID(); context = nil
        isRunning = false; job = nil; revisions = []; pageCount = 0; errorMessage = nil
    }
}

struct OCRReaderPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: OCRReaderController
    @State private var rangeMode = 0
    @State private var firstPage = "1"
    @State private var lastPage = "1"
    @State private var language = 0
    @State private var replaceNativeText = false

    var body: some View {
        NavigationStack {
            Form {
                Section("本机文字识别") {
                    ReaderPanelHeading(title: "让扫描内容可以搜索与标注",
                        subtitle: "识别仅在此设备完成，不上传原文，也不改变原始文件和阅读位置。",
                        systemImage: "text.viewfinder")
                    Picker("识别范围", selection: $rangeMode) {
                        Text("当前页").tag(0); Text("页码范围").tag(1); Text("全部页面").tag(2)
                    }
                    Text("共 \(controller.pageCount) 页；单次最多识别 1,000 页。")
                        .font(.caption).foregroundStyle(.secondary)
                    if rangeMode == 1 {
                        ReaderAdaptiveActions {
                            TextField("起始页", text: $firstPage).textFieldStyle(.roundedBorder)
                                .frame(minWidth: 70, maxWidth: 120).accessibilityLabel("OCR 起始页")
                            TextField("结束页", text: $lastPage).textFieldStyle(.roundedBorder)
                                .frame(minWidth: 70, maxWidth: 120).accessibilityLabel("OCR 结束页")
                        }
                    }
                    Picker("印刷文字语言", selection: $language) {
                        Text("简体中文与英文").tag(0); Text("英文").tag(1)
                    }
                    Text("默认保留有效原生文字；手写、复杂表格和公式不保证准确。")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("高级识别设置") {
                        Toggle("用 OCR 替代所选页的原生文字", isOn: $replaceNativeText)
                    }
                    if controller.isRunning {
                        ProgressView(value: Double((controller.job?.completedPages.count ?? 0) + (controller.job?.failedPages.count ?? 0)),
                            total: Double(max(1, controller.job?.pageIndices.count ?? 1)))
                        Button("取消识别", role: .cancel) { controller.cancel() }
                    } else {
                        Button { model.startLocalOCR(pages: selectedPages, settings: settings) } label: {
                            ReaderActionLabel(title: "开始本机识别", systemImage: "text.viewfinder")
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedPages.isEmpty)
                            .accessibilityIdentifier("ocr-start")
                    }
                    if let job = controller.job {
                        Text("已完成 \(job.completedPages.count) 页 · 失败 \(job.failedPages.count) 页 · \(job.state.rawValue)")
                            .font(.caption.monospacedDigit())
                        if !job.failedPages.isEmpty {
                            DisclosureGroup("\(job.failedPages.count) 页未完成 · 查看原因") {
                                Text("未完成页：\(job.failedPages.map { String($0 + 1) }.joined(separator: "、"))")
                                    .foregroundStyle(.secondary)
                                ForEach(job.failedPages, id: \.self) { page in
                                    if let reason = job.failureReasons[page] {
                                        Text("第 \(page + 1) 页：\(reason)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if [.interrupted, .cancelled, .partial, .failed].contains(job.state), !controller.isRunning {
                            Button("继续未完成页面") { model.startLocalOCR(pages: job.pageIndices, settings: job.settings, resume: job) }
                        }
                    }
                    if let error = controller.errorMessage { Text(error).foregroundStyle(.red) }
                }
                if let revision = model.ocrDisplayRevision {
                    Section("识别文字 · 请对照原图核实") {
                        Toggle("在原图上选择识别行", isOn: $model.ocrTextSelectionEnabled)
                        Text("开启后点击原图中的文字区域；双指缩放与滚动保持原生行为。也可从下方定位、复制或添加高亮。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(revision.pages) { page in
                            DisclosureGroup("第 \(page.pageIndex + 1) 页 · \(page.usesNativeText ? "原生文字（未 OCR）" : "\(page.spans.count) 行")") {
                                DisclosureGroup("生成来源与设置") { OCRPageProvenanceView(page: page) }
                                if page.usesNativeText {
                                    Text("本页保留 PDF 原生文字，没有执行 OCR；请在原文中选择文字。")
                                        .foregroundStyle(.secondary)
                                } else if page.spans.isEmpty {
                                    Text("本页未识别出可用文字，可调整语言后重试。").foregroundStyle(.secondary)
                                }
                                ForEach(page.spans) { span in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(span.text).textSelection(.enabled)
                                        ReaderAdaptiveActions {
                                            Button {
                                                model.selectOCRSpan(revision: revision, page: page, span: span)
                                                dismiss()
                                            } label: {
                                                ReaderActionLabel(title: "定位", systemImage: "scope")
                                            }
                                            Button { Self.copy(span.text) } label: {
                                                ReaderActionLabel(title: "复制", systemImage: "doc.on.doc")
                                            }
                                            Button {
                                                model.selectOCRSpan(revision: revision, page: page, span: span)
                                                model.addHighlight()
                                            } label: {
                                                ReaderActionLabel(title: "高亮", systemImage: "highlighter")
                                            }
                                        }
                                        .buttonStyle(.borderless)
                                        Text("可信度 \(Int(span.confidence * 100))%")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 8)
                                    .accessibilityElement(children: .contain)
                                }
                            }
                        }
                    }
                    Section("识别版本") {
                        ForEach(controller.revisions) { revision in
                            Button {
                                model.selectLocalOCRRevision(revision)
                            } label: {
                                HStack {
                                    Text(revision.createdAt, style: .date)
                                    Text(revision.createdAt, style: .time)
                                    Spacer()
                                    Text("\(revision.pages.count) 页")
                                    if revision.id == model.ocrDisplayRevision?.id { Image(systemName: "checkmark") }
                                }
                            }.disabled(controller.isRunning)
                        }
                        Text("旧版本保留，已有笔记和引用不会悄悄改用新识别结果。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("版本的引擎和设置只描述发布这次任务；沿用页的生成设置请在对应页查看。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("识别文字")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
#if os(macOS)
        .frame(minWidth: 480, idealWidth: 600, minHeight: 420, idealHeight: 680)
#endif
        .onAppear {
            firstPage = String((model.currentPositionLocator?.pdfPageIndex ?? 0) + 1)
            lastPage = String(controller.pageCount)
        }
    }

    private var settings: OCRSettings {
        OCRSettings(languages: language == 0 ? ["zh-Hans", "en-US"] : ["en-US"], replaceNativeText: replaceNativeText)
    }
    private var selectedPages: [Int] {
        guard controller.pageCount > 0 else { return [] }
        if rangeMode == 0 { return [min(controller.pageCount - 1, max(0, model.currentPositionLocator?.pdfPageIndex ?? 0))] }
        if rangeMode == 2 { return controller.pageCount <= OCRSettings.maximumPagesPerJob ? Array(0..<controller.pageCount) : [] }
        guard let start = Int(firstPage), let end = Int(lastPage), start > 0, end >= start,
              end <= controller.pageCount, end - start < OCRSettings.maximumPagesPerJob else { return [] }
        return Array((start - 1)..<end)
    }
    private static func copy(_ value: String) {
#if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
#else
        UIPasteboard.general.string = value
#endif
    }
}

private struct OCRPageProvenanceView: View {
    let page: OCRPage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch page.provenance {
            case .unknown:
                Text("生成来源未知：旧记录未保存逐页引擎、设置、任务及时间；不会用本次设置补填。")
            case .recognized(let record), .nativeText(let record):
                Text(page.usesNativeText ? "来源：PDF 原生文字（未执行 OCR）" : "来源：本机 OCR")
                Text("引擎：\(record.engineVersion == OCRPageProvenance.unknownEngineVersion ? "未知" : record.engineVersion)")
                Text("\(page.usesNativeText ? "任务语言（未用于 OCR）" : "识别语言")：\(record.settings.languages.joined(separator: "、"))")
                Text("原生文字策略：\(record.settings.replaceNativeText ? "使用 OCR 替代" : "保留有效原生文字")")
                Text("任务：\(record.jobID)")
                Text("\(page.usesNativeText ? "保留时间" : "识别结果接收时间")：\(record.recognizedAt.formatted(date: .numeric, time: .standard))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}
