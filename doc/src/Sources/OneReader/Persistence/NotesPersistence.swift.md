# Notes center source boundaries

- `Domain/NotesModels.swift` defines tag normalization, query/cursor/page records,
  export snapshots and the strict v1 local route. It does not fork Annotation or
  Locator identity and contains no Provider or network behavior.
- `Persistence/NotesPersistence.swift` owns the separately registered v12
  migration, private note-search projection/triggers, bounded asynchronous keyset
  queries, tag transactions, optimistic edit/delete checks and consistent export
  snapshots. It reuses ReaderPersistence's authoritative Annotation decoder.
- `Persistence/NotesMarkdownExporter.swift` owns deterministic escaping/naming,
  optional sanitized webpage links and atomic new-copy publication beneath an
  explicitly authorized directory. No path from content controls filesystem IO.
- `App/NotesCenterModel.swift` owns cancellable pagination generation, selection
  and mutation invalidation. AppModel initializes it with narrow refresh/open
  callbacks; original-snapshot preview suppresses durable progress and index work.
- `UI/NotesCenterView.swift`, `NotesTagManager.swift`, and `NotesExportView.swift`
  provide native controls, selectable retained content, scope previews, explicit
  destructive confirmations, error feedback, cancellation and directory consent.
  The Inspector uses the same editor and mutation service.
  macOS export is a persistent AppKit button in `NotesCenterFooter`, with explicit
  accessibility identity and a keyboard equivalent. Enabled state respects both
  current note count and the SwiftUI environment; its coordinator rejects stale
  disabled actions and updates the callback on reload. iOS export is a separate
  toolbar item rather than a second child in a compacted group.

See [notes center contracts](../../../../notes-center.md). Native/device
acceptance is not implied by the unit-level data and export regression suite.
