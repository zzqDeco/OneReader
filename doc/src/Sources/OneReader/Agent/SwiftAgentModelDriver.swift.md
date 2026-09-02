# `Sources/OneReader/Agent/SwiftAgentModelDriver.swift`

Adapts the pinned Provider models to SwiftAgent while retaining OneReader's
authority over projection, generation, budgets, persistence, and output
validation. Every generation uses an explicitly tightened response-token option;
the host independently measures complete responses and cumulatively aggregates
every SDK stream delta. It limits both the full logical entry and total encoded
stream entries, persists the aggregate rather than the last delta, and fails
closed even when a Provider ignores its option.

The pinned Anthropic adapter emits cumulative text prefixes, unlike the delta
contract consumed by OpenFoundationModels. The driver validates exact UTF-8
byte prefixes and normalizes those snapshots before yielding them, while still
counting the full raw entries for transport telemetry. Combining marks and ZWJ
sequences remain valid suffixes; canonically equivalent byte rewrites fail
closed. Final structured segments replace their
provisional text in the persisted aggregate.

Before and after network work the controlled model revalidates the Run's
immutable Provider binding. Every model boundary appends a context snapshot and
a model-call metric containing actual input/complete-or-cumulative output bytes,
conservative token upper bounds, and duration. The base-model summarizer shares
the run round budget and the same input/output enforcement. Metrics include a
success/failure/cancellation outcome. If streaming or summarization fails after
observing output, the runtime records the actual bytes and appends the aggregate
as a `partialFailure` audit entry without installing it in the resumable mutable
transcript. Generation, task cancellation, and Provider binding are rechecked
after every Provider return. Metric and partial data commit atomically; if a
non-cooperative Provider returns normally after a matching Run has reached
`cancelled`, persistence converts the nominal result to cancellation and retains
the observed entry even after a replacement generation closes the recorder.
Large rejected entries become bounded digest markers instead of being copied
wholesale into SQLite.
