# Native reader UI polish

Status: Active

Branch: `feature/native-ui-polish`

Milestone: Reader-features visual refinement; no release in this slice.

Dependencies: [Reader features integration](reader-features-integration.plan.md), PR #33.

## Summary

Improve the macOS and iPhone interface in parallel with functional acceptance of
the four reader features. Keep UI changes out of #33: the new branch starts from
dev and includes the validated integration commit as a dependency.

## User Behavior

The Library is a calm, browsable shelf with a clear continue-reading entry and
quiet capture status. Notes, OCR and bilingual controls have a consistent native
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

Scope update: the user deferred the heavy bilingual feature. Its UI file,
translation runtime/cache/schema and Provider setup are untouched in this
refinement; the host availability gate is a separate integration dependency.

## Non-goals

Release, main promotion, signature/provisioning configuration, iPad hardware,
redesigning native presentations, new product features, model/network changes.

## Delivery checklist

- [x] User behavior implemented (visual refinement; native acceptance pending)
- [x] Existing contracts preserved (static boundary check; runtime tests pending)
- [ ] Focused tests pass
- [ ] Unified validation passes
- [ ] Native acceptance recorded
- [x] Current-state and source docs synchronized
- [ ] Branch merged into `dev`
- [ ] Status changed to Delivered
