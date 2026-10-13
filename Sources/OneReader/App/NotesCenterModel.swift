import Combine
import Foundation

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
    private(set) var nextCursor: NotesCursor?

    let database: LibraryDatabase
    private let onMutation: @MainActor () -> Void
    private let onOpen: @MainActor (NotesEntry) async throws -> Void
    private var generation = UUID()
    private var openTask: Task<Void, Error>?

    init(database: LibraryDatabase, onMutation: @escaping @MainActor () -> Void, onOpen: @escaping @MainActor (NotesEntry) async throws -> Void) {
        self.database = database
        self.onMutation = onMutation
        self.onOpen = onOpen
    }

    func invalidate() { revision = UUID() }

    func reload() async {
        generation = UUID()
        let token = generation
        let requested = query
        isLoading = true
        errorMessage = nil
        entries = []
        selectedIDs = []
        nextCursor = nil
        do {
            let page = try await database.notesPage(query: requested)
            let currentTags = try await database.notesTags()
            try Task.checkCancellation()
            guard token == generation, requested == query else { return }
            entries = page.entries
            nextCursor = page.nextCursor
            totalCount = page.totalCount
            tags = currentTags
        } catch is CancellationError {
            // The replacement task owns the new list state.
        } catch {
            if token == generation { errorMessage = error.localizedDescription }
        }
        if token == generation { isLoading = false }
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
        errorMessage = nil
        let task = Task { try await onOpen(entry) }
        openTask = task
        do { try await task.value }
        catch is CancellationError {}
        catch { errorMessage = error.localizedDescription }
    }

    func cancelOpening() { openTask?.cancel(); openTask = nil }

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
