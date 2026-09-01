# `Sources/OneReader/Persistence/LibraryDatabase.swift`

Owns the GRDB `DatabasePool`, ordered migrations, WAL/foreign-key setup,
transactional source/snapshot/Space commits, schema metadata, and legacy
progress migration manifest. It also computes shared-content-aware removal
plans and commits Source removal with Space detachment, annotation/history
cleanup, graph/plan invalidation, progress reset, active-Run cancellation, and
durable Agent-generation advancement in one transaction.

Adapter plans and Observations are encoded with stable JSON settings. Schema v7
introduced atomic index staging. Schema v9 separates raw evidence Observations
from `search_documents`, records one active AdapterPlan per Snapshot, keys index
runs by Snapshot plus plan ID, and publishes only after an active-plan
compare-and-swap. Startup drops interrupted staging so a partial or superseded
plan can never be mistaken for current searchable data.
After a v8-to-v9 migration, active searchable plans without a completed
projection are queryable as deterministic rebuild work. App bootstrap schedules
all of them, so global search recovers without opening each Space.
Search joins active Source state so a removed Source cannot remain visible
through stale FTS rows. When FTS `unicode61` produces no match, a bounded
active-search-projection substring query supplies exact Chinese/unsegmented-script
results without scanning a managed repository tree. Every returned hit derives
a query-specific quote/range Locator and preserves format identity such as a PDF
page.

It records Provider Keychain references but never API keys. A legacy progress
file is moved only after database migration succeeds and is explicitly marked
as not bound to new objects.

Schema v6 marks transcript rows as complete or partial-failure audit data and
model-call metrics as succeeded, failed, or cancelled. These immutable failure
records never become the mutable resumable session transcript. Migration tests
open a real v5 database with existing transcript/metric rows, verify default
backfill through v6, and prove unknown enum values fail closed.

`SourceRevisionCoordinator` is the Agent-session refresh barrier. Product
refresh stages the managed revision and resolves anchors first; the final
database transaction inserts the immutable Snapshot, advances the Source,
stores relocated/orphaned annotation states and position migrations, and
invalidates stale Agent runs. The coordinator first invalidates in-memory Agent
sessions for affected Spaces; that transaction also cancels persisted
active/waiting/interrupted runs, supersedes candidates, records events, and increments
durable generations.

Schema v8 adds Source-keyed security-scoped bookmark storage. Import can insert
the bookmark in the same transaction as Source/Snapshot/Space identity; Source
removal deletes it even though the historical Source row remains marked
removed.
