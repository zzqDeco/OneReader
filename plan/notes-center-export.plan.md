# 全局笔记中心与 Markdown 导出

Status: Active

Branch: `feature/notes-center-export`

Milestone: Unassigned

Dependencies: Existing Annotation, Locator resolution and managed Library.

## Summary

Implement issue #28 as a native Library entry that pages existing annotations,
supports independent private-note search and tag management, and exports an
explicitly selected static Markdown package with validated local deep links.

## User Behavior

- Browse, search and filter all annotations by source, Space, kind, tags and date.
- Edit the original annotation, manage tags, confirm deletion and return through
  existing locator resolution; preserve retained text when an anchor is unavailable.
- Preview selected/filter/Space export scope and fields, then explicitly choose a
  local destination. Export is cancellable and never silently overwrites files.

## Contracts/Migration

- Reserve uniquely named schema migration v12. Original IDs, locators, timestamps,
  snapshots and progress stay unchanged; tags start empty.
- Tags are stable-ID relationships; normalized names are unique. Rename collisions
  require explicit merge confirmation; deleting a tag deletes only relationships.
- A separate, rebuildable note-search projection never enters source search or
  Agent tools. Stable keyset pagination uses creation time plus annotation ID.
- Versioned deep links contain only local IDs, validate all referenced identities,
  and do not import, refresh, fetch, run providers, or carry file paths/private text.
- Markdown filenames and text are sanitized. Exports are static copies, committed
  atomically as a new directory; no absolute sandbox paths or original attachments.

## Implementation

1. Add domain/query/tag/export contracts and persistence plus bounded regressions.
2. Add native notes list, filters, tag editor and safe mutation commands. Integrate
   Library entry and existing Inspector refresh using the same records.
3. Resolve original snapshots with existing adapters; add strictly validated local
   routes, Markdown renderer and cancellable export preparation/publication.
4. Synchronize current-state/source docs, run bootstrap and targeted tests with at
   most two compiler jobs. Root owns merged-schema/native/device acceptance.

## Test Plan

Migration preservation; deduplication by ID; Unicode/tag collisions; combined
filters and 10,000-row keyset pagination; private-search isolation/rebuild;
edit/delete concurrency; safe URL validation; deterministic Markdown escaping,
filename collisions and traversal; cancellation and no-overwrite publication.

## Acceptance Evidence

- Implemented on base `a3c5b241d8678c806cf2f4a5d04cf21c2f909063` with native
  Library/Inspector entrypoints and original-snapshot preview.
- `scripts/bootstrap-dependencies.sh` configured the repository mirror. No
  dependency pins or release versions changed.
- `swift test --jobs 2 --filter Notes`: 14 tests, zero failures on 2026-10-13
  (13 new Notes tests plus the existing matching redaction test). This also
  compiled the shared module and native SwiftUI views. A later related-regression
  pass is recorded below before handoff.
- Final related regression: `swift test --jobs 2 --filter
  'Notes|ReaderPersistenceTests|LibraryDatabaseTests|AppModelLibraryTests'` passed
  68 tests with zero failures in 7.323 seconds. Two old schema-10 assertions were
  updated to the active schema constant after this migration raised it to 12.
- Generated 10,000 annotations: 50 pages of 200 in 0.6752 seconds for the measured
  query loop. The test process peak RSS changed from 58,949,632 to 59,473,920 bytes
  on macOS 27.2 build 26B5091g. This is a bounded data-layer measurement, not an
  application/UI or arbitrary-scale performance guarantee.
  The final combined run measured 0.4479 seconds with test-process peak RSS
  77,332,480 → 83,542,016 bytes; process high-water marks include prior test work.
- Export golden text, hostile Markdown/filenames, static capture, cancellation,
  existing-file preservation and injected disk-full failure have automated proof.
- Documentation index, Apple metadata, Xcode project consistency, entitlement
  fixtures and `git diff --check` passed. The macOS entitlement now allows writing
  only to user-selected locations; imports retain read-only source bookmarks and
  Agent tools gain no filesystem-write capability.
- No production Library, real user exports, Provider calls or Simulator/device
  sessions were used. Root owns full merged schema, platform builds, native
  macOS/iPhone/VoiceOver acceptance, cold URL routing and hosted CI.

## Non-goals

Cloud sync, AI note rewriting, OCR/translation, iPad hardware acceptance, releases,
dependency upgrades, distribution, or edits to other feature worktrees.

## Integration touchpoints

New implementation lives in `NotesModels.swift`, `NotesPersistence.swift`,
`NotesMarkdownExporter.swift`, `NotesCenterModel.swift`, `NotesCenterView.swift`,
`NotesTagManager.swift`, and `NotesExportView.swift`.

Shared edits to compose with the parallel features:

- `Sources/OneReader/Persistence/LibraryDatabase.swift`: register the standalone
  `registerNotesMigration` after v10 and set branch schema to 12. Root should
  compose capture v11, notes v12, translation v13 and OCR v14 in order and set
  the final schema/runtime metadata once.
- `Sources/OneReader/Persistence/ReaderPersistence.swift`: expose the existing
  Annotation decoder internally; no second Annotation serialization contract.
- `Sources/OneReader/App/AppModel.swift`: initialize notes model, refresh
  Inspector after mutations, invalidate the global notes list on Library
  refresh, route strictly validated local notes URLs, and retain exact-snapshot
  preview without replacing progress/history or starting indexing.
- `Sources/OneReader/App/OneReaderApp.swift`: Shift-Command-N notes command.
- `Sources/OneReader/UI/LibraryHomeView.swift` and `LibrarySidebarV2.swift`: native
  Library entrypoints; `WorkspaceViewV2.swift`: notes sheet.
- `Sources/OneReader/UI/ReaderInspectorView.swift`: shared editor and confirmed,
  version-checked deletion; `ReaderSurfaceV2.swift`: original-snapshot banner.
- `project.yml`, `Resources/Info.plist`, and `Resources/Info-iOS.plist`: register
  only the `onereader` URL scheme. Regeneration produced no pbxproj change.
- `Resources/OneReader.entitlements`, `scripts/check-app-entitlements.sh`, and
  `scripts/test-entitlement-gate.sh`: user-selected read/write for explicit
  local export, with broad write exceptions rejected. Read-only original-source
  bookmarks and the read-only Agent tool contract are unchanged.
- `Tests/OneReaderTests/LibraryDatabaseTests.swift` and `AppModelLibraryTests.swift`:
  assert the active schema version rather than the former hardcoded 10; the
  former also verifies a UUID local notes-Library identity. Root will advance
  the shared runtime-schema expectation with translation.
- Documentation/indexes: `README.md`, `doc/README.md`, `doc/apple-platforms.md`,
  `doc/architecture.md`, `doc/reader-workspace.md`, `doc/src/README.md`,
  AppModel and LibraryDatabase source notes, plus `plan/README.md`.

Native file-picker delivery, installed custom-URL dispatch, PDF/EPUB/HTML/
Quick Look notes navigation, narrow layouts, VoiceOver, restart, signed package
and required CI remain integration acceptance. No worker merge, push or PR.

## Delivery checklist

- [x] User behavior implemented
- [x] Contracts and migration implemented
- [x] Focused tests pass
- [ ] Unified validation passes (root integration)
- [ ] Native acceptance recorded (root integration)
- [x] Current-state and source docs synchronized
- [ ] Branch merged into `dev` (not authorized in worker)
