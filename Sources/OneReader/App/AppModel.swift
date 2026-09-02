#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Combine
import Foundation
import UniformTypeIdentifiers

struct AppNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

enum ReaderSearchScope: String, CaseIterable, Identifiable, Sendable {
    case source
    case space
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source: "当前来源"
        case .space: "当前空间"
        case .library: "整个资料库"
        }
    }
}

enum AgentRunAttentionKind: Equatable, Sendable {
    case disclosure
    case adapterCandidate
    case interrupted
}

enum PlatformFileImportPurpose: Equatable, Sendable {
    case add(ImportDestination)
    case reauthorize(sourceID: String)

    var allowsMultipleSelection: Bool {
        if case .add = self { return true }
        return false
    }
}

enum OriginalSourceOpenPolicy {
    static func allows(_ url: URL?, onMobile: Bool) -> Bool {
        guard let url else { return false }
        guard onMobile else { return true }
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || scheme == "http"
    }
}

private struct PendingReadingPosition {
    let id: UUID
    let spaceID: String
    let presentationToken: UUID
    let update: ReadingPositionUpdate
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var spaces: [ReadingSpace] = []
    @Published private(set) var sources: [Source] = []
    @Published private(set) var snapshots: [SourceSnapshot] = []
    @Published private(set) var sourceIDsBySpace: [String: [String]] = [:]
    @Published private(set) var progressBySpace: [String: ReadingProgress] = [:]
    @Published private(set) var graphsBySpace: [String: ReadingGraph] = [:]
    @Published private(set) var plansBySpace: [String: ReadingPlanDraft] = [:]
    @Published private(set) var pendingGraphsBySpace: [String: ReadingGraph] = [:]
    @Published private(set) var pendingPlansBySpace: [String: ReadingPlanDraft] = [:]
    @Published private(set) var providerProfiles: [ProviderProfile] = []

    @Published var selectedCollection: LibraryCollection = .allSpaces
    @Published var selectedSpaceID: String?
    @Published var selectedSourceID: String?
    @Published var isReadingWorkspaceOpen = false
    @Published var navigationTab: WorkspaceNavigationTab = .outline
    @Published var inspectorTab: ReaderInspectorTab = .annotations
    @Published var isInspectorPresented = false

    @Published private(set) var adapterPlan: AdapterPlan?
    @Published private(set) var contentNodes: [ContentNode] = []
    @Published private(set) var presentationState: ReaderPresentationState = .empty
    @Published private(set) var currentObservation: Observation?
    @Published private(set) var annotations: [Annotation] = []
    @Published private(set) var history: [ReadingHistoryEntry] = []
    @Published private(set) var activity: [ReaderActivityItem] = []
    @Published private(set) var agentRuns: [AgentRun] = []
    @Published private(set) var evidenceAnswer: EvidenceAnswer?
    @Published var currentSelection: ReaderSelection?
    @Published private(set) var currentPositionLocator: Locator?

    @Published var searchText = ""
    @Published var searchScope: ReaderSearchScope = .space
    @Published private(set) var searchResults: [ContentSearchHit] = []
    @Published private(set) var isSearching = false

    @Published private(set) var pendingImports: [PendingImport] = []
    @Published private(set) var refreshingSourceIDs: Set<String> = []
    @Published var largeImportConfirmation: LargeImportConfirmation?
    @Published var pendingSourceRemoval: Source?
    @Published private(set) var isBootstrapComplete = false
    @Published var isImportSheetPresented = false
    @Published var platformFileImportPurpose: PlatformFileImportPurpose?
    @Published var notice: AppNotice?

    @Published var preferences: ReaderPreferences {
        didSet { Self.save(preferences: preferences, defaults: defaults) }
    }
    @Published private(set) var providerTestInFlightID: String?
    @Published private(set) var providerTestResult: ProviderConnectionTest?

    private let libraryRootURL: URL?
    private let defaults: UserDefaults
    private let presentationRegistry = PresentationRegistry.standard
    private let secretStore: any ProviderSecretStore
    private let agentDriverFactory: any ReadingAgentDriverFactory
    private var database: LibraryDatabase?
    private var managedLibrary: ManagedLibrary?
    private var registry: AdapterRegistry?
    private var coordinator: AdapterCoordinator?
    private var remoteImporter: RemoteSourceImporter?
    private var agentRuntime: ReadingAgentRuntime?

    private var deterministicActivityBySpace: [String: [ReaderActivityItem]] = [:]
    private var contentGeneration = UUID()
    private var workspaceGeneration = UUID()
    private var contentTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var positionSaveTask: Task<Void, Never>?
    private var pendingPositionUpdate: PendingReadingPosition?
    private var importTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var agentTask: Task<Void, Never>?
    private var activeAgentRunID: String?
    private var activeAgentRunSpaceID: String?
    private var indexTasks: [String: Task<Void, Never>] = [:]
    private var indexSnapshotIDs: [String: String] = [:]
    private var indexPlanIDs: [String: String] = [:]
    private var indexGenerations: [String: UUID] = [:]
    private var pendingIndexImportIDs: [String: Set<String>] = [:]

    init(
        libraryRootURL: URL? = nil,
        defaults: UserDefaults = .standard,
        secretStore: any ProviderSecretStore = KeychainProviderSecretStore(),
        agentDriverFactory: any ReadingAgentDriverFactory = DefaultReadingAgentDriverFactory(),
        automaticBootstrap: Bool = true
    ) {
        self.libraryRootURL = libraryRootURL
        self.defaults = defaults
        self.secretStore = secretStore
        self.agentDriverFactory = agentDriverFactory
        preferences = Self.loadPreferences(defaults: defaults)
        if automaticBootstrap {
            Task { [weak self] in
                await self?.bootstrap()
            }
        }
    }

    deinit {
        contentTask?.cancel()
        searchTask?.cancel()
        positionSaveTask?.cancel()
        importTasks.values.forEach { $0.cancel() }
        refreshTasks.values.forEach { $0.cancel() }
        agentTask?.cancel()
        indexTasks.values.forEach { $0.cancel() }
    }

    var visibleSpaces: [ReadingSpace] {
        switch selectedCollection {
        case .allSpaces:
            spaces
        case .recent:
            spaces
                .filter { $0.lastOpenedAt != nil }
                .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        case .processing:
            spaces.filter { space in
                sourceIDs(in: space.id).contains { sourceID in
                    source(id: sourceID)?.managedState == .processing
                } || agentRuns.contains {
                    $0.spaceID == space.id && ($0.state == .queued || $0.state == .running)
                }
            }
        case .favorites:
            spaces.filter { space in
                space.isFavorite || sourceIDs(in: space.id).contains {
                    source(id: $0)?.isFavorite == true
                }
            }
        }
    }

    var selectedSpace: ReadingSpace? {
        guard let selectedSpaceID else { return nil }
        return spaces.first { $0.id == selectedSpaceID }
    }

    var selectedSource: Source? {
        guard let selectedSourceID else { return nil }
        return source(id: selectedSourceID)
    }

    var selectedSnapshot: SourceSnapshot? {
        guard let source = selectedSource,
              let snapshotID = source.latestSnapshotID else { return nil }
        return snapshots.first { $0.id == snapshotID }
    }

    var presentationDocument: PresentationDocument? {
        guard case .ready(let document) = presentationState else { return nil }
        return document
    }

    var presentationDescriptor: PresentationSurfaceDescriptor? {
        presentationDocument.flatMap { presentationRegistry.descriptor(for: $0.surface) }
    }

    var currentGraph: ReadingGraph? {
        selectedSpaceID.flatMap { graphsBySpace[$0] }
    }

    var currentPlan: ReadingPlanDraft? {
        selectedSpaceID.flatMap { plansBySpace[$0] }
    }

    var pendingPlan: ReadingPlanDraft? {
        selectedSpaceID.flatMap { pendingPlansBySpace[$0] }
    }

    var currentProgress: ReadingProgress {
        guard let selectedSpaceID else { return .empty }
        return progressBySpace[selectedSpaceID] ?? .empty
    }

    var currentPresentationToken: UUID {
        contentGeneration
    }

    var currentPositionDescription: String? {
        guard let sourceID = selectedSourceID else { return nil }
        if let pendingPositionUpdate,
           pendingPositionUpdate.spaceID == selectedSpaceID,
           pendingPositionUpdate.update.locator.sourceID == sourceID {
            return pendingPositionUpdate.update.displayLabel
                ?? Self.positionDescription(for: pendingPositionUpdate.update.locator)
        }
        guard let position = currentProgress.sourcePositions[sourceID] else { return nil }
        return position.displayLabel ?? Self.positionDescription(for: position.locator)
    }

    var selectedSpaceSources: [Source] {
        guard let selectedSpaceID else { return [] }
        return sourceIDs(in: selectedSpaceID).compactMap(source(id:))
    }

    var canSearchCurrentPresentation: Bool {
        presentationDescriptor?.supportsFind == true
    }

