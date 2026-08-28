import Foundation

enum SourceOriginKind: String, Codable, CaseIterable, Sendable {
    case localFile
    case localDirectory
    case remoteURL
    case githubRepository
}

enum SourceManagedState: String, Codable, CaseIterable, Sendable {
    case processing
    case ready
    case failed
    case removed
}

struct Source: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var displayName: String
    let originKind: SourceOriginKind
    let originURL: URL?
    var managedState: SourceManagedState
    var latestSnapshotID: String?
    var failureReason: String?
    var isFavorite: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString.lowercased(),
        displayName: String,
        originKind: SourceOriginKind,
        originURL: URL?,
        managedState: SourceManagedState = .processing,
        latestSnapshotID: String? = nil,
        failureReason: String? = nil,
        isFavorite: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.originKind = originKind
        self.originURL = originURL
        self.managedState = managedState
        self.latestSnapshotID = latestSnapshotID
        self.failureReason = failureReason
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ReadingSpace: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var isFavorite: Bool
    let createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date?

    init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        isFavorite: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
    }
}

enum SourceRevisionKind: String, Codable, Sendable {
    case contentDigest
    case directoryTreeDigest
    case gitCommit
    case webSnapshot
    case unresolved
}

enum SourceKind: String, Codable, CaseIterable, Sendable {
    case githubRepository
    case pdf

    var displayName: String {
        switch self {
        case .githubRepository: "GitHub Repo"
        case .pdf: "PDF"
        }
    }
}

enum SourceCapability: String, Codable, CaseIterable, Sendable {
    case list
    case read
    case render
    case search
    case resolve
}

enum SourceAvailability: String, Codable, Sendable {
    case resolving
    case ready
    case offline
    case stale
}

struct ReadingSource: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    let kind: SourceKind
    let origin: URL?
    var revision: String?
    let capabilities: Set<SourceCapability>
    var availability: SourceAvailability
    var detail: String
}

struct SourceSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let sourceID: String
    let revision: String
    let revisionKind: SourceRevisionKind
    let digest: String
    let observedAt: Date
    let origin: URL?
    let managedRelativePath: String?
    let byteCount: Int64

    init(
        id: String,
        sourceID: String,
        revision: String,
        revisionKind: SourceRevisionKind,
        digest: String,
        observedAt: Date,
        origin: URL?,
        managedRelativePath: String?,
        byteCount: Int64
    ) {
        self.id = id
        self.sourceID = sourceID
        self.revision = revision
        self.revisionKind = revisionKind
        self.digest = digest
        self.observedAt = observedAt
        self.origin = origin
        self.managedRelativePath = managedRelativePath
        self.byteCount = byteCount
    }

    init(sourceID: String, revision: String, observedAt: Date, origin: URL?) {
        let kind: SourceRevisionKind = sourceID.hasPrefix("github:")
            ? .gitCommit
            : .contentDigest
        self.init(
            id: "\(sourceID)@\(revision)",
            sourceID: sourceID,
            revision: revision,
            revisionKind: revision.isEmpty ? .unresolved : kind,
            digest: revision,
            observedAt: observedAt,
            origin: origin,
            managedRelativePath: nil,
            byteCount: 0
        )
    }

    var isResolved: Bool {
        revisionKind != .unresolved && !revision.isEmpty
    }
}

enum NativeLocator: Codable, Hashable, Sendable {
    case repository(path: String, startLine: Int?, endLine: Int?)
    case pdf(pageIndex: Int)

    var conciseDescription: String {
        switch self {
        case let .repository(path, startLine, endLine):
            guard let startLine else { return path }
            if let endLine, endLine != startLine {
                return "\(path):\(startLine)-\(endLine)"
            }
            return "\(path):\(startLine)"
        case let .pdf(pageIndex):
            return "第 \(pageIndex + 1) 页"
        }
    }
}

struct TextAnchor: Codable, Hashable, Sendable {
    let prefix: String?
    let exact: String
    let suffix: String?
}

struct Locator: Codable, Hashable, Sendable {
    let sourceID: String
    let sourceRevision: String
    let native: NativeLocator
    let textAnchor: TextAnchor?
    let fingerprint: String?

