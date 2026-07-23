import Foundation

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
    let sourceID: String
    let revision: String
    let observedAt: Date
    let origin: URL?

    var id: String {
        "\(sourceID)@\(revision)"
    }

    var isResolved: Bool {
        revision != DemoCatalog.unresolvedRevision
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

