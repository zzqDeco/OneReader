import Combine
import Foundation

enum TranslationRowState: Equatable {
    case pending, working, cached, verbatim, failed, unknown
    var title: String {
        switch self {
        case .pending: "尚未翻译"
        case .working: "翻译中"
        case .cached: "已缓存 · 机器译文"
        case .verbatim: "代码或原始内容 · 保留原文"
        case .failed: "失败 · 可重试"
        case .unknown: "请求结果未知 · 可重试"
        }
    }
}

struct BilingualRow: Identifiable {
    var id: String { segment.id }
    let segment: TranslationSegment
    var state: TranslationRowState
    var cached: CachedTranslation?
}

/// Host-owned translation controller. Serial segment requests use the existing Reading Agent session.
@MainActor
final class BilingualReadingModel: ObservableObject {
    @Published private(set) var rows: [BilingualRow] = []
    @Published private(set) var isBusy = false
    @Published private(set) var status = "选中原文或加载当前阅读单元，再决定是否翻译。"
    @Published private(set) var settings: TranslationSettings?
    @Published private(set) var pendingDisclosureRunID: String?
    @Published private(set) var sourceLanguageSuggestion: String?
    @Published var layout: BilingualLayout = .interleaved {
        didSet { defaults?.set(layout.rawValue, forKey: "bilingual.layout") }
    }
    @Published var followsSource = false
    @Published var sourceLanguage: TranslationLanguage = .automatic {
        didSet {
            defaults?.set(sourceLanguage.rawValue, forKey: "bilingual.sourceLanguage")
            if oldValue != sourceLanguage { reloadSettings() }
        }
    }
    @Published var targetLanguage: TranslationLanguage = .simplifiedChinese {
        didSet {
            defaults?.set(targetLanguage.rawValue, forKey: "bilingual.targetLanguage")
            if oldValue != targetLanguage { reloadSettings() }
        }
    }
    private var database: LibraryDatabase?
    private var coordinator: AdapterCoordinator?
    private var runtime: ReadingAgentRuntime?
    private var profile: ProviderProfile?
    private var spaceID: String?
    private var sourceIdentity: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var activeRunID: String?
    private var defaults: UserDefaults?
    private(set) var lastReadLocator: Locator?

    func recordUserReading(_ locator: Locator) { lastReadLocator = locator }
    func originalReaderBecameActive() { lastReadLocator = nil }

    var completedCount: Int { rows.filter { $0.state == .cached || $0.state == .verbatim }.count }
    var remainingCount: Int { rows.filter { $0.state != .cached && $0.state != .verbatim }.count }
    var sendCharacterCount: Int { rows.filter { $0.state != .cached && $0.state != .verbatim }.reduce(0) { $0 + $1.segment.modelText.utf16.count } }

    func configure(database: LibraryDatabase, coordinator: AdapterCoordinator, runtime: ReadingAgentRuntime,
                   defaults: UserDefaults? = nil) {
        self.database = database; self.coordinator = coordinator; self.runtime = runtime
        self.defaults = defaults
        if let value = defaults?.string(forKey: "bilingual.sourceLanguage").flatMap(TranslationLanguage.init(rawValue:)) { sourceLanguage = value }
        if let value = defaults?.string(forKey: "bilingual.targetLanguage").flatMap(TranslationLanguage.init(rawValue:)), value != .automatic { targetLanguage = value }
        if let value = defaults?.string(forKey: "bilingual.layout").flatMap(BilingualLayout.init(rawValue:)) { layout = value }
    }

    func sourceWillChange(spaceID: String, sourceID: String, snapshotID: String) {
        let identity = spaceID + ":" + sourceID + "@" + snapshotID
        guard sourceIdentity != identity else { return }
        cancel()
        sourceIdentity = identity
        lastReadLocator = nil
        rows = []; settings = nil; pendingDisclosureRunID = nil
        status = "当前来源尚未加载对照片段；不会自动发送原文。"
    }

    func providerDidChange(_ profile: ProviderProfile?) {
        guard self.profile != profile else { return }
        self.profile = profile
        reloadSettings()
    }

