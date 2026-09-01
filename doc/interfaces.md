# Interfaces

## Core objects

### Source

Owns stable identity, a user-facing description, origin descriptor, managed
state, latest snapshot pointer, and timestamps. It deliberately contains no
format semantics or adapter choice.

### SourceSnapshot

An immutable observation boundary with its own ID, source ID, revision kind,
revision value, digest, managed relative path, byte count, and observation
time. Git repositories use commit SHAs; directories use a sorted tree digest;
other managed sources use a content or web-snapshot digest.

### AdapterDescriptor and AdapterPlan

An adapter descriptor declares ID, version, deterministic probe rules,
capabilities, and limitations. An adapter plan binds one snapshot to a primary
adapter, optional helpers, per-capability routing, probe evidence, confidence,
reason, and optional user override. Adapters never become Source identity.

### Locator

A locator is scoped by source ID, snapshot ID, adapter ID, locator schema, and
opaque adapter payload. Structural path, exact text quote, and fingerprint are
portable recovery hints. Positional payload from another revision is never
silently accepted as current.

### Observation

Raw material read from a snapshot with locator, media type, digest, truncation,
and inline or artifact-backed content reference. Observation text is untrusted
tool data.

### SourceFragment

The evidence boundary used by ReadingUnits, generated claims, annotations, and
answers. It always retains an exact snapshot-bound Locator.

### ReadingUnit, ReadingGraph, and ReadingPlan

A ReadingUnit is a virtual semantic node and must have at least one valid
SourceFragment. A ReadingGraph versions units and relations against explicit
snapshots. A ReadingPlan is a frozen ordered projection of exactly one graph
version for overview, systematic, review, or a free-form goal.

### GraphPatch

The only Agent-facing graph mutation proposal. The host checks schema, source
and snapshot identity, adapter registration, locators, evidence, confidence,
relations, and base graph version before a transaction can commit it. Models do
not receive database-write tools.

### Annotation and progress

Bookmarks, highlights, and notes bind to capability-supported Locators and
carry current, relocated, or orphaned state. Progress separately records source
position, unit completion, frozen plan step, and history.

### AgentRun, AgentEvent, and AgentArtifact

Persist queue/running/wait/completed/failure/cancellation/interruption state,
ordered user-visible activity, and large immutable artifacts. Events describe
actions and validation facts, never hidden reasoning.

### ProviderProfile and ReadingAgentSession

A Provider profile stores provider kind, endpoint, user-supplied model ID,
timeout, optional context limit, tested capabilities, and only a Keychain
reference. Apple on-device and loopback Ollama profiles are local; OpenAI
Responses and Anthropic Messages profiles require HTTPS and a one-time
per-Space-and-canonical-destination disclosure before any fragment is sent.

A ReadingAgentSession is the sole mutable runtime owner for one Space. Each run
binds its generation token and the host-derived exact Source/Snapshot manifest;
both invalidate late model/tool results. Restart changes queued, running, or
waiting runs to interrupted and records the matching event; network work
resumes only through an explicit new run, and one interrupted/disclosure parent
can create at most one linked child. Low-confidence adapter output is a
persisted candidate with separate local confirm/dismiss behavior, not a
resumable network operation.

Structure-pipeline requests additionally persist host-owned provenance. Resume
continues from the task's next phase, while standalone questions and completed
route projection schedule nothing further. An interrupted Run may be abandoned
as an auditable terminal state; Provider or Source binding changes cancel stale
interrupted Runs automatically. Explicit cancellation is scoped to the captured
Run ID and cannot target a later replacement. Every App-level Provider mutation
reloads the selected Space's persisted Run projection after invalidation, so UI
recovery controls reflect the terminal database state immediately.

## Capability responsibilities

Adapters may independently implement Probe, Revision, List, Read, Search,
Render, and Resolve. The registry composes only declared capabilities. An
adapter does not:

- invent reading semantics;
- decide the user's route;
- silently relocate across revisions;
- persist user state;
- execute source instructions;
- fetch model endpoints or write source files.

## Persistence contract

`Library.sqlite` is opened through a GRDB `DatabasePool`, which provides WAL
mode for concurrent reads and serialized writes. Schema versions are explicit
in metadata and migrations. Large payloads remain in managed content or
Artifact files and are referenced by relative path and digest.

Local import copies to `.Staging`, verifies the copied digest, atomically moves
to content-addressed `Sources/`, then commits source/snapshot/Space rows. A
failed database commit removes only a newly created unreferenced managed copy.
Capacity thresholds are injected at the storage boundary for deterministic
tests; deduplicated bytes are not charged twice.

Source removal is a two-system transaction: exclusively owned managed
containers move to Trash before the database marks the Source removed and
deletes its Space memberships. The database side also deletes Source-bound
annotations/history, clears its position, invalidates affected graphs/frozen
plans and route progress, cancels active Agent runs, and advances durable
session generations. Shared containers remain referenced. If the database
commit fails, the host attempts to restore moved containers from Trash.
Original selected files and directories are never removal targets.

Legacy JSON is backup input only. It is never treated as a valid new graph,
plan, source position, or completion record. Current reader state is stored in
GRDB only; `progress-v1.json` is eligible for one unbound legacy backup and is
never reused as live storage.

Agent structured output never writes through a model tool. The host first
validates schemas, the run's exact manifest, freshly reprobed registry
capabilities, deterministic evidence, saved Observations, graph versions, and
frozen-plan unit IDs. Validation produces no side effect. One GRDB transaction
then compares the session generation and run state, rechecks the manifest,
commits the domain object and structured output, activates any accepted
AdapterPlan, transitions the run, and
appends the terminal event. Full transcripts remain durable even when the
smaller model projection replaces large results with Artifact handles or
structured summaries. Every model-call audit records an outcome and observed
byte bounds. Output seen before a streaming or summary failure is append-only
`partialFailure` audit data and is never installed into the mutable resumable
session transcript. Its model-call metric and optional partial record commit in
one transaction with a database-assigned sequence; a matching terminal
cancelled Run can finish only this immutable audit after a newer generation is
active. Oversized partial content is replaced by a digest/byte-count marker.
Provider stream entries are normalized to the delta contract before
aggregation; Anthropic cumulative prefixes must extend the prior prefix or the
call fails closed.

Provider endpoint changes are normalized and validated before persistence.
Disclosure rows also retain a hash of Provider kind plus canonical effective
endpoint, preventing a profile ID from carrying consent to a different
destination. Source refresh is committed only through an orchestrator that
first cancels live model work and then updates the Snapshot pointer, affected
run states, outputs, events, and durable session generations transactionally.

## Adapter execution contract

`AdapterCoordinator` reconstructs a context only from committed Source and
Snapshot rows plus a managed relative path. It rejects missing managed bytes,
persists deterministic AdapterPlans, and stores read Observations as evidence.
Search uses a distinct projection keyed to the active Snapshot/AdapterPlan pair;
staging can publish only while that pair still matches. Directory indexing
expands PDF pages and EPUB spine items, and child locators are resolved below
the managed root without following symlinks. Web snapshot locators remain
bound to the snapshot root rather than being mistaken for ordinary child files.

Remote fetching is outside every adapter and outside the Agent runtime. A
remote import commits through the same `ManagedLibrary` transaction as a local
source, with the original URL retained only as origin metadata.
