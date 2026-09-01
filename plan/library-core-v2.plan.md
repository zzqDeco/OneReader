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

- `swift test` passes 30 tests. The storage suite covers file and directory
  import, package-descendant identity, symlink rejection, digest reuse,
  missing/corrupted copy repair, crash-orphan adoption, injected 4 GiB/2 GiB
  policy paths, shared-byte removal, and Trash behavior.
- Two AppModel persistence-safety tests force database initialization failure:
  valid `progress-v2.json` is loaded before saving, while an unsupported current
  schema remains byte-for-byte untouched after user state changes.
- `testInitializesVersionedSchemaInWALMode` verifies the temporary Application
  Support tree (`Library.sqlite`, `Sources`, `Snapshots`, `Derived`,
  `Artifacts`, `Legacy`, `.Staging`), WAL, and schema metadata. The legacy test
  verifies the backup bytes, relative destination, and
  `boundToNewObjects=false` manifest detail.
- A real development launch migrated
  `progress-v1.json → Legacy/progress-v1-20260828-094102.json`; the SQLite row
  retained kind `legacy-progress-v1`, both paths, and the unbound detail. New
  compatibility progress writes to `progress-v2.json`.
- `swift build --configuration release`, the documentation index (49 Markdown
  files), `scripts/package-app.sh`, strict codesign verification, and
  `git diff --check` pass on the candidate tree. The packaged Info.plist reports
  `0.2.0` / macOS `26.1`; entitlements are App Sandbox, network client, and
  user-selected read-only files.
- Native launch on macOS 27 showed an empty Library without a demo/network
  request. The accessibility tree exposed the sidebar, search field, empty-state
  import guidance, route inspector, toolbar controls, and labels.
- Integrated final review is owned by a Sol max sub-agent on the exact release
  candidate; prior slice-level reviewer claims are not promotion evidence.

## Non-goals

Format-specific parsing, network refresh, model invocation, full reading UI,
cloud storage, account identity, and destructive cleanup of user documents.

## Delivery Checklist

- [x] User behavior implemented
- [x] Contracts and migration implemented
- [x] Focused tests pass
- [x] Unified validation passes
- [x] Native acceptance recorded
- [x] Current-state and source docs synchronized
- [x] Branch merged into `dev`
- [ ] Integrated Sol max review accepted and status changed to Delivered