    var stableID: String {
        "\(sourceID)@\(sourceRevision):\(native.conciseDescription)"
    }
}

struct Observation: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let sourceID: String
    let sourceRevision: String
    let locator: Locator
    let mediaType: String
    let content: String
    let contentDigest: String
    let truncated: Bool
    let observedAt: Date
}

enum FragmentRole: String, Codable, Sendable {
    case primary
    case example
    case evidence
    case reference
}

struct SourceFragment: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let sourceID: String
    let locator: Locator
    let role: FragmentRole
    let label: String
}

enum RelationType: String, Codable, Sendable {
    case follows
    case prerequisite
    case references
    case implements
    case deepens
    case optional
}

struct UnitRelation: Codable, Hashable, Sendable {
    let targetUnitID: String
    let type: RelationType
    let weight: Double
    let confidence: Double
    let isHardConstraint: Bool
}

enum PresentationKind: String, Codable, CaseIterable, Sendable {
    case repository
    case pdf
    case comparison

    var displayName: String {
        switch self {
        case .repository: "Repo"
        case .pdf: "PDF"
        case .comparison: "对照"
        }
    }
}

struct ReadingUnit: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String
    let fragments: [SourceFragment]
    let relations: [UnitRelation]
    let estimatedMinutes: Int
    let importance: Double
    let confidence: Double
    let sourceOrder: Int
    let preferredPresentation: PresentationKind

    var repositoryFragment: SourceFragment? {
        fragments.first { fragment in
            if case .repository = fragment.locator.native { return true }
            return false
        }
    }

    var pdfFragment: SourceFragment? {
        fragments.first { fragment in
            if case .pdf = fragment.locator.native { return true }
            return false
        }

    }

    var availablePresentations: [PresentationKind] {
        switch (repositoryFragment != nil, pdfFragment != nil) {
        case (true, true): [.repository, .pdf, .comparison]
        case (true, false): [.repository]
        case (false, true): [.pdf]
        case (false, false): []
        }
    }
}

struct ReadingGraph: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let version: String
    let title: String
    let sourceSnapshots: [SourceSnapshot]
    let units: [ReadingUnit]
    let mapperID: String
    let mapperVersion: String
    let generatedAt: Date
}

enum ReadingGoal: String, Codable, CaseIterable, Identifiable, Sendable {
    case quickOverview
    case systematic
    case review

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quickOverview: "快速了解"
        case .systematic: "系统阅读"
        case .review: "复习巩固"
        }
    }

    var compactDescription: String {
        switch self {
        case .quickOverview: "优先抓住高价值章节"
        case .systematic: "按材料原始顺序推进"
        case .review: "优先处理未完成单元"
        }
    }
}

struct PlannedUnit: Identifiable, Codable, Hashable, Sendable {
    let unitID: String
    let position: Int
    let reason: String

    var id: String { unitID }
}

struct ReadingPlan: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let graphVersion: String
    let goal: ReadingGoal
    let orderedUnits: [PlannedUnit]
    let createdAt: Date
}

enum UnitProgressState: String, Codable, Sendable {
    case unseen
    case previewed
    case reading
    case completed
    case skipped
    case needsReview
}

struct UnitProgress: Codable, Hashable, Sendable {
    let unitID: String
    var state: UnitProgressState
    var fraction: Double
    var updatedAt: Date
}

struct SourcePosition: Codable, Hashable, Sendable {
    let sourceID: String
    var locator: Locator
    var updatedAt: Date
}

struct ReadingProgress: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var graphVersion: String?
    var activeGoal: ReadingGoal
    var currentUnitID: String?
    var units: [String: UnitProgress]
    var sourcePositions: [String: SourcePosition]
    var lastActiveAt: Date

    static var empty: ReadingProgress {
        ReadingProgress(
            schemaVersion: currentSchemaVersion,
            graphVersion: nil,
            activeGoal: .systematic,
            currentUnitID: nil,
            units: [:],
            sourcePositions: [:],
            lastActiveAt: .now
        )
    }

    func state(for unitID: String) -> UnitProgressState {
        units[unitID]?.state ?? .unseen
    }

    var completedUnitIDs: Set<String> {
        Set(
            units.values
                .filter { $0.state == .completed }
                .map(\.unitID)
        )
    }
}

