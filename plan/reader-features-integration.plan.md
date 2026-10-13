# Reader features integration

## Status

Active. Integrates issues #25, #26, #27 and #28 only.

## Branch

`feature/reader-tools-integration` from `dev` at `a3c5b241d8678c806cf2f4a5d04cf21c2f909063`.

## Milestone

Next reader feature increment; publication requires a separate decision.

## Dependencies

Capture/inbox, global notes/export, bilingual reading and local OCR topic branches. Preserve the
existing native reader, managed snapshots, position invariants and provider consent boundary.

## Summary

Implement four independent feature slices in isolated worktrees, then integrate shared models,
migrations, menus and reader hooks. Root owns final integration and evidence-bound acceptance.

## User Behavior

Collect into an inbox, organize and open sources, recover reading positions, annotate and export
notes, optionally translate real text, and locally recognize scanned pages without changing originals.

## Contracts / Migration

Reserved migrations: capture v11, notes v12, translation v13, OCR v14. Stable annotation IDs and
revision-specific locators connect features. Translation never guesses OCR and no feature bypasses
remote-data consent. Review final schema ordering, index identity and generated Xcode project.

## Implementation

1. Parallel narrow topic branches, plans and tests.
2. Integrate complete commits without discarding shared hooks.
3. Build/test combined migrations, import-to-read-to-annotate-to-export and OCR-to-translate paths.
4. Native isolated macOS acceptance, physical-iPhone regression and independent Sol max review.
5. Focused PRs with current-head CI. No automatic main promotion or release.

## Test Plan

Run the shared native validator and cross-feature tests; no real model secrets in CI. Record actual
device visibility separately from unit/build results. Preserve production apps, Library and sources.

## Acceptance Evidence

Pending. A feature remains open while its required implementation or acceptance is incomplete.

### Capture / notes / bilingual merge slice

Resolve the delegated capture merge without replacing existing notes or bilingual
hooks. Preserve ordered migrations v11 → v12 → v13 and metadata 13/runtime 6,
all native entrypoints and documentation rows. Regenerate the project and run
static checks before committing the merge. A subsequent focused cross-feature
test will verify capture organization, notes identity/export and translation
cache isolation with only generated fixtures. OCR v14 and full native/device/CI
validation remain with the root integrator.

The merged capture startup adds an async recovery suspension. A cold local
notes link now waits for the owning bootstrap rather than invoking a second
concurrent bootstrap. Invalid notes routes are rejected before entering the
capture path. Focused regressions cover this interaction and cross-feature
source/annotation/progress identity; they do not run a Provider.

- Merge commit `f3b211b0eed0e8230046d966e66f92e646282467` integrates capture
  `7acbf652250ebba68005520ddfd3d22625229228` with notes and bilingual reading.
- 2026-10-13: `swift test --jobs 2 --filter
  'ReaderFeatureIntegrationTests|CaptureInboxTests|NotesCenterTests|NotesExportTests|NotesNavigationTests|TranslationTests|ReleaseMetadataTests|LibraryDatabaseTests'`
  passed 57 tests with zero failures in 3.274 seconds after the first debug build.
  The two new integration tests verify ordered 11/12/13 migrations, original
  Annotation/progress retention after captured-source organization, source
  search/private-note/translation-cache separation, and cold notes-link routing.
  Translation data is a generated cache fixture; no real model or network call
  is made by the new tests.
- XcodeGen regeneration, 89-file documentation index, 28-slot Apple metadata,
  project consistency, entitlement fixtures and whitespace checks pass. Dependency
  pins and release versions are unchanged. No release, Xcode/device or production
  operation was performed; OCR 14 and final acceptance remain separate.

### OCR integration slice

- `21d0a99` integrates OCR `d58276c` while preserving all native entrypoints and
  ordered migrations v11 → v12 → v13 → v14. Release metadata is DB14/runtime6.
- OCR topic validation: 283 macOS tests, zero skips/failures; 21 physical-iPhone
  hosted tests, zero failures, including real local Chinese/English recognition.
  Accurate Vision revision 2 is the validated macOS compatibility pipeline;
  iOS uses revision 3. The actual engine is recorded in immutable OCR evidence.
- Integration additionally adapts native-image and mixed-PDF translation reads.
  Full OCR pages become bounded, readable UTF-16 evidence fragments; repeated
  selected OCR lines use verified span offsets. Native PDF pages are not
  reinterpreted as OCR. `OCRFeatureIntegrationTests` passes the complete generated
  capture → image → OCR → source-fragment → notes/export path, old evidence after
  re-recognition, original-byte/position retention and four-migration ordering.
- Full integrated/native/visible acceptance and Sol max conclusions remain gates,
  not implied by topic or cross-feature test success. No real Provider is called.

### Reviewer repair integration and final candidate

- Code candidate `37f53db36d99d1405ebdaa8ad36187b83189d8ad` integrates bilingual
  `c91b5b7`, capture `13470ee`, notes `fd61ee7` and OCR `b4f837a` review repairs.
  Source code remains DB14/runtime6 with ordered v11/v12/v13/v14 migrations.
- 2026-10-13: full integrated `swift test --jobs 2` passes 363 tests, zero skips
  and failures. This includes generated fixtures and real local Vision, but no
  real Provider call. The 10,000-note pagination fixture reads 50 bounded pages
  in 0.464 seconds on the local host; this is not a UI frame-rate benchmark.
- OCR topic `b4f837a` passes 298 macOS tests and 22 hosted tests on the connected
  physical iPhone 18 Pro Max. The latter includes the production native
  mixed-PDF selection bridge, actual bilingual Vision, native OCR overlay/image
  geometry and position, and twelve PDF zoom contracts. These are topic tests,
  not integrated share-extension or manual-gesture acceptance.
- The repaired contracts reject late OCR plan activation/index publication and
  stale Agent finalization atomically, repair old active pointers at startup,
  retain old evidence, and preserve each carried/resumed page's actual processing
  provenance. Native PDFKit text selection does not inherit an OCR locator.
- Current dependency, documentation, generated-project, Apple metadata,
  entitlement/release fixtures and whitespace checks pass. Final release
  packaging, unsigned iOS app/share build, exact-head CI and final Sol max
  conclusions are separate pending gates.
- The isolated macOS preview visibly imports a generated image and produces four
  bilingual OCR lines. It is a pre-final candidate. Native mouse input currently
  reports `noWindowsAvailable`; selection/search/notes/export/restart acceptance
  has not been substituted with automated results. The preview was quit normally
  through its application menu; its isolated Library is preserved for the rebuild.
- Integrated iPhone signing is pending provisioning support for the isolated
  `group.io.github.zzqDeco.OneReader.features-preview.capture` App Group. No
  production group, trust, or security setting is altered to bypass this gate.
  No Simulator is created or booted, and no main/release mutation is performed.

## Non-goals

iPad device acceptance, hosted Xcode migration, cloud sync, distribution/signing and v0.3.3 rework.

## Delivery Checklist

- [ ] Four feature slices implemented and individually tested.
- [ ] Integrated data migrations and native build tested.
- [ ] Cross-feature and physical/visible acceptance recorded.
- [ ] Sol max conclusions resolved and current-head CI green.
- [ ] Documentation, issue evidence and focused PR handoff complete.