    func prepare(spaceID: String, document: PresentationDocument, locator: Locator,
                 nextLocator: Locator?, selection: ReaderSelection?, plan: AdapterPlan,
                 profile: ProviderProfile?) {
        cancel()
        guard let database, let coordinator else { return }
        self.spaceID = spaceID; self.profile = profile
        sourceIdentity = spaceID + ":" + locator.sourceID + "@" + locator.snapshotID
        let expected = generation
        isBusy = true; rows = []; pendingDisclosureRunID = nil
        status = "正在读取本地原文；尚未访问模型。"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let segments = try await TranslationSourceBuilder.prepare(document: document,
                    locator: locator, nextLocator: nextLocator, selection: selection,
                    plan: plan, coordinator: coordinator, database: database)
                try Task.checkCancellation()
                guard generation == expected else { return }
                rows = segments.map { BilingualRow(segment: $0, state: $0.isVerbatim ? .verbatim : .pending) }
                let text = segments.map(\.originalText).joined()
                let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
                sourceLanguageSuggestion = cjk > 10 ? "原文可能为中文（推测，可手动纠正）" : "原文语言未确认，可手动指定"
                reloadSettings(cancelWork: false)
            } catch is CancellationError {
                return
            } catch {
                guard generation == expected else { return }
                status = error.localizedDescription
            }
            if generation == expected { isBusy = false }
        }
    }

    func translate() { startTranslations(resuming: nil) }

    func confirmRemoteDisclosure() {
        guard let id = pendingDisclosureRunID, let database else { return }
        do {
            try database.acknowledgeRemoteDisclosure(runID: id)
            pendingDisclosureRunID = nil
            startTranslations(resuming: id)
        } catch { status = "授权已失效，请重新加载当前范围。" }
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isBusy = false
        let runID = activeRunID ?? pendingDisclosureRunID
        activeRunID = nil; pendingDisclosureRunID = nil
        if let runID, let spaceID, let runtime {
            Task { if let session = try? await runtime.session(forSpaceID: spaceID) { await session.cancel(runID: runID) } }
        }
        for index in rows.indices where rows[index].state == .working { rows[index].state = .unknown }
        if !rows.isEmpty { status = "已取消；成功段落保留。已发送但未确认的请求可能已计费，重试可能重复计费。" }
    }

    func deleteCurrentCache(retranslate: Bool = false) {
        let cancellingRunID = activeRunID ?? pendingDisclosureRunID
        cancel()
        guard let database, let settings else { return }
        let segments = rows.map(\.segment)
        let expected = generation
        isBusy = true
        task = Task { [weak self] in
            guard let self else { return }
            if let cancellingRunID, let spaceID, let runtime,
               let session = try? await runtime.session(forSpaceID: spaceID) {
                await session.cancel(runID: cancellingRunID)
            }
            guard generation == expected else { return }
            do {
                try database.deleteTranslations(segments: segments, settings: settings)
                for index in rows.indices where !rows[index].segment.isVerbatim {
                    rows[index].cached = nil; rows[index].state = .pending
                }
                status = "已删除当前语言与模型的译文缓存。原文、标注及阅读进度未改变。"
            } catch { status = "无法删除译文缓存。" }
            isBusy = false
            if retranslate { translate() }
        }
    }

    private func reloadSettings(cancelWork: Bool = true) {
        if cancelWork { cancel() }
        settings = nil
        for index in rows.indices where !rows[index].segment.isVerbatim {
            rows[index].cached = nil; rows[index].state = .pending
        }
        guard let profile, let database else {
            status = "未配置模型。原文仍可阅读；配置过的模型可离线加载其已缓存译文。"
            return
        }
        do {
            let value = try TranslationSettings(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, profile: profile)
            settings = value
            let unknown = try spaceID.map { try database.unfinishedTranslationSegmentIDs(spaceID: $0, settings: value) } ?? []
            for index in rows.indices where !rows[index].segment.isVerbatim {
                let cached = try database.cachedTranslation(segment: rows[index].segment, settings: value)
                rows[index].cached = cached
                rows[index].state = cached != nil ? .cached : (unknown.contains(rows[index].id) ? .unknown : .pending)
            }
            status = rows.isEmpty ? "请加载当前单元或原文选区。" : "本地缓存 \(completedCount)/\(rows.count) 段。缺失译文不会自动联网。"
        } catch { status = error.localizedDescription }
    }

    private func startTranslations(resuming runID: String?) {
        guard !isBusy, let database, let runtime, let spaceID, let settings, remainingCount > 0 else { return }
        task?.cancel(); generation = UUID()
        let expected = generation
        isBusy = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await runtime.session(forSpaceID: spaceID)
                var resume = runID
                for index in rows.indices {
                    try Task.checkCancellation()
                    guard generation == expected else { return }
                    let segment = rows[index].segment
                    if segment.isVerbatim { continue }
                    if let cached = try database.cachedTranslation(segment: segment, settings: settings) {
                        rows[index].cached = cached; rows[index].state = .cached
                        continue
                    }
                    rows[index].state = .working
                    status = "正在翻译第 \(index + 1)/\(rows.count) 段；原文仍可阅读。"
                    let handle: AgentRunHandle
                    if let prior = resume {
                        handle = try await session.resume(runID: prior); resume = nil
                    } else {
                        let manifest = try database.currentSnapshotManifest(spaceID: spaceID)
                        handle = try await session.start(AgentRunRequest(spaceID: spaceID, task: .translateFragments,
                            targetSourceID: segment.locator.sourceID, targetSnapshotID: segment.locator.snapshotID,
                            expectedSnapshotIDs: Set(manifest.values), snapshotManifest: manifest,
                            translation: TranslationRequest(settings: settings, segments: [segment])))
                    }
                    guard generation == expected, !Task.isCancelled else {
                        await session.cancel(runID: handle.runID)
                        return
                    }
                    activeRunID = handle.runID
                    do { for try await _ in handle.events { try Task.checkCancellation() } }
                    catch is CancellationError { await session.cancel(runID: handle.runID); throw CancellationError() }
                    catch { /* Durable run status below distinguishes failure from waiting. */ }
                    try Task.checkCancellation()
                    guard generation == expected else { return }
                    activeRunID = nil
                    let state = try database.agentRunState(runID: handle.runID)
                    if state == .waitingForUser {
                        pendingDisclosureRunID = handle.runID
                        rows[index].state = .pending
                        status = "等待确认外发：仅发送以上未缓存原文片段用于翻译，不发送笔记、历史问答或其他来源。"
                        break
                    }
                    if let cached = try database.cachedTranslation(segment: segment, settings: settings) {
                        rows[index].cached = cached; rows[index].state = .cached
                    } else {
                        rows[index].state = .unknown
                        status = "未获得有效译文。成功段落已保存；已发送请求可能计费，重试可能重复计费。"
                        break
                    }
                }
                if remainingCount == 0 { status = "全部片段可离线阅读。机器译文请核对术语、否定与数字。" }
            } catch is CancellationError {
                return
            } catch {
                guard generation == expected else { return }
                status = "翻译未完成，原文不受影响；请检查模型设置或稍后重试。"
                for index in rows.indices where rows[index].state == .working { rows[index].state = .unknown }
            }
            if generation == expected { isBusy = false; activeRunID = nil }
        }
    }
}
