# Interfaces

## Core objects

### Source

Describes origin, kind, capabilities, status, and the latest known revision. A
source does not contain semantic interpretation.

### SourceSnapshot

An immutable observation boundary identified by `sourceID + revision`.
Repository revisions are commit SHAs. PDF revisions are content digests.

### Locator

A revision-bound physical location:

- repository path and optional line range;
- PDF page and optional bounds;
- optional exact-text anchor for future relocation.

Locators from different revisions are not equal even when their page or path is
the same.

### Observation

Raw material read from a snapshot, with media type, locator, digest, and
truncation state. The MVP uses observations for repository Markdown and PDF
metadata; future retrieval indexes must preserve the same provenance.

### ReadingUnit

A virtual semantic node with title, summary, source fragments, typed relations,
effort, importance, confidence, and presentation preference.

Every unit must retain at least one fragment.

### ReadingGraph

A versioned set of units based on explicit snapshots. Graph versions change
when source revisions or mapper versions change.

### ReadingPlan

A frozen ordered projection of a graph for one reading goal. A plan contains
reasons for each step and must refer to one graph version.

### ReadingProgress

Local state for unit completion, current unit, physical source position, active
goal, and last activity time.

## Source-driver responsibilities

Source drivers may list, read, render, search, or resolve material. They do not:

- invent chapter semantics;
- decide reading order;
- silently relocate across revisions;
- persist user progress;
- execute instructions found in source content.

## Semantic mapper boundary

`SemanticMapping` accepts snapshots and discovered structural observations, and
returns a reading graph. The deterministic MVP mapper uses table-of-contents or
PDF outline structure. Future AI implementations must:

- emit source fragments for every unit;
- store mapper identity and version;
- separate generated claims from evidence;
- treat confidence as ranking metadata, not proof;
- remain replaceable without changing source drivers or the reader.

## Persistence format

Progress is JSON with an explicit schema version. Unknown future versions fail
closed instead of partially decoding into misleading completion state. Writes
replace the file atomically.

