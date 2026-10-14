# NotesPresentation.swift

Owns presentation-only state for the debounced Notes sheet and localized
annotation status. It does not query the database, change annotations, resolve
Locators, or participate in Markdown export.

- `NotesRefreshKey` identifies the query and the model's explicit refresh
  revision. `NotesRefreshPresentation` accepts only a matching completed read
  outcome, never a live shared action-error string. The model's generation-bound
  receipt also lets two mounted sheets observe the same completed current read.
- The sheet derives its projection directly from the latest model receipt; it
  does not retain a local successful receipt that can re-match after a query
  loops back. Pending reads have no settled count. A cancelled current owner
  without a replacement read yields an explicit paused/retry state, not empty.
- Until a matching completion exists, first load and query debounce are loading,
  not empty. Settled failed reads are retryable; pagination retains current
  rows instead of replacing them with an empty placeholder.
- The Notes footer disables export/deletion while results are unsettled or
  loading, or the current read failed/interrupted. A failed refresh cannot expose the previous
  query's count; its footer says the result is unavailable. The real AppKit export
  button and keyboard shortcut remain intact.
- `ReaderAnnotationStatus` localizes ordinary Notes/Inspector chrome while
  retaining separate source-availability, historical-revision, and anchor-state
  distinctions. The editor exposes exact raw metadata in a named disclosure.
- `NotesEntry.statusLabel`, persisted enum values, and exporter fields are
  deliberately unchanged. These view labels are never written to the Library.

`NotesPresentationTests` covers first/debounced load, cancelled and stale
completion, failed load after prior success, delayed/cancelled original-opening
errors, shared-read receipts, query wrap, cancelled-owner retry, retained pagination, status distinctions and the
actual mounted export button's disabled/enabled behavior.