    var canCreateHighlight: Bool {
        presentationDescriptor?.supportsStructuredHighlight == true
            && currentSelection?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var spaceSupportsSearch: Bool {
        selectedSpaceID.map { capabilityAvailable(.search, in: $0) } == true
    }

    var spaceSupportsAgentEvidence: Bool {
        selectedSpaceID.map { capabilityAvailable(.read, in: $0) } == true
    }

    var availableNavigationTabs: [WorkspaceNavigationTab] {
        WorkspaceNavigationTab.allCases.filter { tab in
            switch tab {
            case .outline, .sources: true
            case .route: spaceSupportsAgentEvidence
            case .search: spaceSupportsSearch
            }
        }
    }

    var availableInspectorTabs: [ReaderInspectorTab] {
        ReaderInspectorTab.allCases.filter { tab in
            switch tab {
            case .annotations, .activity: true
            case .evidence, .ask: spaceSupportsAgentEvidence
            }
        }
    }

    var activeProvider: ProviderProfile? {
        guard let database, let selectedSpaceID else {
            return providerProfiles.first(where: \.isDefault)
        }
        return (try? database.providerProfile(forSpaceID: selectedSpaceID))
    }

    var waitingAgentRun: AgentRun? {
        agentRuns.first { $0.state == .waitingForUser || $0.state == .interrupted }
    }

    var waitingAgentAttentionKind: AgentRunAttentionKind? {
        guard let run = waitingAgentRun else { return nil }
        if run.errorCategory == "disclosure-required" { return .disclosure }
        if let output = try? database?.agentOutput(runID: run.id),
           output.disposition == "waitingForUser",
           case .adapterPlan = output.output {
            return .adapterCandidate
        }
        return run.state == .interrupted ? .interrupted : nil
    }

    var activePendingImportCount: Int {
        pendingImports.filter { $0.state.isActive }.count
    }

    func sourceIDs(in spaceID: String) -> [String] {
        sourceIDsBySpace[spaceID] ?? []
    }

    func source(id: String) -> Source? {
        sources.first { $0.id == id }
    }

    func progressFraction(for spaceID: String) -> Double {
        let progress = progressBySpace[spaceID] ?? .empty
        let sourceIDs = sourceIDs(in: spaceID)
        let sourceFractions = sourceIDs.compactMap {
            progress.sourcePositions[$0]?.progressFraction
        }
        if !sourceFractions.isEmpty, !sourceIDs.isEmpty {
            return sourceFractions.reduce(0, +) / Double(sourceIDs.count)
        }
        guard let graph = graphsBySpace[spaceID], !graph.units.isEmpty else { return 0 }
        let completed = graph.units.reduce(into: 0) { result, unit in
            if progress.state(for: unit.id) == .completed { result += 1 }
        }
        return Double(completed) / Double(graph.units.count)
    }

    func resumeDescription(for spaceID: String) -> String? {
        guard let position = (progressBySpace[spaceID] ?? .empty).sourcePositions.values
            .filter({ sourceIDs(in: spaceID).contains($0.sourceID) })
            .max(by: { $0.updatedAt < $1.updatedAt }),
              let source = source(id: position.sourceID) else { return nil }
        let detail = position.displayLabel ?? Self.positionDescription(for: position.locator)
        return "\(source.displayName) · \(detail)"
    }

    func bootstrap() async {
        guard !isBootstrapComplete else { return }
        do {
            let database = try LibraryDatabase(rootURL: libraryRootURL)
            let managedLibrary = try ManagedLibrary(database: database)
            let registry = try AdapterRegistry.standard()
            let coordinator = AdapterCoordinator(database: database, registry: registry)
            let remoteImporter = RemoteSourceImporter(library: managedLibrary)
            let toolHost = ReadingToolHost(
                database: database,
                coordinator: coordinator,
                registry: registry
            )
            let validator = AgentOutputValidator(database: database, registry: registry)
            let runtime = ReadingAgentRuntime(
                database: database,
                toolHost: toolHost,
                validator: validator,
                secretStore: secretStore,
                driverFactory: agentDriverFactory
            )
            self.database = database
            self.managedLibrary = managedLibrary
            self.registry = registry
            self.coordinator = coordinator
            self.remoteImporter = remoteImporter
            self.agentRuntime = runtime
            try reloadLibraryState()
            try schedulePendingSearchIndexRebuilds()
        } catch {
            notice = AppNotice(title: "资料库无法打开", message: error.localizedDescription)
        }
        isBootstrapComplete = true
    }

    func selectCollection(_ collection: LibraryCollection) {
        selectedCollection = collection
        closeReadingWorkspace()
    }

    func openSpace(_ spaceID: String, preferredSourceID: String? = nil) {
        guard spaces.contains(where: { $0.id == spaceID }) else { return }
        transitionWorkspace(to: spaceID)
        selectedSpaceID = spaceID
        isReadingWorkspaceOpen = true
        navigationTab = .outline
        do {
            try database?.updateSpace(id: spaceID, openedAt: .now)
            try reloadLibraryState(preservingSelection: true)
            try loadSpaceState(spaceID: spaceID)
        } catch {
            notice = AppNotice(title: "无法打开阅读空间", message: error.localizedDescription)
        }
        let progress = progressBySpace[spaceID] ?? .empty
        let mostRecentPositionSourceID = progress.sourcePositions.values
            .filter { sourceIDs(in: spaceID).contains($0.sourceID) }
            .max(by: { $0.updatedAt < $1.updatedAt })?
            .sourceID
        let candidate = preferredSourceID.flatMap { id in
            sourceIDs(in: spaceID).contains(id) ? id : nil
        } ?? mostRecentPositionSourceID ?? sourceIDs(in: spaceID).first
        if let candidate {
            openSource(candidate, locator: progress.sourcePositions[candidate]?.locator)
        } else {
            selectedSourceID = nil
            currentPositionLocator = nil
            presentationState = .empty
        }
    }

    func closeReadingWorkspace() {
        transitionWorkspace(to: nil)
        contentTask?.cancel()
        selectedSpaceID = nil
        selectedSourceID = nil
        currentPositionLocator = nil
        isReadingWorkspaceOpen = false
        presentationState = .empty
    }

    func presentLocalSourceImporter(destination: ImportDestination = .newSpace) {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "添加到 OneReader"
        panel.prompt = "导入"
        panel.message = "选择 PDF、EPUB、Markdown、文本、HTML、代码文件或目录"
        panel.allowedContentTypes = [.item]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.resolvesAliases = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor [weak self] in
                self?.importLocalURLs(panel.urls, destination: destination)
            }
        }
#else
        platformFileImportPurpose = .add(destination)
#endif
    }

    func completePlatformFileImport(_ result: Result<[URL], any Error>) {
        guard let purpose = platformFileImportPurpose else { return }
        platformFileImportPurpose = nil
        switch result {
        case .failure(let error):
            notice = AppNotice(title: "无法读取所选材料", message: error.localizedDescription)
        case .success(let urls):
            switch purpose {
            case .add(let destination):
                importLocalURLs(urls, destination: destination)
            case .reauthorize(let sourceID):
                guard let selectedURL = urls.first,
                      let managedLibrary else { return }
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await managedLibrary.authorizeLocalSource(
                            sourceID: sourceID,
                            selectedURL: selectedURL
                        )
                        refreshSource(sourceID)
                    } catch {
                        notice = AppNotice(
                            title: "无法授权来源",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }
    }

    func importLocalURLs(
        _ urls: [URL],
        destination: ImportDestination = .newSpace,
        allowLargeImport: Bool = false
    ) {
        guard !urls.isEmpty else { return }
        let taskID = UUID()
        importTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer { importTasks[taskID] = nil }
            for url in urls {
                guard !Task.isCancelled else { return }
                await importOne(
                    .local(url),
                    destination: destination,
                    allowLargeImport: allowLargeImport
                )
            }
        }
    }

    func importRemoteURL(
        _ url: URL,
        destination: ImportDestination = .newSpace,
        allowLargeImport: Bool = false
    ) {
        let taskID = UUID()
        importTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer { importTasks[taskID] = nil }
            await importOne(
                .remote(url),
                destination: destination,
                allowLargeImport: allowLargeImport
            )
        }
    }

    func confirmLargeImport() {
        guard let confirmation = largeImportConfirmation else { return }
        largeImportConfirmation = nil
        switch confirmation.request {
        case .local(let url):
            importLocalURLs(
                [url],
                destination: confirmation.destination,
                allowLargeImport: true
            )
        case .remote(let url):
            importRemoteURL(
                url,
                destination: confirmation.destination,
                allowLargeImport: true
            )
        }
    }

    func handleOpenURL(_ url: URL) {
        if url.isFileURL {
            importLocalURLs([url])
        } else if url.scheme?.lowercased() == "https" {
            importRemoteURL(url)
        } else {
            notice = AppNotice(title: "无法打开", message: "OneReader 只接受本地材料或 HTTPS URL。")
        }
    }

    func openSource(_ sourceID: String, locator: Locator? = nil) {
        guard let spaceID = selectedSpaceID,
              sourceIDs(in: spaceID).contains(sourceID),
              let source = source(id: sourceID),
              let snapshotID = source.latestSnapshotID,
              let database,
              let coordinator else { return }

        flushReadingPosition()
        let requestedLocator = locator ?? currentProgress.sourcePositions[sourceID]?.locator
        selectedSourceID = sourceID
        currentPositionLocator = nil
        presentationState = .loading
        currentObservation = nil
        currentSelection = nil
        contentNodes = []
        adapterPlan = nil
        contentTask?.cancel()
        contentGeneration = UUID()
        let generation = contentGeneration
        appendActivity(
            spaceID: spaceID,
            phase: "探测来源",
            message: "正在验证托管快照并选择基础适配器。",
            state: .running
        )

        contentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let plan: AdapterPlan
                if let existing = try database.fetchAdapterPlan(snapshotID: snapshotID) {
                    plan = existing
                } else {
                    plan = try await coordinator.prepare(
                        sourceID: sourceID,
                        snapshotID: snapshotID
                    )
                }
                try Task.checkCancellation()
                let nodes: [ContentNode]
                if plan.capabilityRoutes[.list] != nil {
                    nodes = try await coordinator.list(plan: plan, limit: 2_000)
                } else {
                    nodes = []
                }
                let target = try await resolvedTarget(
                    requestedLocator,
                    plan: plan,
                    nodes: nodes,
                    coordinator: coordinator
                )
                let document = try await coordinator.render(plan: plan, locator: target)
                var observation: Observation?
                if plan.capabilityRoutes[.read] != nil {
                    observation = try? await coordinator.read(
                        plan: plan,
                        locator: document.locator,
                        maxCharacters: 65_536
                    )
                }
                try Task.checkCancellation()
                guard generation == contentGeneration else { return }
                adapterPlan = plan
                contentNodes = nodes
                presentationState = .ready(document)
                currentObservation = observation
                if !availableNavigationTabs.contains(navigationTab) {
                    navigationTab = .outline
                }
                if !availableInspectorTabs.contains(inspectorTab) {
                    inspectorTab = .annotations
                }
                if plan.capabilityRoutes[.search] == nil, searchScope == .source {
                    searchScope = .space
                    searchResults = []
                }
                loadAnnotations()
                recordPositionAndHistory(locator: document.locator)
                appendActivity(
                    spaceID: spaceID,
                    phase: "选择适配器",
                    message: "基础阅读界面已准备好。",
                    state: .completed
                )
                startIndexing(plan: plan, spaceID: spaceID)
            } catch is CancellationError {
                return
            } catch {
                guard generation == contentGeneration else { return }
                presentationState = .unavailable(error.localizedDescription)
                appendActivity(
                    spaceID: spaceID,
                    phase: "选择适配器",
                    message: "基础适配器无法呈现该来源。",
                    state: .failed
                )
            }
        }
    }

    func openNode(_ node: ContentNode) {
        openLocator(node.locator)
    }

    func openLocator(_ locator: Locator) {
        guard let spaceID = selectedSpaceID,
              sourceIDs(in: spaceID).contains(locator.sourceID) else { return }
        openSource(locator.sourceID, locator: locator)
    }

    func openSearchHit(_ hit: ContentSearchHit) {
        if selectedSpaceID.map({ sourceIDs(in: $0).contains(hit.sourceID) }) != true,
           let targetSpaceID = spaces.first(where: {
               sourceIDs(in: $0.id).contains(hit.sourceID)
           })?.id {
            openSpace(targetSpaceID, preferredSourceID: hit.sourceID)
        }
        openLocator(hit.locator)
    }

    func updateReadingPosition(_ locator: Locator) {
        updateReadingPosition(
            Self.inferredPositionUpdate(for: locator),
            presentationToken: currentPresentationToken
        )
    }

    func updateReadingPosition(_ update: ReadingPositionUpdate) {
        updateReadingPosition(update, presentationToken: currentPresentationToken)
    }

    func updateReadingPosition(
        _ update: ReadingPositionUpdate,
        presentationToken: UUID
    ) {
        let locator = update.locator
        guard presentationToken == contentGeneration,
              let spaceID = selectedSpaceID,
              let source = selectedSource,
              source.id == locator.sourceID,
              source.latestSnapshotID == locator.snapshotID else { return }
        let saveID = UUID()
        pendingPositionUpdate = PendingReadingPosition(
            id: saveID,
            spaceID: spaceID,
            presentationToken: presentationToken,
            update: update
        )
        currentPositionLocator = locator
        positionSaveTask?.cancel()
        let generation = workspaceGeneration
        positionSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard let self,
                  generation == workspaceGeneration,
                  presentationToken == contentGeneration,
                  selectedSpaceID == spaceID,
                  selectedSourceID == locator.sourceID,
                  pendingPositionUpdate?.id == saveID else { return }
            pendingPositionUpdate = nil
            positionSaveTask = nil
            persistSourcePosition(update, spaceID: spaceID)
        }
    }

    func flushReadingPosition() {
        positionSaveTask?.cancel()
        positionSaveTask = nil
        guard let pendingPositionUpdate else { return }
        self.pendingPositionUpdate = nil
        let locator = pendingPositionUpdate.update.locator
        guard pendingPositionUpdate.presentationToken == contentGeneration,
              selectedSpaceID == pendingPositionUpdate.spaceID,
              selectedSourceID == locator.sourceID,
              source(id: locator.sourceID)?.latestSnapshotID == locator.snapshotID else {
            return
        }
        persistSourcePosition(
            pendingPositionUpdate.update,
            spaceID: pendingPositionUpdate.spaceID
        )
    }

    func selectPreviousNode() {
        guard let locator = presentationDocument?.locator,
              let index = contentNodeIndex(for: locator),
              index > 0 else { return }
        openNode(contentNodes[index - 1])
    }

    func selectNextNode() {
        guard let locator = presentationDocument?.locator,
              let index = contentNodeIndex(for: locator),
              index + 1 < contentNodes.count else { return }
        openNode(contentNodes[index + 1])
    }

    func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        let generation = workspaceGeneration
        let spaceID = selectedSpaceID
        let scope = searchScope
        let sourcePlan = adapterPlan
        searchTask = Task { [weak self] in
            guard let self, let database else { return }
            do {
                let results: [ContentSearchHit]
                switch scope {
                case .library:
                    results = try database.searchObservations(query: query, limit: 20)
                case .source:
                    guard let plan = sourcePlan, let coordinator else {
                        results = []
                        break
                    }
                    results = try await coordinator.search(plan: plan, query: query, limit: 20)
                case .space:
                    guard let spaceID else {
                        results = []
                        break
                    }
                    results = try await searchSpace(
                        spaceID: spaceID,
                        query: query,
                        limit: 20
                    )
                }
                try Task.checkCancellation()
                guard generation == workspaceGeneration,
                      selectedSpaceID == spaceID else { return }
                searchResults = results
            } catch is CancellationError {
                return
            } catch {
                guard generation == workspaceGeneration,
                      selectedSpaceID == spaceID else { return }
                notice = AppNotice(title: "搜索失败", message: error.localizedDescription)
            }
            if generation == workspaceGeneration, selectedSpaceID == spaceID {
                isSearching = false
            }
        }
    }

    func addBookmark() {
        saveAnnotation(kind: .bookmark, selectedText: nil, note: nil)
    }

    func addHighlight() {
        guard let selection = currentSelection,
              !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saveAnnotation(
            kind: .highlight,
            locator: selection.locator,
            selectedText: selection.text,
            note: nil
        )
    }

    func addNote(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        saveAnnotation(
            kind: .note,
            locator: currentSelection?.locator ?? currentPositionLocator,
            selectedText: currentSelection?.text,
            note: normalized
        )
    }

    func deleteAnnotation(_ annotation: Annotation) {
        guard let database, let spaceID = selectedSpaceID else { return }
        do {
            try database.deleteAnnotation(id: annotation.id, spaceID: spaceID)
            loadAnnotations()
        } catch {
            notice = AppNotice(title: "无法删除标注", message: error.localizedDescription)
        }
    }

    func toggleSpaceFavorite(_ spaceID: String) {
        guard let space = spaces.first(where: { $0.id == spaceID }), let database else { return }
        do {
            try database.updateSpace(id: spaceID, isFavorite: !space.isFavorite)
            try reloadLibraryState(preservingSelection: true)
        } catch {
            notice = AppNotice(title: "无法更新收藏", message: error.localizedDescription)
        }
    }

    func toggleSourceFavorite(_ sourceID: String) {
        guard let source = source(id: sourceID), let database else { return }
        do {
            try database.updateSourceFavorite(id: sourceID, isFavorite: !source.isFavorite)
            try reloadLibraryState(preservingSelection: true)
        } catch {
            notice = AppNotice(title: "无法更新收藏", message: error.localizedDescription)
        }
    }

    func requestSourceRemoval(_ sourceID: String) {
        pendingSourceRemoval = source(id: sourceID)
    }

    func refreshSource(_ sourceID: String) {
        guard refreshTasks[sourceID] == nil,
              let source = source(id: sourceID),
              let managedLibrary,
              let remoteImporter,
              let coordinator,
              let database,
              let agentRuntime else { return }
        refreshingSourceIDs.insert(sourceID)
        refreshTasks[sourceID] = Task { [weak self] in
            guard let self else { return }
            defer {
                refreshingSourceIDs.remove(sourceID)
                refreshTasks[sourceID] = nil
            }
            var candidate: ManagedRefreshCandidate?
            var revisionLease: SourceRevisionRefreshLease?
            var committed = false
            var recoveryLocator: Locator?
            do {
                appendActivityForSource(
                    sourceID: sourceID,
                    phase: "刷新来源",
                    message: "正在保存新的阅读版本。",
                    state: .running
                )
                switch source.originKind {
                case .localFile, .localDirectory:
                    candidate = try await managedLibrary.stageLocalRefresh(sourceID: sourceID)
                case .remoteURL, .githubRepository:
                    candidate = try await remoteImporter.stageRefresh(source: source)
                }
                guard let candidate else { return }
                guard candidate.changed else {
                    appendActivityForSource(
                        sourceID: sourceID,
                        phase: "刷新来源",
                        message: "来源内容没有变化，继续使用当前阅读版本。",
                        state: .completed
                    )
                    return
                }

                recoveryLocator = cancelIndexingForRevision(sourceID: sourceID)
                revisionLease = try await agentRuntime.beginSourceRevisionRefresh(
                    sourceID: sourceID
                )
                let migrations = await sourceRevisionMigrations(
                    candidate: candidate,
                    coordinator: coordinator,
                    database: database
                )
                let generations = try database.commitSnapshotRefreshAndInvalidateRuns(
                    candidate.snapshot,
                    migrations: migrations
                )
                committed = true
                if let revisionLease {
                    await agentRuntime.completeSourceRevisionRefresh(
                        lease: revisionLease,
                        generations: generations
                    )
                }
                revisionLease = nil

                try reloadLibraryState(preservingSelection: true)
                for spaceID in try database.spaceIDs(containing: sourceID) {
                    progressBySpace[spaceID] = try database.fetchReadingProgress(spaceID: spaceID)
                }
                let plan = try await coordinator.prepare(
                    sourceID: sourceID,
                    snapshotID: candidate.snapshot.id
                )
                if let spaceID = selectedSpaceID,
                   sourceIDs(in: spaceID).contains(sourceID) {
                    try loadSpaceState(spaceID: spaceID)
                    startIndexing(plan: plan, spaceID: spaceID)
                    if selectedSourceID == sourceID { openSource(sourceID) }
                }
                appendActivityForSource(
                    sourceID: sourceID,
                    phase: "刷新来源",
                    message: "新阅读版本已保存；旧引用已重新定位或标记为待确认。",
                    state: .completed
                )
                if activeProvider != nil,
                   selectedSpaceID.map({ sourceIDs(in: $0).contains(sourceID) }) == true {
                    launchAgentPipeline()
                }
            } catch is CancellationError {
                if let revisionLease {
                    await agentRuntime.abortSourceRevisionRefresh(lease: revisionLease)
                }
                if let candidate, !committed {
                    try? await managedLibrary.discardRefreshCandidate(candidate)
                }
                restorePresentationAfterRefreshFailure(
                    sourceID: sourceID,
                    previousLocator: recoveryLocator,
                    committed: committed,
                    message: "来源刷新已取消；已恢复可用版本。"
                )
            } catch {
                if let revisionLease {
                    await agentRuntime.abortSourceRevisionRefresh(lease: revisionLease)
                }
                if let candidate, !committed {
                    try? await managedLibrary.discardRefreshCandidate(candidate)
                }
                restorePresentationAfterRefreshFailure(
                    sourceID: sourceID,
                    previousLocator: recoveryLocator,
                    committed: committed,
                    message: committed
                        ? "新阅读版本已保存，但暂时无法呈现。"
                        : "刷新失败；已恢复上一个可用阅读版本。"
                )
                appendActivityForSource(
                    sourceID: sourceID,
                    phase: "刷新来源",
                    message: "来源刷新失败。",
                    state: .failed
                )
                if case LibraryStorageError.sourceAccessRequiresAuthorization = error {
                    presentRefreshReauthorization(for: source)
                } else {
                    notice = AppNotice(
                        title: "无法刷新来源",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func presentRefreshReauthorization(for source: Source) {
#if os(macOS)
        guard let originURL = source.originURL else { return }
        let panel = NSOpenPanel()
        panel.title = "重新授权本地来源"
        panel.prompt = "授权并刷新"
        panel.message = "请选择原来的来源：\(source.displayName)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = source.originKind == .localDirectory
        panel.canChooseFiles = source.originKind == .localFile
        panel.resolvesAliases = false
        panel.directoryURL = originURL.deletingLastPathComponent()
        panel.begin { [weak self] response in
            guard response == .OK, let selectedURL = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self, let managedLibrary else { return }
                do {
                    try await managedLibrary.authorizeLocalSource(
                        sourceID: source.id,
                        selectedURL: selectedURL
                    )
                    refreshSource(source.id)
                } catch {
                    notice = AppNotice(
                        title: "无法授权来源",
                        message: error.localizedDescription
                    )
                }
            }
        }
#else
        platformFileImportPurpose = .reauthorize(sourceID: source.id)
#endif
    }

    func confirmSourceRemoval() {
        guard let source = pendingSourceRemoval else { return }
        pendingSourceRemoval = nil
        removeSource(source.id)
    }

    func dismissPendingImport(_ pendingID: String) {
        removePending(id: pendingID)
    }

    private func removeSource(_ sourceID: String) {
        guard let managedLibrary else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                if let agentRuntime {
                    let lease = try await agentRuntime.beginSourceRevisionRefresh(
                        sourceID: sourceID
                    )
                    do {
                        let generations = try await managedLibrary.removeSource(id: sourceID)
                        await agentRuntime.completeSourceRevisionRefresh(
                            lease: lease,
                            generations: generations
                        )
                    } catch {
                        await agentRuntime.abortSourceRevisionRefresh(lease: lease)
                        throw error
                    }
                } else {
                    _ = try await managedLibrary.removeSource(id: sourceID)
                }
                try reloadLibraryState(preservingSelection: true)
                if let selectedSpaceID {
                    try loadSpaceState(spaceID: selectedSpaceID)
                }
                if selectedSourceID == sourceID {
                    contentTask?.cancel()
                    selectedSourceID = selectedSpaceID.flatMap { sourceIDs(in: $0).first }
                    if let selectedSourceID { openSource(selectedSourceID) }
                    else { presentationState = .empty }
                }
            } catch {
                notice = AppNotice(title: "无法移除来源", message: error.localizedDescription)
            }
        }
    }

    func openOriginalSource() {
        guard canOpenOriginalSource,
              let url = selectedSource?.originURL else { return }
#if os(macOS)
        NSWorkspace.shared.open(url)
#else
        UIApplication.shared.open(url)
#endif
    }

    var canOpenOriginalSource: Bool {
#if os(iOS)
        let onMobile = true
#else
        let onMobile = false
#endif
        return OriginalSourceOpenPolicy.allows(
            selectedSource?.originURL,
            onMobile: onMobile
        )
    }

    func selectReadingUnit(_ unitID: String) {
        guard let graph = currentGraph,
              let unit = graph.units.first(where: { $0.id == unitID }),
              let locator = unit.fragments.first?.locator else { return }
        updateProgress { progress in
            progress.currentUnitID = unitID
            progress.currentPlanStepID = unitID
            if progress.state(for: unitID) == .unseen {
                progress.units[unitID] = UnitProgress(
                    unitID: unitID,
                    state: .reading,
                    fraction: 0.05,
                    updatedAt: .now
                )
            }
        }
        openLocator(locator)
    }

    func markReadingUnitComplete(_ unitID: String) {
        updateProgress { progress in
            progress.units[unitID] = UnitProgress(
                unitID: unitID,
                state: .completed,
                fraction: 1,
                updatedAt: .now
            )
            progress.currentPlanStepID = unitID
        }
    }

    func adoptPendingReadingPlan() {
        guard let database,
              let spaceID = selectedSpaceID,
              let graph = pendingGraphsBySpace[spaceID],
              let plan = pendingPlansBySpace[spaceID],
              graph.id == plan.graphID,
              graph.version == plan.graphVersion else { return }
        var progress = progressBySpace[spaceID] ?? .empty
        let validUnitIDs = Set(graph.units.map(\.id))
        progress.units = progress.units.filter { validUnitIDs.contains($0.key) }
        if progress.currentUnitID.map({ !validUnitIDs.contains($0) }) == true {
            progress.currentUnitID = nil
        }
        if progress.currentPlanStepID.map({ !validUnitIDs.contains($0) }) != false {
            progress.currentPlanStepID = plan.orderedUnitIDs.first
        }
        progress.graphVersion = graph.version
        if let goal = ReadingGoal(rawValue: plan.goal) {
            progress.activeGoal = goal
        }
        progress.lastActiveAt = .now
        do {
            try database.saveReadingProgress(progress, spaceID: spaceID)
            progressBySpace[spaceID] = progress
            graphsBySpace[spaceID] = graph
            plansBySpace[spaceID] = plan
            pendingGraphsBySpace[spaceID] = nil
            pendingPlansBySpace[spaceID] = nil
        } catch {
            notice = AppNotice(title: "无法切换阅读路线", message: error.localizedDescription)
        }
    }

    func launchAgentPipeline() {
        guard spaceSupportsAgentEvidence else {
            notice = AppNotice(
                title: "当前空间没有可引用正文",
                message: "系统预览材料只支持整份材料的书签和笔记，暂时不能生成阅读结构。"
            )
            return
        }
        guard activeProvider != nil else {
            inspectorTab = .activity
            isInspectorPresented = true
            notice = AppNotice(
                title: "尚未配置模型",
                message: "基础阅读不需要模型；若要生成阅读结构与路线，请先在设置中配置并测试模型服务。"
            )
            return
        }
        agentTask?.cancel()
        guard let spaceID = selectedSpaceID else { return }
        let generation = workspaceGeneration
        agentTask = Task { [weak self] in
            await self?.executeAgentPipeline(spaceID: spaceID, generation: generation)
        }
    }

    func askAgent(_ question: String) {
        let normalized = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let spaceID = selectedSpaceID else { return }
        guard spaceSupportsAgentEvidence else {
            notice = AppNotice(
                title: "当前空间不支持证据问答",
                message: "至少需要一份能够读取正文并保存精确位置的材料。"
            )
            return
        }
        guard activeProvider != nil else {
            notice = AppNotice(title: "尚未配置模型", message: "请先在设置中配置模型服务。")
            return
        }
        evidenceAnswer = nil
        agentTask?.cancel()
        agentTask = Task { [weak self] in
            _ = await self?.runAgentTask(
                .answerWithEvidence,
                spaceID: spaceID,
                question: normalized
            )
        }
    }

    func cancelAgentRun() {
        let runID = activeAgentRunID ?? agentRuns.first {
            $0.state == .queued || $0.state == .running
        }?.id
        let spaceID = activeAgentRunSpaceID ?? selectedSpaceID
        agentTask?.cancel()
        guard let runtime = agentRuntime, let spaceID, let runID else { return }
        Task {
            if let session = try? await runtime.session(forSpaceID: spaceID) {
                await session.cancel(runID: runID)
            }
            loadAgentActivity(spaceID: spaceID)
        }
    }

    func confirmWaitingAgentRun() {
        guard let run = waitingAgentRun,
              let database,
              let runtime = agentRuntime,
              let attentionKind = waitingAgentAttentionKind,
              let request = try? database.request(forRunID: run.id) else { return }
        let generation = workspaceGeneration
        agentTask?.cancel()
        agentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await runtime.session(forSpaceID: run.spaceID)
                let resumedState: AgentRunState
                switch attentionKind {
                case .disclosure:
                    try database.acknowledgeRemoteDisclosure(runID: run.id)
                    let handle = try await session.resume(runID: run.id)
                    await consume(
                        handle: handle,
                        spaceID: run.spaceID,
                        generation: generation
                    )
                    resumedState = try database.agentRunState(runID: handle.runID) ?? .failed
                case .adapterCandidate:
                    _ = try await session.confirmAdapterCandidate(runID: run.id)
                    loadAgentActivity(spaceID: run.spaceID)
                    if selectedSpaceID == run.spaceID, let selectedSourceID {
                        openSource(selectedSourceID)
                    }
                    resumedState = .completed
                case .interrupted:
                    let handle = try await session.resume(runID: run.id)
                    await consume(
                        handle: handle,
                        spaceID: run.spaceID,
                        generation: generation
                    )
                    resumedState = try database.agentRunState(runID: handle.runID) ?? .failed
                }
                guard selectedSpaceID == run.spaceID,
                      workspaceGeneration == generation,
                      resumedState == .completed else { return }
                startIndexingAdapterPlan(for: request, spaceID: run.spaceID)
                await continueAgentPipeline(
                    after: request,
                    spaceID: run.spaceID,
                    generation: generation
                )
            } catch {
                if selectedSpaceID == run.spaceID {
                    notice = AppNotice(title: "无法继续阅读辅助任务", message: error.localizedDescription)
                }
            }
        }
    }

    func dismissWaitingAgentRun() {
        guard let run = waitingAgentRun,
              waitingAgentAttentionKind == .adapterCandidate,
              let database,
              let request = try? database.request(forRunID: run.id),
              let runtime = agentRuntime else { return }
        let generation = workspaceGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await runtime.session(forSpaceID: run.spaceID)
                try await session.dismissAdapterCandidate(runID: run.id)
                loadAgentActivity(spaceID: run.spaceID)
                await continueAgentPipeline(
                    after: request,
                    spaceID: run.spaceID,
                    generation: generation
                )
            } catch {
                if selectedSpaceID == run.spaceID {
                    notice = AppNotice(title: "无法保留基础方案", message: error.localizedDescription)
                }
            }
        }
    }

    func abandonInterruptedAgentRun() {
        guard let run = waitingAgentRun,
              waitingAgentAttentionKind == .interrupted,
              let runtime = agentRuntime else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await runtime.session(forSpaceID: run.spaceID)
                try await session.abandon(runID: run.id)
                loadAgentActivity(spaceID: run.spaceID)
            } catch {
                if selectedSpaceID == run.spaceID {
                    notice = AppNotice(title: "无法放弃阅读辅助任务", message: error.localizedDescription)
                }
            }
        }
    }

    func saveProviderProfile(_ profile: ProviderProfile, secret: String?) {
        guard let database else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                var revised = profile
                if let secret,
                   !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    revised.keychainReference = try await secretStore.save(
                        secret: secret,
                        reference: profile.keychainReference
                    )
                }
                if revised.kind.requiresSecret, revised.keychainReference == nil {
                    throw ReadingAgentError.secretMissing
                }
                try database.saveProviderProfile(revised)
                providerProfiles = try database.fetchProviderProfiles()
                refreshSelectedAgentActivityAfterProviderMutation()
            } catch {
                notice = AppNotice(title: "无法保存模型服务", message: error.localizedDescription)
            }
        }
    }

    func testProvider(_ profile: ProviderProfile, secret: String?) {
        guard let database else { return }
        providerTestInFlightID = profile.id
        providerTestResult = nil
        Task { [weak self] in
            guard let self else { return }
            let hasUnsavedSecret = secret?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            var effectiveSecret = secret
            if effectiveSecret?.isEmpty != false,
               let reference = profile.keychainReference {
                effectiveSecret = try? await secretStore.secret(for: reference)
            }
            let tester = ProviderConnectionTester(database: database)
            let savedProfile = (try? database.fetchProviderProfiles())?
                .first(where: { $0.id == profile.id })
            let shouldPersist = ProviderConnectionTester.shouldPersistResult(
                draft: profile,
                saved: savedProfile,
                hasUnsavedSecret: hasUnsavedSecret
            )
            let result = await tester.test(
                profile: profile,
                secret: effectiveSecret,
                persistResult: shouldPersist
            )
            providerTestResult = result
            providerTestInFlightID = nil
            providerProfiles = (try? database.fetchProviderProfiles()) ?? providerProfiles
            refreshSelectedAgentActivityAfterProviderMutation()
        }
    }

    func setProviderOverride(_ profileID: String?) {
        guard let database, let spaceID = selectedSpaceID else { return }
        do {
            try database.setProviderOverride(profileID: profileID, forSpaceID: spaceID)
            refreshSelectedAgentActivityAfterProviderMutation(affecting: spaceID)
        } catch {
            notice = AppNotice(title: "无法切换模型服务", message: error.localizedDescription)
        }
    }

