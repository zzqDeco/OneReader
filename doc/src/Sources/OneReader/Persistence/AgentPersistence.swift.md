# `Sources/OneReader/Persistence/AgentPersistence.swift`

Owns GRDB access for Provider profiles and Space overrides, disclosure facts,
Agent runs/events/transcripts/sessions, immutable context snapshots, model-call
metrics, Artifact metadata, structured outputs, and validated domain commits.
JSON coders are created per operation because Foundation coders are not shared
as concurrent mutable state.

Provider rows contain only Keychain references. Each Run stores immutable
destination and Provider-revision identities. Editing a profile or Space
override transactionally cancels every active Run whose binding is stale,
supersedes pending output, appends an audit event, and advances the session
generation. Disclosure facts bind a hash of Provider kind and canonical
endpoint; confirmation uses the Run-bound identity. Provider connection results
carry the exact tested revision and update capabilities/status only when a
same-transaction comparison proves that revision is still current.

Events have a unique ordered sequence per run. Run creation and its first queued
event share one transaction. Ordinary recorder event writes require the Run to
remain queued/running and compare the exact next sequence in that transaction,
so no event can be appended after a terminal transition. Artifacts are scoped
by run ID, and startup interruption does not replay external work. Context snapshots are
append-only per Run and preserve both the full and actual projected transcript;
the session row is only the mutable current view. Model-call rows store actual
bytes, conservative token upper bounds, duration, and call outcome; transcript
entries distinguish complete content from audit-only partial failures. Model
metrics and any partial-failure transcript record share one write transaction
and a database-assigned transcript sequence. The transaction rechecks the Run,
session generation, and selected Provider binding. A nominal success or failure
that loses to terminal cancellation is stored as cancellation with the bounded
observed entry. Cancellation audit may finish for a matching terminal-cancelled
Run after its Space session has advanced, but it cannot mutate that session or
domain state. A unique
partial index permits only one resumed child per parent run. Beginning a newer run
transactionally supersedes older queued/running/waiting rows and their pending
output. The sole production finalization path compares the active session
generation and run state, rechecks the exact Snapshot manifest, applies the
host-owned domain mutation, saves output, transitions state, and appends the
final event inside one write transaction. There is no separate production
helper that can commit a validated domain result outside that CAS.
An accepted AdapterPlan is inserted and selected in `active_adapter_plans`
inside that same finalization transaction; search visibility can therefore bind
to the exact committed plan without a second write window.
