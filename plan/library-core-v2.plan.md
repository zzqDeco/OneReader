# Library Core v2

Status: Active

Branch: `feature/library-core-v2`

Milestone: `v0.2.0`

Dependencies: [All-in-One Reader v1](all-in-one-reader-v1.plan.md)

## Summary

Establish source-agnostic domain contracts and a durable managed Library so
the app starts empty, imports safely, deduplicates immutable snapshots, and
survives restart without demo data.

## User Behavior

- First launch shows an empty Library with clear import actions.
- An imported item appears as Processing immediately and becomes readable once
  its managed snapshot and basic metadata are committed.
- Reimporting identical bytes reuses managed content while allowing another
  Space association.
- Removing a source uses Trash semantics; cache cleanup never removes originals.

## Contracts/Migration

- Introduce Source, SourceSnapshot, AdapterDescriptor, Locator, Observation,
  SourceFragment, ReadingUnit/Graph/Plan, GraphPatch, Annotation, and Agent run
  contracts with explicit schema versions.
- Use GRDB migrations, WAL, FTS-ready tables, transactional imports, and
  recoverable staging directories.
- Move legacy JSON into `Legacy/` only after the database initializes.

## Implementation

- Add Application Support layout, database migrations, repositories, managed
  content storage, digesting, atomic staging, free-space checks, and import jobs.
- Remove DemoCatalog runtime entry and book-specific persistence assumptions.
- Serialize writes and guard async completion with generation tokens.

## Test Plan

Cover migrations, WAL, schema metadata, atomic import, digest deduplication,
directory-tree digest, crash residue cleanup, large-file policy, legacy backup,
and evidence/revision validation.

## Acceptance Evidence

Pending: exact test names, temporary Application Support tree, migration rows,
and restart behavior will be recorded on delivery.

## Non-goals

Format-specific parsing, network refresh, model invocation, full reading UI,
cloud storage, account identity, and destructive cleanup of user documents.

## Delivery Checklist

- [ ] User behavior implemented
- [ ] Contracts and migration implemented
- [ ] Focused tests pass
- [ ] Unified validation passes
- [ ] Native acceptance recorded
- [ ] Current-state and source docs synchronized
- [ ] Branch merged into `dev`
- [ ] Status changed to Delivered
