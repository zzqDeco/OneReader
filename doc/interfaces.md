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

The compatibility Repo/PDF native locator remains only until the adapter slice
finishes migrating the existing vertical-slice readers.

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
deletes its Space memberships. Shared containers remain referenced. If the
database commit fails, the host attempts to restore moved containers from
Trash. Original selected files and directories are never removal targets.

Legacy JSON is backup input only. It is never treated as a valid new graph,
plan, source position, or completion record. Transitional live progress uses
`progress-v2.json`; only `progress-v1.json` is eligible for legacy backup.
