# Native reader UI polish

Status: Active

Branch: `feature/native-ui-polish`

Milestone: Reader-features visual refinement; no release in this slice.

Dependencies: [Reader features integration](reader-features-integration.plan.md),
PR #33 merged to `dev` as `002ee65` on 2026-10-14; its dev CI passed.

## Summary

Improve the macOS and iPhone interface in parallel with functional acceptance of
the local reader features. Keep UI changes out of #33: the new branch starts from
dev and is aligned with the merged integration commit as a dependency. Bilingual
reading remains deferred, with its product entrypoints disabled.

## User Behavior

The Library is a calm, browsable shelf with a clear continue-reading entry and
quiet capture status. Notes, OCR and capture controls have a consistent native
hierarchy instead of oversized forms and repeated metadata. macOS retains useful
density; iPhone respects safe areas, touch size and Dynamic Type.

## Contracts/Migration

No schema, snapshot, locator, Provider, consent, cache or signing changes. Do not
modify PDF/image/text bridges, scroll capture or evidence semantics. Preserve
action accessibility identifiers, independent buttons, keyboard shortcuts and
the persistent native `notes-export` control. No new dependencies or demo data.

## Implementation

- Use existing system typography, semantic light/dark colors and restrained teal.
  UI/UX Pro Max's general landing-page recommendation is not an app shell; apply
  its native SwiftUI accessibility/layout guidance rather than marketing heroes.
- Normalize 4/8/12/16/24 point spacing, section headings, dividers, metadata,
  cards and action sizes across Library, reader navigation and assistance sheets.
- Prioritize Library/reader chrome and the new notes/OCR/bilingual/capture flows.
  Preserve the reading canvas and avoid nested decorative glass/shadows.
- Use adaptive layout and separate accessibility children for multi-action rows.
- Root owns final integration and native visible acceptance; the UI implementer
  owns only UI/design/docs/tests, not product runtime or production data.

## Test Plan

Focused mounted-control and layout regressions, full shared tests, release build,
unsigned iOS app/share build, doc/project checks and current-head hosted CI.
Reuse existing build caches and serialize compilation; do not create or boot a
Simulator. Sol max reviews final source/test changes and reports conclusions.

Native macOS light/dark, wide/narrow Library/notes/assistance screenshots and
keyboard/action checks are separate from build proof. iPhone UI proof is only
claimed when actually obtained; signing work and iPad hardware remain deferred.

## Acceptance Evidence

Implementation is present on the topic branch: quiet generated spine covers,
Library hierarchy, named navigation/Inspector tabs, adaptive action groups,
notes filters/results/export hierarchy, import and capture controls, OCR density.
Three focused metrics/mounted-export regressions are added. The implementer did
not run Swift/Xcode builds, create DerivedData, create/boot a Simulator or operate
native controls; root owns serialized builds and visible acceptance. Static doc
index and diff checks are recorded in the branch handoff. No screenshot, fake
model or compile substitutes for actual UI behavior.

Root validation of runtime tree `ecf326c` on 2026-10-14:

- All 379 shared tests passed, with no skips or failures, including actual Vision
  OCR and the mounted persistent export-control test. The test class was made
  `@MainActor`; product bridge/runtime code was not changed by this correction.
- macOS release build, exact dependency-lock check, documentation index (94
  Markdown files), generated Xcode project, Apple metadata, Sandbox app assembly,
  strict ad-hoc codesign and entitlement checks passed. App resources and pins are
  unchanged from merged dev; assembly reused those resources with the new release
  executable and the existing shared Swift build cache.
- The unsigned generic-device iOS app and Share extension compiled successfully,
  reusing the single retained feature DerivedData directory. No Simulator was
  created or booted. This is compilation proof, not physical-device acceptance.
- Sol max reviewed the UI source/test delta and final alignment; no blocking
  findings. The review does not substitute for visual/device acceptance.
- The isolated `OneReader Features Preview` was normally quit, its prior app
  bundle retained, and the new UI executable reopened against the same test-only
  Library. No production Library, Provider or source content was used.
- Actual macOS observations covered the wide Library, the compact-window menu,
  light Library/notes, dark reader/notes/OCR/export, compact assistance overlay,
  native scrolling inside OCR/export forms and named navigation/Inspector tabs.
  The fixture image preserves its original white pixels in dark mode. The
  reading-theme preference is not a new global Library theme control.
- A real notes-row **return-to-original** click showed the original snapshot and
  matched Chinese OCR region. The **edit** action opened the existing note and
  was cancelled without changing it. Type filtering showed the two note records.
  OCR's per-line **locate** selected the real seven-character Chinese quote;
  the reader **highlight** action persisted a second highlight and Inspector
  readback showed both highlights and both retained notes.
- The persistent native `notes-export` button and `Command-Shift-E` both opened
  the export configuration. Generating its preview produced two annotations from
  one Source, with the privacy options and snapshot boundary visible. The final
  directory write was not repeated in this visual-only UI delta; the dependency's
  completed native export and data regression remain separate evidence.

Remaining gates: current-head hosted CI, physical iPhone compact/Dynamic Type
visual acceptance (signing work remains deferred), and explicit UI merge approval.
Full VoiceOver, Reduce Motion and manual touch/gesture acceptance are not claimed.

Scope update: the user deferred the heavy bilingual feature. Its UI file,
translation runtime/cache/schema and Provider setup are untouched in this
refinement; the host availability gate is a separate integration dependency.

## Non-goals

Release, main promotion, signature/provisioning configuration, iPad hardware,
redesigning native presentations, new product features, model/network changes.

## Delivery checklist

- [x] User behavior implemented (visual refinement; native acceptance pending)
- [x] Existing contracts preserved (static boundary check and 379 shared tests)
- [x] Focused tests pass
- [x] Local validation passes (unsigned iOS build; no Simulator)
- [ ] Current-head hosted CI passes
- [x] macOS visible acceptance recorded
- [ ] iPhone compact/Dynamic Type native acceptance recorded
- [x] Current-state and source docs synchronized
- [ ] Branch merged into `dev`
- [ ] Status changed to Delivered