struct RepositoryCoordinate: Codable, Hashable, Sendable {
    let owner: String
    let repository: String

    var slug: String {
        "\(owner)/\(repository)"
    }
}

struct RepositoryChapter: Identifiable, Codable, Hashable, Sendable {
    let title: String
    let path: String
    let order: Int

    var id: String { path }
}

struct RepositoryBook: Codable, Hashable, Sendable {
    let coordinate: RepositoryCoordinate
    let defaultBranch: String
    let source: ReadingSource
    let snapshot: SourceSnapshot
    let chapters: [RepositoryChapter]
}

struct PDFSection: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let pageIndex: Int
    let order: Int
}

enum AdapterCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case probe
    case revision
    case list
    case read
    case search
    case render
    case resolve
}

struct AdapterProbeRule: Codable, Hashable, Sendable {
    var filenameExtensions: Set<String>
    var mediaTypes: Set<String>
    var sourceOrigins: Set<SourceOriginKind>
    var magicPrefixes: [Data]

    init(
        filenameExtensions: Set<String> = [],
        mediaTypes: Set<String> = [],
        sourceOrigins: Set<SourceOriginKind> = [],
        magicPrefixes: [Data] = []
    ) {
        self.filenameExtensions = filenameExtensions
        self.mediaTypes = mediaTypes
        self.sourceOrigins = sourceOrigins
        self.magicPrefixes = magicPrefixes
    }
}

struct AdapterDescriptor: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let version: String
    let displayName: String
    let probeRule: AdapterProbeRule
    let capabilities: Set<AdapterCapability>
    let limitations: [String]
}

struct ProbeEvidence: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let adapterID: String
    let rule: String
    let detail: String
    let confidence: Double
}

struct AdapterPlan: Identifiable, Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let id: String
    let schemaVersion: Int
    let sourceID: String
    let snapshotID: String
    let primaryAdapterID: String
    let auxiliaryAdapterIDs: [String]
    let capabilityRoutes: [AdapterCapability: String]
    let evidence: [ProbeEvidence]
    let confidence: Double
    let reason: String
    let isUserOverride: Bool
    let createdAt: Date
}

enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case bookmark
    case highlight
    case note
}

enum AnnotationAnchorState: String, Codable, Sendable {
    case current
    case relocated
    case orphaned
}

struct Annotation: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let spaceID: String
    let sourceID: String
    let snapshotID: String
    let kind: AnnotationKind
    var locator: Locator
    var anchorState: AnnotationAnchorState
    var selectedText: String?
    var note: String?
    var color: String?
    let createdAt: Date
    var updatedAt: Date
}

struct GraphPatch: Identifiable, Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let id: String
    let schemaVersion: Int
    let graphID: String
    let baseGraphVersion: String?
    let snapshotIDs: Set<String>
    let upsertUnits: [ReadingUnit]
    let removeUnitIDs: Set<String>
    let generatedAt: Date
}

enum AgentRunState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case waitingForUser
    case completed
    case failed
    case cancelled
    case interrupted
}

enum AgentTaskKind: String, Codable, CaseIterable, Sendable {
    case routeAdapters
    case scoutSpace
    case materializeGraph
    case projectRoute
    case answerWithEvidence
}

struct AgentRun: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let spaceID: String
    let task: AgentTaskKind
    let generation: Int
    var state: AgentRunState
    let providerProfileID: String?
    let createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var errorCategory: String?
}

enum AgentEventKind: String, Codable, CaseIterable, Sendable {
    case phase
    case toolStarted
    case toolFinished
    case artifactCreated
    case validation
    case waitingForUser
    case completed
    case failed
}

struct AgentEvent: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let runID: String
    let sequence: Int
    let kind: AgentEventKind
    let phase: String
    let message: String
    let metadata: [String: String]
    let createdAt: Date
}

struct AgentArtifact: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let runID: String
    let digest: String
    let mediaType: String
    let relativePath: String
    let byteCount: Int64
    let summary: String
    let createdAt: Date
}
