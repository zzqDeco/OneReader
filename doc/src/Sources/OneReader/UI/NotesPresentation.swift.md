# NotesPresentation.swift

Owns presentation-only state for the debounced Notes sheet and localized
annotation status. It does not query the database, change annotations, resolve
Locators, or participate in Markdown export.

- `NotesRefreshKey` identifies the query and the model's explicit refresh
  revision. `NotesRefreshPresentation` accepts a completion only if that key
  still matches and the task has not been cancelled.
- Until a matching completion exists, first load and query debounce are loading,
  not empty. Settled failed reads are retryable; pagination retains current
  rows instead of replacing them with an empty placeholder.
- The Notes footer disables export/deletion while results are unsettled or
  loading. Its real AppKit export button and keyboard shortcut remain intact.
- `ReaderAnnotationStatus` localizes ordinary Notes/Inspector chrome while
  retaining separate source-availability, historical-revision, and anchor-state
  distinctions. The editor exposes exact raw metadata in a named disclosure.
- `NotesEntry.statusLabel`, persisted enum values, and exporter fields are
  deliberately unchanged. These view labels are never written to the Library.

`NotesPresentationTests` covers first/debounced load, cancelled and stale
completion, failed load, retained pagination, status distinctions and the actual
mounted export button's disabled/enabled behavior.
