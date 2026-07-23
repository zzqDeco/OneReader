import AppKit
import Combine
import Foundation
import PDFKit

enum ReaderContentState: Equatable {
    case idle
    case loading
    case loaded(Observation)
    case failed(String)
}

struct AppNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sources: [ReadingSource]
    @Published private(set) var graph: ReadingGraph
    @Published private(set) var plan: ReadingPlan
    @Published private(set) var progress: ReadingProgress
    @Published var selectedUnitID: String?
    @Published var presentation: PresentationKind
    @Published private(set) var contentState: ReaderContentState = .idle
    @Published private(set) var markdownAssetBaseURL: URL?
    @Published private(set) var pdfDocument: PDFDocument?
    @Published private(set) var pdfPageIndex = 0
    @Published private(set) var isResolvingRepository = false
    @Published private(set) var isLoadingPDF = false
    @Published private(set) var isImporting = false
    @Published var isImportSheetPresented = false
    @Published var isRouteInspectorPresented = true
    @Published var notice: AppNotice?

    private let githubSource: GitHubBookSource
    private let progressStore: ProgressStore
    private let mapper: any SemanticMapping
    private let planner = ReadingPlanner()

    private var activeRepositoryBook: RepositoryBook?
    private var activePDFSnapshot: SourceSnapshot?
    private var markdownCache: [String: Observation] = [:]
    private var contentTask: Task<Void, Never>?
    private var pdfTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var isDemoWorkspace = true

    init(
        githubSource: GitHubBookSource = GitHubBookSource(),
        progressStore: ProgressStore = ProgressStore(),
        mapper: any SemanticMapping = DeterministicSemanticMapper()
    ) {
        self.githubSource = githubSource
        self.progressStore = progressStore
        self.mapper = mapper

        let initialGraph = mapper.mapRepositoryBook(
            title: "把时间当作朋友",
            repositorySnapshot: DemoCatalog.unresolvedRepositorySnapshot,
            chapters: DemoCatalog.fallbackChapters,
            pdfSnapshot: DemoCatalog.unresolvedPDFSnapshot,
            pdfPageHints: DemoCatalog.pdfPageHints
        )
        let initialProgress = ReadingProgress.empty
        sources = [
            DemoCatalog.unresolvedRepositorySource,
            DemoCatalog.unresolvedPDFSource
        ]
        graph = initialGraph
        progress = initialProgress
        plan = planner.makePlan(
            graph: initialGraph,
            goal: initialProgress.activeGoal,
            progress: initialProgress
        )
        selectedUnitID = initialGraph.units.first?.id
        presentation = .repository

        Task { [weak self] in
            await self?.bootstrap()
        }
    }

    deinit {
        contentTask?.cancel()
        pdfTask?.cancel()
        persistenceTask?.cancel()
    }

    var selectedUnit: ReadingUnit? {
        guard let selectedUnitID else { return nil }
        return graph.units.first { $0.id == selectedUnitID }
    }

    var currentObservation: Observation? {
        if case let .loaded(observation) = contentState {
            return observation
        }
        return nil
    }

    var completedCount: Int {
        graph.units.reduce(into: 0) { count, unit in
            if progress.state(for: unit.id) == .completed {
                count += 1
            }
        }
    }

    var completionFraction: Double {
        guard !graph.units.isEmpty else { return 0 }
        return Double(completedCount) / Double(graph.units.count)
    }

    var activeSourceRevisionLabel: String {
        let revisions = graph.sourceSnapshots.filter(\.isResolved)
        guard let repository = revisions.first(where: {
            $0.sourceID.hasPrefix("github:")
        }) else {
            return "等待 Source revision"
        }
        return String(repository.revision.prefix(7))
    }

    func unit(for plannedUnit: PlannedUnit) -> ReadingUnit? {
        graph.units.first { $0.id == plannedUnit.unitID }
    }

    func selectUnit(_ unitID: String) {
        guard let unit = graph.units.first(where: { $0.id == unitID }) else {
            return
        }
        selectedUnitID = unit.id
        progress.currentUnitID = unit.id
        progress.graphVersion = graph.version
        progress.lastActiveAt = .now

        if progress.state(for: unit.id) == .unseen {
            progress.units[unit.id] = UnitProgress(
                unitID: unit.id,
                state: .reading,
                fraction: 0.05,
                updatedAt: .now
            )
        }

        if !unit.availablePresentations.contains(presentation) {
            presentation = unit.repositoryFragment != nil ? .repository : .pdf
        }
        if let pageIndex = unit.pdfFragment?.locator.pdfPageIndex {
            pdfPageIndex = pageIndex
        }
        loadSelectedRepositoryContent()
        if presentation != .repository {
            loadPDFIfNeeded()
        }
        persistProgress()
    }

    func setPresentation(_ newPresentation: PresentationKind) {
        guard selectedUnit?.availablePresentations.contains(newPresentation) == true else {
            return
        }
        presentation = newPresentation
        if newPresentation != .repository {
            if let pageIndex = selectedUnit?.pdfFragment?.locator.pdfPageIndex {
                pdfPageIndex = pageIndex
            }
            loadPDFIfNeeded()
        }
        if newPresentation != .pdf {
            loadSelectedRepositoryContent()
        }
    }

    func changeGoal(_ goal: ReadingGoal) {
        guard progress.activeGoal != goal else { return }
        progress.activeGoal = goal
        progress.lastActiveAt = .now
        rebuildPlan()
        persistProgress()
    }

    func selectPreviousUnit() {
        guard
            let selectedUnitID,
            let index = plan.orderedUnits.firstIndex(where: { $0.unitID == selectedUnitID }),
            index > 0
        else {
            return
        }
        selectUnit(plan.orderedUnits[index - 1].unitID)
    }

    func selectNextUnit() {
        guard
            let selectedUnitID,
            let index = plan.orderedUnits.firstIndex(where: { $0.unitID == selectedUnitID }),
            index + 1 < plan.orderedUnits.count
        else {
            return
        }
        selectUnit(plan.orderedUnits[index + 1].unitID)
    }

    func markCurrentUnitCompleted(advance: Bool = true) {
        guard let selectedUnitID else { return }
        progress.units[selectedUnitID] = UnitProgress(
            unitID: selectedUnitID,
            state: .completed,
            fraction: 1,
            updatedAt: .now
        )
        progress.lastActiveAt = .now
        persistProgress()
        if advance {
            selectNextUnit()
        }
    }

    func openFragment(_ fragment: SourceFragment) {
        switch fragment.locator.native {
        case .repository:
            setPresentation(.repository)
        case let .pdf(pageIndex):
            pdfPageIndex = pageIndex
            setPresentation(.pdf)
            updatePDFPosition(pageIndex)
        }
    }

    func setPDFPage(_ pageIndex: Int) {
        guard let document = pdfDocument else { return }
        let clamped = min(max(0, pageIndex), max(document.pageCount - 1, 0))
        guard clamped != pdfPageIndex else { return }
        pdfPageIndex = clamped
        updatePDFPosition(clamped)
    }

    func reloadSelectedContent() {
        if presentation != .pdf {
            loadSelectedRepositoryContent(force: true)
        }
        if presentation != .repository {
            loadPDFIfNeeded(force: true)
        }
    }

    func importRepository(urlString: String) {
        guard let url = URL(string: urlString) else {
            notice = AppNotice(
                title: "无法导入",
                message: GitHubBookSourceError.invalidRepositoryURL.localizedDescription
            )
            return
        }
        isImporting = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let book = try await githubSource.loadBook(from: url)
                applyImportedRepository(book)
                isImportSheetPresented = false
            } catch {
                notice = AppNotice(
                    title: "GitHub Repo 导入失败",
                    message: error.localizedDescription
                )
            }
            isImporting = false
        }
    }

    func presentLocalPDFImporter() {
        let panel = NSOpenPanel()
        panel.title = "选择 PDF"
        panel.prompt = "打开"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        isImportSheetPresented = false
        isImporting = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
                applyImportedPDF(data: data, url: url)
            } catch {
                notice = AppNotice(
                    title: "PDF 导入失败",
                    message: error.localizedDescription
                )
            }
            isImporting = false
        }
    }

    func restoreDemo() {
        contentTask?.cancel()
        pdfTask?.cancel()
        activeRepositoryBook = nil
        activePDFSnapshot = nil
        pdfDocument = nil
        markdownCache.removeAll()
        isDemoWorkspace = true
        sources = [
            DemoCatalog.unresolvedRepositorySource,
            DemoCatalog.unresolvedPDFSource
        ]
        graph = mapper.mapRepositoryBook(
            title: "把时间当作朋友",
            repositorySnapshot: DemoCatalog.unresolvedRepositorySnapshot,
            chapters: DemoCatalog.fallbackChapters,
            pdfSnapshot: DemoCatalog.unresolvedPDFSnapshot,
            pdfPageHints: DemoCatalog.pdfPageHints
        )
        rebuildPlan()
        selectUnit(graph.units.first?.id ?? "")
        Task { [weak self] in
            await self?.resolveDemoRepository()
        }
    }

    func openCurrentSourceInBrowser() {
        guard let url = selectedUnit?.repositoryFragment.flatMap(repositoryWebURL) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func resizeMainWindow(width: CGFloat, height: CGFloat) {
        isRouteInspectorPresented = width > 1_000

        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            return
        }
        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: width, height: height)
        let target = NSSize(
            width: min(width, max(visibleFrame.width - 32, 700)),
            height: min(height, max(visibleFrame.height - 32, 560))
        )
        window.setContentSize(target)
        window.center()
    }

    private func bootstrap() async {
        do {
            progress = try await progressStore.load()
        } catch {
            notice = AppNotice(
                title: "进度未载入",
                message: error.localizedDescription
            )
            progress = .empty
        }
        rebuildPlan()
        if
            let restored = progress.currentUnitID,
            graph.units.contains(where: { $0.id == restored })
        {
            selectedUnitID = restored
        } else {
            selectedUnitID = plan.orderedUnits.first?.unitID
        }
        await resolveDemoRepository()
    }

    private func resolveDemoRepository() async {
        isResolvingRepository = true
        do {
            let book = try await githubSource.loadBook(from: DemoCatalog.repositoryURL)
            activeRepositoryBook = book
            replaceSource(book.source)
            rebuildDemoGraph(repositorySnapshot: book.snapshot, chapters: book.chapters)
            loadSelectedRepositoryContent()
        } catch {
            markSource(
                id: DemoCatalog.repositorySourceID,
                availability: .offline,
                detail: "暂时离线 · 保留结构"
            )
            contentState = .failed(error.localizedDescription)
            notice = AppNotice(
                title: "公开仓库暂时不可达",
                message: "目录结构仍可浏览；联网后点“重新载入”恢复原文。\(error.localizedDescription)"
            )
        }
        isResolvingRepository = false
    }

    private func rebuildDemoGraph(
        repositorySnapshot: SourceSnapshot? = nil,
        chapters: [RepositoryChapter]? = nil
    ) {
        let repoSnapshot = repositorySnapshot
            ?? activeRepositoryBook?.snapshot
            ?? DemoCatalog.unresolvedRepositorySnapshot
        let activeChapters = chapters
            ?? activeRepositoryBook?.chapters
            ?? DemoCatalog.fallbackChapters
        graph = mapper.mapRepositoryBook(
            title: "把时间当作朋友",
            repositorySnapshot: repoSnapshot,
            chapters: activeChapters,
            pdfSnapshot: activePDFSnapshot ?? DemoCatalog.unresolvedPDFSnapshot,
            pdfPageHints: DemoCatalog.pdfPageHints
        )
        reconcileSelectionAndProgress()
    }

    private func applyImportedRepository(_ book: RepositoryBook) {
        contentTask?.cancel()
        pdfTask?.cancel()
        activeRepositoryBook = book
        activePDFSnapshot = nil
        pdfDocument = nil
        markdownCache.removeAll()
        isDemoWorkspace = false
        sources = [book.source]
        graph = mapper.mapRepositoryBook(
            title: book.source.title,
            repositorySnapshot: book.snapshot,
            chapters: book.chapters,
            pdfSnapshot: nil,
            pdfPageHints: [:]
        )
        presentation = .repository
        reconcileSelectionAndProgress(preferFirstUnit: true)
        loadSelectedRepositoryContent()
    }

    private func applyImportedPDF(data: Data, url: URL) {
        do {
            let sourceSeed = DeterministicSemanticMapper.stableDigest(url.path)
            let sourceID = "pdf:local:\(sourceSeed)"
            let (document, inspection) = try PDFBookSource.inspect(
                data: data,
                title: url.deletingPathExtension().lastPathComponent,
                sourceID: sourceID,
                origin: url
            )
            activeRepositoryBook = nil
            activePDFSnapshot = inspection.snapshot
            pdfDocument = document
            isDemoWorkspace = false
            markdownCache.removeAll()
            sources = [inspection.source]
            graph = mapper.mapPDF(
                title: inspection.source.title,
                snapshot: inspection.snapshot,
                sections: inspection.sections
            )
            presentation = .pdf
            pdfPageIndex = graph.units.first?.pdfFragment?.locator.pdfPageIndex ?? 0
            reconcileSelectionAndProgress(preferFirstUnit: true)
        } catch {
            notice = AppNotice(
                title: "PDF 导入失败",
                message: error.localizedDescription
            )
        }
    }

    private func loadSelectedRepositoryContent(force: Bool = false) {
        guard
            let unit = selectedUnit,
            let fragment = unit.repositoryFragment
        else {
            contentTask?.cancel()
            contentState = .idle
            markdownAssetBaseURL = nil
            return
        }

        if !force, let cached = markdownCache[fragment.locator.stableID] {
            contentState = .loaded(cached)
            markdownAssetBaseURL = assetBaseURL(for: fragment)
            return
        }
        guard
            let book = activeRepositoryBook,
            book.snapshot.sourceID == fragment.sourceID
        else {
            contentState = .loading
            return
        }
        guard case let .repository(path, _, _) = fragment.locator.native else {
            return
        }

        contentTask?.cancel()
        contentState = .loading
        markdownAssetBaseURL = assetBaseURL(for: fragment)
        let expectedUnitID = unit.id
        let locatorID = fragment.locator.stableID
        contentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let observation = try await githubSource.readMarkdown(
                    coordinate: book.coordinate,
                    revision: book.snapshot.revision,
                    path: path
                )
                guard !Task.isCancelled, selectedUnitID == expectedUnitID else {
                    return
                }
                markdownCache[locatorID] = observation
                contentState = .loaded(observation)
            } catch {
                guard !Task.isCancelled, selectedUnitID == expectedUnitID else {
                    return
                }
                contentState = .failed(error.localizedDescription)
            }
        }
    }

    private func loadPDFIfNeeded(force: Bool = false) {
        guard pdfDocument == nil || force else { return }
        guard isDemoWorkspace else { return }

        pdfTask?.cancel()
        isLoadingPDF = true
        pdfTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await PDFBookSource.loadRemoteData(from: DemoCatalog.pdfURL)
                try Task.checkCancellation()
                let (document, inspection) = try PDFBookSource.inspect(
                    data: data,
                    title: "把时间当作朋友 · 第三版 PDF",
                    sourceID: DemoCatalog.pdfSourceID,
                    origin: DemoCatalog.pdfURL
                )
                guard !Task.isCancelled else { return }
                pdfDocument = document
                activePDFSnapshot = inspection.snapshot
                replaceSource(inspection.source)
                rebuildDemoGraph()
                if let pageIndex = selectedUnit?.pdfFragment?.locator.pdfPageIndex {
                    pdfPageIndex = pageIndex
                }
            } catch is CancellationError {
                return
            } catch {
                markSource(
                    id: DemoCatalog.pdfSourceID,
                    availability: .offline,
                    detail: "PDF 暂时不可达"
                )
                notice = AppNotice(
                    title: "PDF 载入失败",
                    message: error.localizedDescription
                )
            }
            isLoadingPDF = false
        }
    }

    private func reconcileSelectionAndProgress(preferFirstUnit: Bool = false) {
        progress.graphVersion = graph.version
        if
            !preferFirstUnit,
            let selectedUnitID,
            graph.units.contains(where: { $0.id == selectedUnitID })
        {
            self.selectedUnitID = selectedUnitID
        } else {
            selectedUnitID = graph.units.first?.id
            progress.currentUnitID = selectedUnitID
        }
        rebuildPlan()
        persistProgress()
    }

    private func rebuildPlan() {
        plan = planner.makePlan(
            graph: graph,
            goal: progress.activeGoal,
            progress: progress
        )
    }

    private func persistProgress() {
        progress.lastActiveAt = .now
        let value = progress
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await progressStore.save(value)
            } catch is CancellationError {
                return
            } catch {
                notice = AppNotice(
                    title: "进度未保存",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func updatePDFPosition(_ pageIndex: Int) {
        guard
            let source = sources.first(where: { $0.kind == .pdf }),
            let revision = source.revision
        else {
            return
        }
        let locator = Locator(
            sourceID: source.id,
            sourceRevision: revision,
            native: .pdf(pageIndex: pageIndex),
            textAnchor: nil,
            fingerprint: nil
        )
        progress.sourcePositions[source.id] = SourcePosition(
            sourceID: source.id,
            locator: locator,
            updatedAt: .now
        )
        persistProgress()
    }

    private func replaceSource(_ source: ReadingSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
    }

    private func markSource(
        id: String,
        availability: SourceAvailability,
        detail: String
    ) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            return
        }
        sources[index].availability = availability
        sources[index].detail = detail
    }

    private func assetBaseURL(for fragment: SourceFragment) -> URL? {
        guard
            let book = activeRepositoryBook,
            case let .repository(path, _, _) = fragment.locator.native
        else {
            return nil
        }
        let directory = (path as NSString).deletingLastPathComponent
        var components = URLComponents()
        components.scheme = "https"
        components.host = "raw.githubusercontent.com"
        components.path = "/\(book.coordinate.owner)/\(book.coordinate.repository)/\(book.snapshot.revision)"
        if !directory.isEmpty {
            components.path += "/\(directory)"
        }
        components.path += "/"
        return components.url
    }

    private func repositoryWebURL(for fragment: SourceFragment) -> URL? {
        guard
            let book = activeRepositoryBook,
            case let .repository(path, _, _) = fragment.locator.native
        else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(book.coordinate.owner)/\(book.coordinate.repository)/blob/\(book.snapshot.revision)/\(path)"
        return components.url
    }
}

private extension Locator {
    var pdfPageIndex: Int? {
        if case let .pdf(pageIndex) = native {
            return pageIndex
        }
        return nil
    }
}
