import Combine
import Foundation

/// A read's own outcome, independent of later navigation/action errors.
/// This receipt is transient UI state, not a persistence or query contract.
enum NotesReloadOutcome: Equatable, Sendable {
    case loaded
    case failed(String)
    case superseded
}

struct NotesReloadReceipt: Equatable, Sendable {
    let query: NotesQuery
    let revision: UUID
    let generation: UUID
    let outcome: NotesReloadOutcome
}

@MainActor
final class NotesCenterModel: ObservableObject {
    @Published var query = NotesQuery()
    @Published var selectedIDs: Set<String> = []
    @Published private(set) var entries: [NotesEntry] = []
    @Published private(set) var tags: [AnnotationTag] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var revision = UUID()
    @Published private(set) var lastReloadReceipt: NotesReloadReceipt?
    private(set) var nextCursor: NotesCursor?

    let database: LibraryDatabase
    private let onMutation: @MainActor () -> Void
    private let onOpen: @MainActor (NotesEntry) async throws -> Void
    private var generation = UUID()
    private var openTask: Task<Void, Error>?
    private var openGeneration = UUID()

    init(database: LibraryDatabase, onMutation: @escaping @MainActor () -> Void, onOpen: @escaping @MainActor (NotesEntry) async throws -> Void) {
        self.database = database
        self.onMutation = onMutation
        self.onOpen = onOpen
    }

    func invalidate() { revision = UUID() }

    @discardableResult
    func reload() async -> NotesReloadOutcome {
        generation = UUID()
        let token = generation
        let requested = query
        let requestedRevision = revision
        isLoading = true
        errorMessage = nil
        entries = []
        selectedIDs = []
        nextCursor = nil
        do {
            let page = try await database.notesPage(query: requested)
            let currentTags = try await database.notesTags()
            try Task.checkCancellation()
            guard token == generation, requested == query, requestedRevision == revision else { return .superseded }
            entries = page.entries
            nextCursor = page.nextCursor
            totalCount = page.totalCount
            tags = currentTags
            isLoading = false
            lastReloadReceipt = NotesReloadReceipt(query: requested,
                revision: requestedRevision, generation: token, outcome: .loaded)
            return .loaded
        } catch is CancellationError {
            // The replacement task owns the new list state.
            if token == generation { isLoading = false }
            return .superseded
        } catch {
            guard token == generation, requested == query, requestedRevision == revision else { return .superseded }
            errorMessage = error.localizedDescription
            isLoading = false
            lastReloadReceipt = NotesReloadReceipt(query: requested,
                revision: requestedRevision, generation: token, outcome: .failed(error.localizedDescription))
            return .failed(error.localizedDescription)
        }
    }

    func loadMore() async {
        guard !isLoading, let cursor = nextCursor else { return }
        let token = generation
        let requested = query
        isLoading = true
        defer { if token == generation { isLoading = false } }
        do {
            let page = try await database.notesPage(query: requested, after: cursor)
            try Task.checkCancellation()
            guard token == generation, requested == query else { return }
            let currentIDs = Set(entries.map(\.id))
            entries += page.entries.filter { !currentIDs.contains($0.id) }
            nextCursor = page.nextCursor
            totalCount = page.totalCount
        } catch is CancellationError {
        } catch { if token == generation { errorMessage = error.localizedDescription } }
    }

    func open(_ entry: NotesEntry) async {
        openTask?.cancel()
        openGeneration = UUID()
        let requestedOpen = openGeneration
        let requestedGeneration = generation
        let requestedQuery = query
        let requestedRevision = revision
        errorMessage = nil
        let task = Task { try await onOpen(entry) }
        openTask = task
        do { try await task.value }
        catch is CancellationError {}
        catch {
            guard requestedOpen == openGeneration, requestedGeneration == generation,
                  requestedQuery == query, requestedRevision == revision,
                  !task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func cancelOpening() {
        openGeneration = UUID()
        openTask?.cancel()
        openTask = nil
    }

    func save(_ entry: NotesEntry, note: String, tagIDs: Set<String>) async throws {
        try await database.editNote(id: entry.id, expectedUpdatedAt: entry.annotation.updatedAt, note: note, tagIDs: tagIDs)
        onMutation()
        invalidate()
    }

    func delete(_ entries: [NotesEntry]) async throws {
        try await database.deleteNotes(Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.annotation.updatedAt) }))
        onMutation()
        invalidate()
    }

    func refreshTags() async throws {
        tags = try await database.notesTags()
        query.tagIDs.formIntersection(Set(tags.map(\.id)))
    }
}
