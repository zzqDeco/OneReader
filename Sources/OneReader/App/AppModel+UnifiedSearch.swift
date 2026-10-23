import Foundation

extension AppModel {
    var hasActiveLibrarySearch: Bool {
        !librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var unifiedProcessingCount: Int {
        activePendingImportCount
            + captureJobs.filter { $0.phase != .ready && $0.phase != .cancelled }.count
    }

    func performUnifiedLibrarySearch() {
        unifiedSearchTask?.cancel()
        let query = librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            unifiedSearchResults = UnifiedLibrarySearchResults()
            isUnifiedSearching = false
            return
        }
        isUnifiedSearching = true
        let matchingSpaces = visibleSpaces
        unifiedSearchResults.spaces = matchingSpaces
        guard let database else {
            unifiedSearchResults = UnifiedLibrarySearchResults(spaces: matchingSpaces)
            isUnifiedSearching = false
            return
        }
        unifiedSearchTask = Task { [weak self] in
            guard let self else { return }
            let contentHits = (try? database.searchObservations(query: query, limit: 12)) ?? []
            let notesPage = try? await database.notesPage(query: NotesQuery(search: query), limit: 12)
            let noteEntries = notesPage?.entries ?? []
            guard !Task.isCancelled,
                  librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                return
            }
            unifiedSearchResults = UnifiedLibrarySearchResults(
                spaces: matchingSpaces,
                contentHits: contentHits,
                noteEntries: noteEntries
            )
            isUnifiedSearching = false
        }
    }

    func openLibraryContentSearchHit(_ hit: ContentSearchHit) {
        let matchingSpaces = spaces.filter { sourceIDs(in: $0.id).contains(hit.sourceID) }
        guard let targetSpace = matchingSpaces.first(where: { $0.organizationState != .archived })
            ?? matchingSpaces.first else {
            return
        }
        openSpace(targetSpace.id, preferredSourceID: hit.sourceID)
        openLocator(hit.locator)
    }

    func openLibraryNoteHit(_ entry: NotesEntry) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await openNotesEntry(entry)
            } catch is CancellationError {
                return
            } catch {
                notice = AppNotice(title: "无法打开笔记位置", message: error.localizedDescription)
            }
        }
    }
}
