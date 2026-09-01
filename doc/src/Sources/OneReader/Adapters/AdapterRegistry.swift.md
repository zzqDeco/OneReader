# `Sources/OneReader/Adapters/AdapterRegistry.swift`

Owns the closed, host-defined registry of built-in adapters. It runs
deterministic probes, chooses the highest-confidence primary adapter, records
all probe evidence, and computes per-capability routes without allowing callers
or models to invent adapter IDs.

A throwing format probe is converted to redacted failure evidence and probing
continues, allowing the Quick Look fallback to remain available for damaged or
legacy-encoded regular files.

The registry checks both the declared capability and the corresponding Swift
protocol conformance before dispatch. Read/search limits are bounded at the
registry edge. `AdapterCoordinator.swift` reconstructs contexts from managed
database records, persists plans and Observations, composes directory child
adapters, expands every PDF page and EPUB spine item during indexing, and owns
the active-plan-bound FTS projection.

Locators are accepted only for their exact Source, Snapshot, adapter, and schema.
Cross-revision work must call Resolve and receives an explicit current,
relocated, or orphaned result.
