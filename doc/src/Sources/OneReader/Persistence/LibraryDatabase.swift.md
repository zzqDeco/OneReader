# `Sources/OneReader/Persistence/LibraryDatabase.swift`

Owns the GRDB `DatabasePool`, ordered migrations, WAL/foreign-key setup,
transactional source/snapshot/Space commits, schema metadata, and legacy
progress migration manifest. It also computes shared-content-aware removal
plans and commits Source removal with Space detachment in one transaction.

Adapter plans and Observations are encoded with stable JSON settings. Saving an
Observation updates its FTS5 row in the same write transaction; the index can
be rebuilt solely from durable Observation rows.
Search joins active Source state so a removed Source cannot remain visible
through stale FTS rows.

It records Provider Keychain references but never API keys. A legacy progress
file is moved only after database migration succeeds and is explicitly marked
as not bound to new objects.

Schema v6 marks transcript rows as complete or partial-failure audit data and
model-call metrics as succeeded, failed, or cancelled. These immutable failure
records never become the mutable resumable session transcript. Migration tests
open a real v5 database with existing transcript/metric rows, verify default
backfill through v6, and prove unknown enum values fail closed.

`SourceRevisionCoordinator` is the production refresh entry point. It first
invalidates in-memory Agent sessions for affected Spaces, then one database
transaction installs the new immutable Snapshot, advances the Source pointer,
cancels persisted active/waiting runs, supersedes candidates, records events,
and increments durable generations.
