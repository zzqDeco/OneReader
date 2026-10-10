# `Sources/OneReader/Adapters/AdapterCoordinator.swift`

Reconstructs managed contexts, validates selected adapters, and orchestrates
active-plan-bound atomic search projection. Text index hooks bypass outline
listing; directory children receive their path-scoped context. PDF/EPUB child
nodes retain page/spine identity.

`SearchIndexGate` is process-wide, cancellable, FIFO, and allows one active
Source index, not one per actor instance. Queued work has no staging generation.
Cancellation racing with slot acquisition releases the acquired slot.
`SearchIndexWriter` serializes staging and rejects truncated observations,
fragment/byte overflow, and insufficient capacity. A sentinel node detects
truncated directory/page/spine listings. Limits and retry policy are documented
in `doc/source-adapters.md`; failure cleanup and final publication remain
generation/active-plan guarded database transactions.

Quick Look is explicitly skipped because it offers no structured text. Other
adapter errors cannot silently skip readable content and publish a partial index.