#if os(macOS)
    func resizeMainWindow(width: CGFloat, height: CGFloat) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        var frame = window.frame
        frame.size = NSSize(width: width, height: height)
        if let screen = window.screen {
            frame.origin.x = screen.visibleFrame.midX - width / 2
            frame.origin.y = screen.visibleFrame.midY - height / 2
        }
        window.setFrame(
            frame,
            display: true,
            animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
#endif

    private func importOne(
        _ request: ReaderImportRequest,
        destination: ImportDestination,
        allowLargeImport: Bool
    ) async {
        guard let managedLibrary, let remoteImporter else {
            notice = AppNotice(title: "资料库尚未就绪", message: "请稍后重试。")
            return
        }
        var pending = PendingImport(displayName: request.displayName, state: .copying)
        pendingImports.append(pending)
        let destinationSpaceID = destination == .currentSpace ? selectedSpaceID : nil
        do {
            let result: ManagedImportResult
            switch request {
            case .local(let url):
                result = try await managedLibrary.importLocalSource(
                    at: url,
                    intoSpaceID: destinationSpaceID,
                    allowLargeImport: allowLargeImport
                )
            case .remote(let url):
                result = try await remoteImporter.importSource(
                    from: url,
                    intoSpaceID: destinationSpaceID,
                    allowLargeImport: allowLargeImport
                )
            }
            pending.state = .adapting
            replacePending(pending)
            try reloadLibraryState(preservingSelection: true)
            openSpace(result.space.id, preferredSourceID: result.source.id)
            isImportSheetPresented = false
            if let authorizationWarning = result.authorizationWarning {
                appendActivity(
                    spaceID: result.space.id,
                    phase: "来源授权",
                    message: authorizationWarning,
                    state: .attention
                )
            }
            pending.state = .indexing
            replacePending(pending)
            if let coordinator {
                let plan = try await coordinator.prepare(
                    sourceID: result.source.id,
                    snapshotID: result.snapshot.id
                )
                startIndexing(plan: plan, spaceID: result.space.id, pendingID: pending.id)
            } else {
                removePending(id: pending.id)
            }
            if activeProvider != nil {
                launchAgentPipeline()
            }
        } catch let error as LibraryStorageError {
            if case .largeImportRequiresConfirmation(let byteCount) = error,
               !allowLargeImport {
                removePending(id: pending.id)
                largeImportConfirmation = LargeImportConfirmation(
                    request: request,
                    destination: destination,
                    byteCount: byteCount
                )
                return
            }
            pending.state = .failed(error.localizedDescription)
            replacePending(pending)
            notice = AppNotice(title: "导入失败", message: error.localizedDescription)
        } catch is CancellationError {
            removePending(id: pending.id)
        } catch {
            pending.state = .failed(error.localizedDescription)
            replacePending(pending)
            notice = AppNotice(title: "导入失败", message: error.localizedDescription)
        }
    }

    private func startIndexing(
        plan: AdapterPlan,
        spaceID: String,
        pendingID: String? = nil
    ) {
        guard plan.capabilityRoutes[.search] != nil else {
            if let pendingID { removePending(id: pendingID) }
            return
        }
        if indexTasks[plan.sourceID] != nil,
           indexSnapshotIDs[plan.sourceID] == plan.snapshotID,
           indexPlanIDs[plan.sourceID] == plan.id {
            if let pendingID {
                pendingIndexImportIDs[plan.sourceID, default: []].insert(pendingID)
            }
            return
        }
        if indexTasks[plan.sourceID] != nil {
            indexTasks[plan.sourceID]?.cancel()
            finishPendingIndexImports(sourceID: plan.sourceID)
        }
        if let pendingID {
            pendingIndexImportIDs[plan.sourceID, default: []].insert(pendingID)
        }
        if pendingID == nil,
           (try? database?.isObservationIndexComplete(
               snapshotID: plan.snapshotID,
               planID: plan.id
           )) == true {
            return
        }

        let generation = UUID()
        indexGenerations[plan.sourceID] = generation
        indexSnapshotIDs[plan.sourceID] = plan.snapshotID
        indexPlanIDs[plan.sourceID] = plan.id
        appendActivity(
            spaceID: spaceID,
            phase: "建索引",
            message: "正在后台建立可搜索观察索引。",
            state: .running
        )
        indexTasks[plan.sourceID] = Task { [weak self] in
            guard let self, let coordinator else { return }
            var outcome: ReaderActivityItem.State?
            do {
                try await coordinator.index(plan: plan)
                outcome = .completed
            } catch is CancellationError {
                // A newer Snapshot or app teardown owns the next state.
            } catch {
                outcome = .attention
            }
            guard indexGenerations[plan.sourceID] == generation else { return }
            if let outcome {
                appendActivity(
                    spaceID: spaceID,
                    phase: "建索引",
                    message: outcome == .completed
                        ? "全文索引已就绪。"
                        : "索引未完成；基础阅读仍可使用。",
                    state: outcome
                )
            }
            finishPendingIndexImports(sourceID: plan.sourceID)
            indexTasks[plan.sourceID] = nil
            indexSnapshotIDs[plan.sourceID] = nil
            indexPlanIDs[plan.sourceID] = nil
            indexGenerations[plan.sourceID] = nil
        }
    }

    private func finishPendingIndexImports(sourceID: String) {
        let ids = pendingIndexImportIDs.removeValue(forKey: sourceID) ?? []
        pendingImports.removeAll { ids.contains($0.id) }
    }

    private func contentNodeIndex(for locator: Locator) -> Int? {
        contentNodes.firstIndex { node in
            let candidate = node.locator
            guard candidate.sourceID == locator.sourceID,
                  candidate.snapshotID == locator.snapshotID,
                  candidate.adapterID == locator.adapterID else { return false }
            if candidate == locator { return true }
            if let page = locator.pdfPageIndex {
                return candidate.pdfPageIndex == page
            }
            if let path = locator.relativePath {
                return candidate.relativePath == path
            }
            return candidate.structuralPath == locator.structuralPath
                && candidate.structuralPath != nil
        }
    }

    private func resolvedTarget(
        _ requested: Locator?,
        plan: AdapterPlan,
        nodes: [ContentNode],
        coordinator: AdapterCoordinator
    ) async throws -> Locator? {
        guard let requested else {
            return preferredDefaultNode(in: nodes)?.locator
        }
        guard requested.snapshotID != plan.snapshotID else { return requested }
        let resolution = try await coordinator.resolve(requested, against: plan.snapshotID)
        switch resolution.state {
        case .current, .relocated:
            return resolution.resolved
        case .orphaned:
            throw AdapterError.invalidLocator("旧引用在当前阅读版本中无法恢复")
        }
    }

    private func preferredDefaultNode(in nodes: [ContentNode]) -> ContentNode? {
        nodes
            .filter(\.isReadable)
            .min { lhs, rhs in
                Self.defaultNodeRank(lhs) < Self.defaultNodeRank(rhs)
            }
    }

    private static func defaultNodeRank(_ node: ContentNode) -> (Int, Int, String) {
        let path = node.locator.relativePath ?? node.title
        let components = path.split(separator: "/")
        let name = components.last.map(String.init)?.lowercased() ?? path.lowercased()
        let preferred: [String: Int] = [
            "readme.md": 0,
            "readme.markdown": 1,
            "readme": 2,
            "index.md": 3,
            "index.html": 4,
            "summary.md": 5,
            "toc.md": 6,
        ]
        return (preferred[name] ?? 100, components.count, path.lowercased())
    }

    private func searchSpace(
        spaceID: String,
        query: String,
        limit: Int
    ) async throws -> [ContentSearchHit] {
        guard let coordinator, let database else { return [] }
        var results: [ContentSearchHit] = []
        for sourceID in sourceIDs(in: spaceID) {
            try Task.checkCancellation()
            guard let source = source(id: sourceID), let snapshotID = source.latestSnapshotID else {
                continue
            }
            let plan: AdapterPlan
            if let existing = try database.fetchAdapterPlan(snapshotID: snapshotID) {
                plan = existing
            } else {
                plan = try await coordinator.prepare(
                    sourceID: sourceID,
                    snapshotID: snapshotID
                )
            }
            guard plan.capabilityRoutes[.search] != nil else { continue }
            let remaining = max(1, limit - results.count)
            results.append(contentsOf: try await coordinator.search(
                plan: plan,
                query: query,
                limit: remaining
            ))
            if results.count >= limit { break }
        }
        return Array(results.sorted { $0.rank > $1.rank }.prefix(limit))
    }

    private func saveAnnotation(
        kind: AnnotationKind,
        locator explicitLocator: Locator? = nil,
        selectedText: String?,
        note: String?
    ) {
        guard let database,
              let spaceID = selectedSpaceID,
              let source = selectedSource,
              let snapshot = selectedSnapshot,
              let document = presentationDocument else { return }
        let locator: Locator
        if let explicitLocator {
            locator = explicitLocator
        } else if document.surface == .quickLook {
            locator = Locator(
                sourceID: source.id,
                snapshotID: snapshot.id,
                adapterID: document.locator.adapterID,
                payload: [:],
                structuralPath: nil,
                textQuote: nil,
                fingerprint: snapshot.digest
            )
        } else {
            locator = currentPositionLocator ?? document.locator
        }
        let annotation = Annotation(
            id: UUID().uuidString.lowercased(),
            spaceID: spaceID,
            sourceID: source.id,
            snapshotID: snapshot.id,
            kind: kind,
            locator: locator,
            anchorState: .current,
            selectedText: selectedText,
            note: note,
            color: kind == .highlight ? "yellow" : nil,
            createdAt: .now,
            updatedAt: .now
        )
        do {
            try database.saveAnnotation(annotation)
            loadAnnotations()
            inspectorTab = .annotations
            isInspectorPresented = true
        } catch {
            notice = AppNotice(title: "无法保存标注", message: error.localizedDescription)
        }
    }

    private func loadAnnotations() {
        guard let database, let spaceID = selectedSpaceID else {
            annotations = []
            return
        }
        do {
            annotations = try database.fetchAnnotations(spaceID: spaceID)
        } catch {
            notice = AppNotice(title: "无法读取标注", message: error.localizedDescription)
        }
    }

    private func recordPositionAndHistory(locator: Locator) {
        guard let database, let spaceID = selectedSpaceID else { return }
        currentPositionLocator = locator
        let existing = currentProgress.sourcePositions[locator.sourceID]
        if var existing, existing.locator == locator {
            // The exact position is already durable. In particular, a relocated
            // position intentionally has no fraction or label until the new
            // presentation measures the revised content.
            existing.updatedAt = .now
            persistSourcePosition(existing, spaceID: spaceID)
        } else {
            persistSourcePosition(
                Self.inferredPositionUpdate(for: locator),
                spaceID: spaceID
            )
        }
        let entry = ReadingHistoryEntry(
            spaceID: spaceID,
            sourceID: locator.sourceID,
            snapshotID: locator.snapshotID,
            locator: locator
        )
        do {
            try database.recordReadingHistory(entry)
            history = try database.fetchReadingHistory(spaceID: spaceID, limit: 100)
        } catch {
            // A failed history write must never make the current presentation unreadable.
        }
    }

    private func persistSourcePosition(_ update: ReadingPositionUpdate, spaceID: String) {
        let locator = update.locator
        persistSourcePosition(
            SourcePosition(
                sourceID: locator.sourceID,
                locator: locator,
                updatedAt: .now,
                progressFraction: update.progressFraction,
                granularity: update.granularity,
                displayLabel: update.displayLabel
            ),
            spaceID: spaceID
        )
    }

    private func persistSourcePosition(_ position: SourcePosition, spaceID: String) {
        guard let database else { return }
        var progress = progressBySpace[spaceID] ?? .empty
        progress.sourcePositions[position.sourceID] = position
        progress.lastActiveAt = .now
        do {
            try database.saveReadingProgress(progress, spaceID: spaceID)
            progressBySpace[spaceID] = progress
        } catch {
            notice = AppNotice(title: "无法保存阅读位置", message: error.localizedDescription)
        }
    }

    private func transitionWorkspace(to _: String?) {
        flushReadingPosition()
        workspaceGeneration = UUID()
        contentGeneration = UUID()
        contentTask?.cancel()
        searchTask?.cancel()
        positionSaveTask?.cancel()
        agentTask?.cancel()
        currentSelection = nil
        currentPositionLocator = nil
        evidenceAnswer = nil
        searchResults = []
        isSearching = false
        // Cancelling the consumer terminates its AsyncStream. The Session then
        // cancels only the run that owns that stream ID, so a late A→B switch
        // can never cancel a newer run after the user returns to A.
    }

    private func updateProgress(_ mutation: (inout ReadingProgress) -> Void) {
        guard let database, let spaceID = selectedSpaceID else { return }
        var progress = progressBySpace[spaceID] ?? .empty
        mutation(&progress)
        progress.lastActiveAt = .now
        do {
            try database.saveReadingProgress(progress, spaceID: spaceID)
            progressBySpace[spaceID] = progress
        } catch {
            notice = AppNotice(title: "无法保存阅读进度", message: error.localizedDescription)
        }
    }

    private func executeAgentPipeline(
        spaceID: String,
        generation: UUID,
        routingAfterSourceID: String? = nil
    ) async {
        guard selectedSpaceID == spaceID,
              workspaceGeneration == generation,
              let database else { return }
        let manifest: [String: String]
        do {
            manifest = try database.currentSnapshotManifest(spaceID: spaceID)
        } catch {
            if selectedSpaceID == spaceID, workspaceGeneration == generation {
                notice = AppNotice(title: "阅读辅助无法启动", message: error.localizedDescription)
            }
            return
        }

        let orderedSourceIDs = manifest.keys.sorted()
        let sourceIDsToRoute: ArraySlice<String>
        if let routingAfterSourceID,
           let index = orderedSourceIDs.firstIndex(of: routingAfterSourceID) {
            sourceIDsToRoute = orderedSourceIDs[orderedSourceIDs.index(after: index)...]
        } else {
            sourceIDsToRoute = orderedSourceIDs[...]
        }
        for sourceID in sourceIDsToRoute {
            guard selectedSpaceID == spaceID,
                  workspaceGeneration == generation,
                  let snapshotID = manifest[sourceID] else { return }
            let installed = try? database.fetchAdapterPlan(snapshotID: snapshotID)
            if installed?.isUserOverride == true
                || installed?.id.hasPrefix("agent-adapter-plan:") == true {
                continue
            }
            let state = await runAgentTask(
                .routeAdapters,
                spaceID: spaceID,
                pipeline: .readingStructure,
                targetSourceID: sourceID,
                targetSnapshotID: snapshotID,
                generation: generation
            )
            guard state == .completed else { return }
        }

        if selectedSpaceID == spaceID,
           workspaceGeneration == generation,
           let selectedSourceID,
           manifest[selectedSourceID] != nil {
            openSource(selectedSourceID)
        }
        await executeDownstreamAgentPipeline(spaceID: spaceID, generation: generation)
    }

    private func executeDownstreamAgentPipeline(
        spaceID: String,
        generation: UUID
    ) async {
        guard selectedSpaceID == spaceID,
              workspaceGeneration == generation else { return }
        guard await runAgentTask(
            .scoutSpace,
            spaceID: spaceID,
            pipeline: .readingStructure,
            generation: generation
        ) == .completed else { return }
        await executeAgentPipelineAfterScout(spaceID: spaceID, generation: generation)
    }

    private func executeAgentPipelineAfterScout(
        spaceID: String,
        generation: UUID
    ) async {
        guard await runAgentTask(
            .materializeGraph,
            spaceID: spaceID,
            pipeline: .readingStructure,
            generation: generation
        ) == .completed else { return }
        await executeAgentPipelineAfterMaterialize(spaceID: spaceID, generation: generation)
    }

    private func executeAgentPipelineAfterMaterialize(
        spaceID: String,
        generation: UUID
    ) async {
        _ = await runAgentTask(
            .projectRoute,
            spaceID: spaceID,
            pipeline: .readingStructure,
            goal: "systematic",
            generation: generation
        )
    }

    private func continueAgentPipeline(
        after request: AgentRunRequest,
        spaceID: String,
        generation: UUID
    ) async {
        guard request.pipeline == .readingStructure else { return }
        switch request.task {
        case .routeAdapters:
            await executeAgentPipeline(
                spaceID: spaceID,
                generation: generation,
                routingAfterSourceID: request.targetSourceID
            )
        case .scoutSpace:
            await executeAgentPipelineAfterScout(spaceID: spaceID, generation: generation)
        case .materializeGraph:
            await executeAgentPipelineAfterMaterialize(spaceID: spaceID, generation: generation)
        case .projectRoute, .answerWithEvidence:
            return
        }
    }

    private func scheduleDownstreamAgentPipeline(for spaceID: String) {
        guard selectedSpaceID == spaceID, activeProvider != nil else { return }
        let generation = workspaceGeneration
        agentTask = Task { [weak self] in
            await self?.executeDownstreamAgentPipeline(
                spaceID: spaceID,
                generation: generation
            )
        }
    }

    private func runAgentTask(
        _ kind: AgentTaskKind,
        spaceID: String,
        pipeline: AgentPipelineKind? = nil,
        goal: String? = nil,
        question: String? = nil,
        targetSourceID: String? = nil,
        targetSnapshotID: String? = nil,
        generation: UUID? = nil
    ) async -> AgentRunState? {
        guard let database, let runtime = agentRuntime else { return nil }
        let uiGeneration = generation ?? workspaceGeneration
        guard selectedSpaceID == spaceID,
              workspaceGeneration == uiGeneration else { return .cancelled }
        do {
            let manifest = try database.currentSnapshotManifest(spaceID: spaceID)
            let request = AgentRunRequest(
                spaceID: spaceID,
                task: kind,
                pipeline: pipeline,
                goal: goal,
                question: question,
                targetSourceID: targetSourceID,
                targetSnapshotID: targetSnapshotID,
                expectedSnapshotIDs: Set(manifest.values),
                snapshotManifest: manifest
            )
            let session = try await runtime.session(forSpaceID: spaceID)
            let handle = try await session.start(request)
            await consume(handle: handle, spaceID: spaceID, generation: uiGeneration)
            let state = try database.agentRunState(runID: handle.runID)
            if state == .completed {
                startIndexingAdapterPlan(for: request, spaceID: spaceID)
            }
            return state
        } catch is CancellationError {
            return .cancelled
        } catch {
            if selectedSpaceID == spaceID, workspaceGeneration == uiGeneration {
                loadAgentActivity(spaceID: spaceID)
            }
            if !(error is ReadingAgentError),
               selectedSpaceID == spaceID,
               workspaceGeneration == uiGeneration {
                notice = AppNotice(title: "阅读辅助任务失败", message: error.localizedDescription)
            }
            return nil
        }
    }

    private func consume(
        handle: AgentRunHandle,
        spaceID: String,
        generation: UUID
    ) async {
        activeAgentRunID = handle.runID
        activeAgentRunSpaceID = spaceID
        defer {
            if activeAgentRunID == handle.runID {
                activeAgentRunID = nil
                activeAgentRunSpaceID = nil
            }
        }
        do {
            for try await _ in handle.events {
                if selectedSpaceID == spaceID, workspaceGeneration == generation {
                    loadAgentActivity(spaceID: spaceID)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            if selectedSpaceID == spaceID, workspaceGeneration == generation {
                loadAgentActivity(spaceID: spaceID)
            }
        }
        guard let database else { return }
        guard selectedSpaceID == spaceID,
              workspaceGeneration == generation else { return }
        if let output = try? database.agentOutput(runID: handle.runID)?.output,
           case .evidenceAnswer(let answer) = output {
            evidenceAnswer = answer
            inspectorTab = .ask
            isInspectorPresented = true
        }
        try? refreshReadingStructureState(spaceID: spaceID)
        loadAgentActivity(spaceID: spaceID)
    }

    private func appendActivity(
        spaceID: String,
        phase: String,
        message: String,
        state: ReaderActivityItem.State
    ) {
        deterministicActivityBySpace[spaceID, default: []].append(
            ReaderActivityItem(phase: phase, message: message, state: state)
        )
        if selectedSpaceID == spaceID { loadAgentActivity(spaceID: spaceID) }
    }

    private func schedulePendingSearchIndexRebuilds() throws {
        guard let database else { return }
        let plans = try database.adapterPlansRequiringSearchIndex()
        for plan in plans {
            guard let spaceID = try database.spaceIDs(containing: plan.sourceID).first else {
                continue
            }
            startIndexing(plan: plan, spaceID: spaceID)
        }
    }

    private func startIndexingAdapterPlan(
        for request: AgentRunRequest,
        spaceID: String
    ) {
        guard request.task == .routeAdapters,
              let sourceID = request.targetSourceID,
              let snapshotID = request.targetSnapshotID,
              let plan = try? database?.fetchAdapterPlan(snapshotID: snapshotID),
              plan.sourceID == sourceID,
              plan.snapshotID == snapshotID else { return }
        startIndexing(plan: plan, spaceID: spaceID)
    }

    private func appendActivityForSource(
        sourceID: String,
        phase: String,
        message: String,
        state: ReaderActivityItem.State
    ) {
        guard let database else { return }
        let spaceIDs = (try? database.spaceIDs(containing: sourceID)) ?? []
        for spaceID in spaceIDs {
            appendActivity(
                spaceID: spaceID,
                phase: phase,
                message: message,
                state: state
            )
        }
    }

    private func cancelIndexingForRevision(sourceID: String) -> Locator? {
        indexTasks[sourceID]?.cancel()
        indexTasks[sourceID] = nil
        indexSnapshotIDs[sourceID] = nil
        indexPlanIDs[sourceID] = nil
        indexGenerations[sourceID] = UUID()
        finishPendingIndexImports(sourceID: sourceID)
        if selectedSourceID == sourceID {
            flushReadingPosition()
            let recoveryLocator = currentProgress.sourcePositions[sourceID]?.locator
                ?? currentPositionLocator
                ?? presentationDocument?.locator
            contentGeneration = UUID()
            contentTask?.cancel()
            presentationState = .loading
            currentObservation = nil
            currentSelection = nil
            currentPositionLocator = nil
            contentNodes = []
            adapterPlan = nil
            return recoveryLocator
        }
        return nil
    }

    private func restorePresentationAfterRefreshFailure(
        sourceID: String,
        previousLocator: Locator?,
        committed: Bool,
        message: String
    ) {
        guard selectedSourceID == sourceID else { return }
        presentationState = .unavailable(message)
        if committed {
            do {
                try reloadLibraryState(preservingSelection: true)
                if let spaceID = selectedSpaceID {
                    try loadSpaceState(spaceID: spaceID)
                }
                guard source(id: sourceID)?.latestSnapshotID != nil else { return }
                openSource(sourceID)
            } catch {
                presentationState = .unavailable(message)
            }
        } else if source(id: sourceID)?.latestSnapshotID != nil {
            openSource(sourceID, locator: previousLocator)
        }
    }

    private func sourceRevisionMigrations(
        candidate: ManagedRefreshCandidate,
        coordinator: AdapterCoordinator,
        database: LibraryDatabase
    ) async -> SourceRevisionMigrationBatch {
        let spaceIDs = (try? database.spaceIDs(containing: candidate.source.id)) ?? []
        var annotationMigrations: [AnnotationRevisionMigration] = []
        var positionMigrations: [SourcePositionRevisionMigration] = []
        for spaceID in spaceIDs {
            let sourceAnnotations = (try? database.fetchAnnotations(
                spaceID: spaceID,
                sourceID: candidate.source.id
            )) ?? []
            for annotation in sourceAnnotations {
                let resolution = try? await coordinator.resolveStaged(
                    annotation.locator,
                    source: candidate.source,
                    snapshot: candidate.snapshot,
                    managedURL: candidate.managedURL
                )
                let state: AnnotationAnchorState = resolution?.resolved == nil
                    ? .orphaned
                    : .relocated
                annotationMigrations.append(
                    AnnotationRevisionMigration(
                        annotationID: annotation.id,
                        state: state
                    )
                )
            }
            guard let progress = try? database.fetchReadingProgress(spaceID: spaceID),
                  let position = progress.sourcePositions[candidate.source.id] else { continue }
            let resolution = try? await coordinator.resolveStaged(
                position.locator,
                source: candidate.source,
                snapshot: candidate.snapshot,
                managedURL: candidate.managedURL
            )
            positionMigrations.append(
                SourcePositionRevisionMigration(
                    spaceID: spaceID,
                    sourceID: candidate.source.id,
                    resolvedLocator: resolution?.resolved
                )
            )
        }
        return SourceRevisionMigrationBatch(
            annotations: annotationMigrations,
            positions: positionMigrations
        )
    }

    private func capabilityAvailable(
        _ capability: AdapterCapability,
        in spaceID: String
    ) -> Bool {
        guard let database else { return false }
        return sourceIDs(in: spaceID).contains { sourceID in
            guard let snapshotID = source(id: sourceID)?.latestSnapshotID else { return false }
            if selectedSourceID == sourceID,
               adapterPlan?.snapshotID == snapshotID {
                return adapterPlan?.capabilityRoutes[capability] != nil
            }
            return (try? database.fetchAdapterPlan(snapshotID: snapshotID))?
                .capabilityRoutes[capability] != nil
        }
    }

    private func loadAgentActivity(spaceID: String) {
        guard let database else { return }
        let runs = (try? database.fetchAgentRuns(spaceID: spaceID)) ?? []
        var mapped = deterministicActivityBySpace[spaceID] ?? []
        for run in runs.reversed() {
            let events = (try? database.fetchAgentEvents(runID: run.id)) ?? []
            mapped.append(contentsOf: events.map { event in
                ReaderActivityItem(
                    id: event.id,
                    phase: event.phase,
                    message: event.message,
                    state: Self.activityState(for: event.kind),
                    date: event.createdAt,
                    metadata: event.metadata
                )
            })
        }
        guard selectedSpaceID == spaceID else { return }
        agentRuns = runs
        activity = mapped.sorted { $0.date < $1.date }
    }

    private func refreshSelectedAgentActivityAfterProviderMutation(
        affecting spaceID: String? = nil
    ) {
        guard let selectedSpaceID,
              spaceID == nil || spaceID == selectedSpaceID else { return }
        loadAgentActivity(spaceID: selectedSpaceID)
    }

    private func refreshReadingStructureState(spaceID: String) throws {
        guard let database else { return }
        var progress: ReadingProgress
        if let cached = progressBySpace[spaceID] {
            progress = cached
        } else {
            progress = try database.fetchReadingProgress(spaceID: spaceID)
        }
        let latestPlan = try database.latestReadingPlan(spaceID: spaceID)
        let latestGraph = try latestPlan.flatMap { try database.readingGraph(id: $0.graphID) }

        if let activeVersion = progress.graphVersion,
           let activeGraph = try database.readingGraph(
                spaceID: spaceID,
                version: activeVersion
           ),
           let activePlan = try database.readingPlan(
                spaceID: spaceID,
                graphVersion: activeVersion
           ) {
            graphsBySpace[spaceID] = activeGraph
            plansBySpace[spaceID] = activePlan
            if let latestPlan,
               let latestGraph,
               latestPlan.graphVersion == latestGraph.version,
               latestGraph.version != activeVersion {
                pendingGraphsBySpace[spaceID] = latestGraph
                pendingPlansBySpace[spaceID] = latestPlan
            } else {
                pendingGraphsBySpace[spaceID] = nil
                pendingPlansBySpace[spaceID] = nil
            }
            return
        }

        guard let latestPlan,
              let latestGraph,
              latestPlan.graphVersion == latestGraph.version else {
            graphsBySpace[spaceID] = nil
            plansBySpace[spaceID] = nil
            pendingGraphsBySpace[spaceID] = nil
            pendingPlansBySpace[spaceID] = nil
            return
        }
        // The first complete graph/plan pair establishes the active frozen
        // route. Every later pair remains pending until the user switches.
        progress.graphVersion = latestGraph.version
        if let goal = ReadingGoal(rawValue: latestPlan.goal) {
            progress.activeGoal = goal
        }
        progress.lastActiveAt = .now
        try database.saveReadingProgress(progress, spaceID: spaceID)
        progressBySpace[spaceID] = progress
        graphsBySpace[spaceID] = latestGraph
        plansBySpace[spaceID] = latestPlan
        pendingGraphsBySpace[spaceID] = nil
        pendingPlansBySpace[spaceID] = nil
    }

    private func loadSpaceState(spaceID: String) throws {
        guard let database else { return }
        progressBySpace[spaceID] = try database.fetchReadingProgress(spaceID: spaceID)
        try refreshReadingStructureState(spaceID: spaceID)
        annotations = try database.fetchAnnotations(spaceID: spaceID)
        history = try database.fetchReadingHistory(spaceID: spaceID, limit: 100)
        loadAgentActivity(spaceID: spaceID)
    }

    private func reloadLibraryState(preservingSelection: Bool = false) throws {
        guard let database else { return }
        spaces = try database.fetchSpaces()
        sources = try database.fetchSources()
        snapshots = try database.fetchSnapshots()
        sourceIDsBySpace = try Dictionary(uniqueKeysWithValues: spaces.map { space in
            (space.id, try database.sourceIDs(in: space.id))
        })
        providerProfiles = try database.fetchProviderProfiles()
        for space in spaces {
            progressBySpace[space.id] = try? database.fetchReadingProgress(spaceID: space.id)
            try? refreshReadingStructureState(spaceID: space.id)
        }
        let allRuns = try database.fetchAgentRuns()
        if selectedSpaceID == nil {
            agentRuns = allRuns
        }
        guard preservingSelection else { return }
        if let selectedSpaceID, !spaces.contains(where: { $0.id == selectedSpaceID }) {
            closeReadingWorkspace()
        }
    }

    private func replacePending(_ pending: PendingImport) {
        guard let index = pendingImports.firstIndex(where: { $0.id == pending.id }) else { return }
        pendingImports[index] = pending
    }

    private func removePending(id: String) {
        pendingImports.removeAll { $0.id == id }
    }

    private static func activityState(for kind: AgentEventKind) -> ReaderActivityItem.State {
        switch kind {
        case .queued: .pending
        case .phase, .modelRound, .toolStarted: .running
        case .toolFinished, .artifactCreated, .validation, .completed: .completed
        case .waitingForUser, .cancelled, .interrupted: .attention
        case .failed: .failed
        }
    }

    private static func loadPreferences(defaults: UserDefaults) -> ReaderPreferences {
        guard let data = defaults.data(forKey: ReaderPreferences.defaultsKey),
              let preferences = try? JSONDecoder().decode(ReaderPreferences.self, from: data) else {
            return ReaderPreferences()
        }
        return preferences
    }

    private static func save(preferences: ReaderPreferences, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: ReaderPreferences.defaultsKey)
        }
    }

    private static func inferredPositionUpdate(for locator: Locator) -> ReadingPositionUpdate {
        if let pageIndex = locator.payload["pageIndex"].flatMap(Int.init) {
            return ReadingPositionUpdate(
                locator: locator,
                granularity: .page,
                displayLabel: ReadingPositionUpdate.label(
                    for: locator,
                    detail: "第 \(pageIndex + 1) 页"
                )
            )
        }
        if let line = locator.payload["startLine"].flatMap(Int.init) {
            return ReadingPositionUpdate(
                locator: locator,
                granularity: .text,
                displayLabel: ReadingPositionUpdate.label(
                    for: locator,
                    detail: "第 \(line) 行"
                )
            )
        }
        if locator.payload["domPath"] != nil || locator.payload["scrollFraction"] != nil {
            let fraction = locator.payload["scrollFraction"].flatMap(Double.init)
            let detail = fraction.map { "阅读到 \(Int(min(max($0, 0), 1) * 100))%" }
                ?? "网页位置"
            return ReadingPositionUpdate(
                locator: locator,
                progressFraction: fraction,
                granularity: .dom,
                displayLabel: ReadingPositionUpdate.label(for: locator, detail: detail)
            )
        }
        let detail = locator.adapterID == QuickLookAdapter.id
            ? "已打开（系统预览仅支持来源级位置）"
            : "已打开"
        return ReadingPositionUpdate(
            locator: locator,
            granularity: .document,
            displayLabel: ReadingPositionUpdate.label(for: locator, detail: detail)
        )
    }

    private static func positionDescription(for locator: Locator) -> String {
        inferredPositionUpdate(for: locator).displayLabel ?? "已记录"
    }
}
