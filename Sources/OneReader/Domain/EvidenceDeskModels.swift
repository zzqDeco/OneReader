import Foundation

enum SpaceSourceRole: String, Codable, CaseIterable, Hashable, Sendable {
    case primary
    case reference

    var title: String {
        switch self {
        case .primary: "主读材料"
        case .reference: "参考附件"
        }
    }
}

struct CompletedEvidenceQA: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let runID: String
    let spaceID: String
    let question: String
    let answer: EvidenceAnswer
    let createdAt: Date

    init(
        id: String,
        runID: String,
        spaceID: String,
        question: String,
        answer: EvidenceAnswer,
        createdAt: Date = .now
    ) {
        self.id = id
        self.runID = runID
        self.spaceID = spaceID
        self.question = question
        self.answer = answer
        self.createdAt = createdAt
    }
}

struct UnifiedLibrarySearchResults: Equatable, Sendable {
    var spaces: [ReadingSpace] = []
    var contentHits: [ContentSearchHit] = []
    var noteEntries: [NotesEntry] = []

    var isEmpty: Bool {
        spaces.isEmpty && contentHits.isEmpty && noteEntries.isEmpty
    }
}

extension AnnotationAnchorState {
    var localizedBadgeTitle: String? {
        switch self {
        case .current:
            nil
        case .relocated:
            "已对齐新版本"
        case .orphaned:
            "原文已变动"
        }
    }
}
