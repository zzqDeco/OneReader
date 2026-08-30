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
    @Published private(set) var isBootstrapComplete = false
    @Published var isImportSheetPresented = false
    @Published var isRouteInspectorPresented = true
    @Published var notice: AppNotice?

    private let githubSource: GitHubBookSource
    private let progressStore: ProgressStore
    private let mapper: any SemanticMapping
    private let libraryRootURL: URL?
    private var libraryDatabase: LibraryDatabase?
    private var managedLibrary: ManagedLibrary?
    private var libraryInitializationError: String?
    private var progressPersistenceEnabled = false
    private let planner = ReadingPlanner()

    private var activeRepositoryBook: RepositoryBook?
    private var activePDFSnapshot: SourceSnapshot?
    private var markdownCache: [String: Observation] = [:]
    private var contentTask: Task<Void, Never>?
    private var pdfTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?

    init(
        githubSource: GitHubBookSource = GitHubBookSource(),
        progressStore: ProgressStore = ProgressStore(),
        mapper: any SemanticMapping = DeterministicSemanticMapper(),
        libraryRootURL: URL? = nil
    ) {
        self.githubSource = githubSource
        self.progressStore = progressStore
        self.mapper = mapper
        self.libraryRootURL = libraryRootURL

        libraryDatabase = nil
        managedLibrary = nil
        libraryInitializationError = nil

        let initialGraph = ReadingGraph(
            id: "graph:empty-library",
            version: "library-v2-empty",
            title: "资料库",
            sourceSnapshots: [],
            units: [],
            mapperID: "none",
            mapperVersion: "2",
            generatedAt: .now
        )
        let initialProgress = ReadingProgress.empty
        sources = []
        graph = initialGraph
        progress = initialProgress
        plan = planner.makePlan(
            graph: initialGraph,
            goal: initialProgress.activeGoal,
            progress: initialProgress
        )
        selectedUnitID = nil
        presentation = .markdown

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
            presentation = unit.repositoryFragment != nil ? .markdown : .pdf
        }
        if let pageIndex = unit.pdfFragment?.locator.pdfPageIndex {
            pdfPageIndex = pageIndex
        }
        loadSelectedRepositoryContent()
        if presentation != .markdown {
            loadPDFIfNeeded()
        }
        persistProgress()
    }

    func setPresentation(_ newPresentation: PresentationKind) {
        guard selectedUnit?.availablePresentations.contains(newPresentation) == true else {
            return
        }
        presentation = newPresentation
        if newPresentation != .markdown {
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
        if let pageIndex = fragment.locator.pdfPageIndex {
            pdfPageIndex = pageIndex
            setPresentation(.pdf)
            updatePDFPosition(pageIndex)
        } else {
            setPresentation(.markdown)
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
        if presentation != .markdown {
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
            guard let managedLibrary else {
                notice = AppNotice(
                    title: "资料库不可用",
                    message: libraryInitializationError ?? "托管资料库尚未完成初始化。"
                )
                isImporting = false
                return
            }
            do {
                let result = try await managedLibrary.importLocalSource(at: url)
                let managedURL = result.managedURL
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: managedURL)
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
        defer { isBootstrapComplete = true }
        let rootURL = libraryRootURL
        let bootstrap = await Task.detached(priority: .userInitiated) {
            do {
                let database = try LibraryDatabase(rootURL: rootURL)
                let library = try ManagedLibrary(database: database)
                return LibraryBootstrapResult(
                    database: database,
                    library: library,
                    errorMessage: nil
                )
            } catch {
                return LibraryBootstrapResult(
                    database: nil,
                    library: nil,
                    errorMessage: error.localizedDescription
                )
            }
        }.value
        libraryDatabase = bootstrap.database
        managedLibrary = bootstrap.library
        libraryInitializationError = bootstrap.errorMessage

        if let libraryInitializationError {
            notice = AppNotice(
                title: "资料库未初始化",
                message: libraryInitializationError
            )
            do {
                progress = try await progressStore.load()
                progressPersistenceEnabled = true
            } catch {
                notice = AppNotice(
                    title: "资料库与进度不可用",
                    message: "\(libraryInitializationError)\n\n进度未载入：\(error.localizedDescription)"
                )
                progress = .empty
                progressPersistenceEnabled = false
            }
            rebuildPlan()
            selectedUnitID = nil
            return
        }
        do {
            progress = try await progressStore.load()
            progressPersistenceEnabled = true
        } catch {
            notice = AppNotice(
                title: "进度未载入",
                message: error.localizedDescription
            )
            progress = .empty
            progressPersistenceEnabled = false
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
    }

    private func applyImportedRepository(_ book: RepositoryBook) {
        contentTask?.cancel()
        pdfTask?.cancel()
        activeRepositoryBook = book
        activePDFSnapshot = nil
        pdfDocument = nil
        markdownCache.removeAll()
        sources = [book.source]
        graph = mapper.mapRepositoryBook(
            title: book.source.title,
            repositorySnapshot: book.snapshot,
            chapters: book.chapters,
            pdfSnapshot: nil,
            pdfPageHints: [:]
        )
        presentation = .markdown
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
        guard let path = fragment.locator.relativePath else {
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
        guard pdfDocument == nil || force else {
            return
        }
        isLoadingPDF = false
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
        guard progressPersistenceEnabled else { return }
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
            snapshotID: activePDFSnapshot?.id ?? "\(source.id)@\(revision)",
            adapterID: "onereader.pdf",
            payload: ["pageIndex": String(pageIndex)],
            structuralPath: "page/\(pageIndex)",
            textQuote: nil,
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
            let path = fragment.locator.relativePath
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
            let path = fragment.locator.relativePath
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

private struct LibraryBootstrapResult: Sendable {
    let database: LibraryDatabase?
    let library: ManagedLibrary?
    let errorMessage: String?
}
