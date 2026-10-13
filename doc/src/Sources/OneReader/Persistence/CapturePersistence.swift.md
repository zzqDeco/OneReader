# Capture persistence

Registers migration v11-capture-inbox and the single Space organization column.
It owns idempotent receipt insertion, atomic attempt claims, retry/cancel,
interrupted-run recovery, and reversible organization.

LibraryDatabase.commitImport inserts result IDs in the same transaction as
Source/Snapshot/Space membership. A lost claim cannot create another source.
Organization operations never rewrite locators, reading progress, notes,
bookmarks, history, source identity, snapshots or managed bytes.
