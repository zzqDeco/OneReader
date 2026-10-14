# NotesCenterModel.swift

Owns the transient Notes query/results and original-opening lifecycle. Existing
database queries, cursor pagination, edit/delete concurrency checks, source
resolution and persistence contracts remain unchanged.

- A first-page reload returns its own `NotesReloadOutcome` and publishes a
  `NotesReloadReceipt` only after its query, revision and generation still match.
  The receipt is not stored in SQLite and does not contain notes/source content.
- A distinct generation makes even equivalent successful reads observable by
  multiple mounted sheets. UI accepts only the latest matching receipt, not a
  superseded task or the mutable shared `errorMessage` as a load outcome.
- Legacy `totalCount` may retain the last completed count after a failed read;
  Notes chrome projects it only from a successful current receipt, never as
  authority for a failed query's export action.
- Opening errors require the same open-request, query, refresh revision and
  reload generation, and an uncancelled task. A replaced/cancelled/old opening
  therefore cannot overwrite a newer search's error state. Current opening and
  pagination errors remain visible as operation errors, not failed first loads.
- Mutation still invalidates the revision after the same existing database
  transaction; no model, Provider, source-tool or reading-position logic is added.

Notes presentation regressions use generated test-owned Libraries and controlled
delayed failures. Closing a test pool simulates a failed read without corrupting
or deleting production tables; native export remains visible and disabled.
