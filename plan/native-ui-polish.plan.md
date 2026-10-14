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
The Notes model may publish transient read outcomes and fence late opening
errors for the UI; its queries, pagination and database transactions do not change.

## Implementation

- Use existing system typography, semantic light/dark colors and restrained teal.
  UI/UX Pro Max's general landing-page recommendation is not an app shell; apply
  its native SwiftUI accessibility/layout guidance rather than marketing heroes.
- Normalize 4/8/12/16/24 point spacing, section headings, dividers, metadata,
  cards and action sizes across Library, reader navigation and assistance sheets.
- Prioritize Library/reader chrome and the new notes/OCR/bilingual/capture flows.
  Preserve the reading canvas and avoid nested decorative glass/shadows.
- Use adaptive layout and separate accessibility children for multi-action rows.
- During native return-to-Library acceptance, the automatic continuation progress
  indicator collapsed to a tiny dot. Use an explicit linear style with a bounded
  nonzero minimum track width, and cover initial/replaced content in a mounted
  compact-layout regression. This changes only progress display, not capture.
- Root owns final integration and native visible acceptance; the UI implementer
  owns only UI/design/docs/tests, not product runtime or production data.

### Continuation: compact reading controls and state clarity

The user requested direct continued UI implementation on 2026-10-14. Continue
on PR #34; this is not permission to merge the UI PR or publish a Release.

- Refine the reader's chrome: a stable, quieter title/action hierarchy, footer
  actions that remain usable at Mac compact width, and compact iPhone controls
  that do not clip at enlarged Dynamic Type. Keep source presentation identity,
  PDF scale requests, position observers, navigation and all action IDs intact.
- Mount the Library continuation/shelf at compact widths with long titles and
  enlarged Dynamic Type; stack its cover/copy when necessary rather than merely
  testing a width token. Preserve the repaired linear progress track and all
  Library actions, without changing progress values or persistence.
- Keep notes loading, debounce, genuine empty result and failure distinct. A
  pending first/filter reload must not briefly claim that there are no notes.
  UI refresh projection must reject a pending, cancelled or mismatched completion; do
  not change database queries, pagination or the export snapshot contract. A
  transient Notes-model read receipt/error fence is allowed to keep load outcomes
  distinct from mutable action errors and to support shared mounted sheets.
  Each read starts with a pending generation receipt. A cancelled current owner
  has a retryable paused outcome, and the UI always projects the latest receipt,
  so returning to an earlier query cannot resurrect its obsolete success.
- Show localized annotation status in ordinary notes/Inspector chrome; retain
  exact revision and anchor state in explicit evidence details. Historical,
  relocated and orphaned states remain visibly distinct, never relabeled current.
- Add focused layout and view-state regressions. Reuse current caches; only root
  compiles/packages or controls Apps. Separate implementation ownership avoids
  conflicting edits, and Sol max reviews immutable checkpoints/conclusions only.
- Validate the Mac preview and attempt connected-iPhone layout acceptance only
  using already available signing/provisioning. Do not configure capabilities,
  certificates, account access, or create/boot a Simulator to unblock it.

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
Four focused metrics/mounted-control regressions are added. The implementer did
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

Progress-display follow-up after `71b15ad`:

- The mounted compact/enlarged-type regression waits up to three seconds for
  the actual normalized native indicator values (0.5, then 0), and checks bar
  style, determinate state and visible 72-point minimum track in both states.
  This avoids accepting an old 0.5 control after content replacement.
- Final full local validation passed all 380 tests with no failures/skips;
  macOS release build, rebuilt Sandbox/signature/entitlements and unsigned iOS
  App/Share compilation passed. Sol max's follow-up review found no blockers.
- The rebuilt isolated executable visibly retained a full linear track on
  first launch, after reader-to-Library return in the wide window, and after
  the same return in the compact window. Its notes center read back both
  highlights and both retained notes after normal quit/reopen.
- The import modal and capture completion disclosure were also inspected;
  neither created a new Source or a network request. The reading theme was
  restored to Follow System, without changing the global macOS appearance.

Checkpoint `e3233e2`: hosted CI run `38514095304` passed on this exact head,
including 380 tests and authoritative native validation. This is the baseline
for the continuation above; it is not evidence for later unvalidated UI edits.

Continuation validation on 2026-10-14:

- All 394 shared tests passed with no failures/skips, including 14 new mounted
  layout, native-action and Notes-state regressions. Real label/cover geometry
  and normalized progress are measured without requiring the user to front a
  window or grant accessibility access. Test-only probes stay in test targets.
- The long-position footer case exposed premature navigation stacking; giving
  navigation priority over flexible metadata repaired it. Narrow/accessibility
  reflow still retains the same native controls and their latest action closures.
- Source presentation, token, selection/position/PDF callbacks hash identically
  to `e3233e2`; domain, AppModel, bridges, persistence, Providers, pins/resources
  and schema are unchanged. Notes export golden/status fields remain unchanged.
- Documentation index (96 Markdown files), dependency lock (28 pins), generated
  project, Apple metadata and release/entitlement gate regressions passed.
- Final release/iOS builds, visible acceptance and immutable Sol max review are
  recorded separately before publishing this continuation checkpoint. Physical
  iPhone remains unavailable; no signing configuration or Simulator is used.

Sol max's `7bf89a5` review identified stale-count export after a failed refresh
and a delayed original-opening error being interpreted as a load failure. The
follow-up separates immutable transient read outcomes from action errors,
projects count/export only from a successful current receipt, and fences old
opening errors. Existing notes queries, pagination, IDs, locators, export fields,
transactions and reading progress are unchanged. Additional generated-Library
regressions and another immutable review validate this narrow UI-state boundary.
The follow-up full suite passed all 399 tests with no failures/skips (19 new
continuation regressions). Closed-pool failure after prior success, delayed
original-opening failure after a successful empty query, current action errors,
cancelled non-cooperative opening and shared-query receipts are covered. The
documentation index now contains 97 Markdown files.

The `59ca1ea` follow-up review caught a cancellation boundary: a cached query-key
success could re-match after Q1 → Q2 → Q1 or the reload-owning sheet disappeared.
The next correction publishes pending/interrupted generation receipts and derives
the UI projection directly from the latest receipt. Regression cases cover the
query-wrap projection and a pre-cancelled real GRDB reload owner followed by
explicit retry; they do not claim cancellation during an already suspended read
or multi-window native acceptance.
The corrected full suite passed all 401 tests with no failures/skips (21 new
continuation regressions), including both cancellation boundaries. Dependency
versions, database schema and product source/presentation contracts are unchanged.

Final source checkpoint `946e6e6` on 2026-10-14:

- Sol max's immutable follow-up found no blocking findings. Its remaining test
  boundary is explicit: the owner-cancellation regression cancels before the
  read starts, not while a database read is already suspended. Controlled
  in-flight cancellation/native multi-window acceptance remains unclaimed.
- All 401 tests, release build, unsigned generic-device iOS App/Share build,
  28-pin lock validation, 97-file documentation index, generated project, Apple
  metadata, release-gate regression scripts and entitlement regression scripts
  passed; these checks do not grant release authorization. Builds were serialized
  and reused the existing Swift scratch directory and single iOS DerivedData;
  no local Simulator was created or booted. Available disk remained about 42 GiB.
- Both the assembled app and isolated preview passed strict ad-hoc signature
  and Sandbox entitlement checks. The prior preview bundle was retained as
  `OneReader Features Preview.pre-final-ui-state.app`; no Source or Library was
  deleted. The preview keeps its distinct Bundle ID and has no production URL
  scheme registration. Signing/account/provisioning configuration is unchanged.
- The exact rebuilt preview opened its two test Sources and original four
  annotations. A generated long-title Markdown material, not personal content,
  exercised wide/compact Library covers, continuation title/progress and reader
  header/footer. The actual next/previous controls navigated the outline, including
  the disabled first-item boundary. Search selected the true Chinese quote and
  its original snapshot. A new test-only bookmark was saved at line 32 and the
  Inspector/Notes center showed its localized current-version status.
- Native scrolling through the settable scroll bar moved the actual text view
  to 0.55 and recorded line 19 / 33%; the mouse-scroll control endpoint returned
  `noWindowsAvailable`. This does not prove gesture smoothness or frame rate.
- The Notes center read five annotations, a no-match search showed zero and
  disabled export, and clearing search restored five and enabled export. Both
  the real native button and Command-Shift-E opened export configuration. Preview
  captured five annotations from two Sources; no output directory was written.
- Paper theme was selected in the isolated app. Closing its Settings window
  led to repeated native-control timeouts, including after control-session reset;
  the exact preview process remained alive. A one-second read-only sample showed
  the main thread waiting in the AppKit event loop, not evidence of a product
  deadlock. The new paper/dark screenshots, restoring Follow System, raw locator
  disclosure and normal quit/reopen position comparison remain incomplete. The
  app was not force-quit and no automation/security settings were changed.

### CI test-compiler correction

Hosted run `38535594012` failed at `c6c4419` during test compilation under the
configured Xcode 26.6 toolchain, before tests or app packaging ran. In the mounted
enlarged-copy regression, a local geometry receipt named `resume` shadowed the
string fixture referenced by the earlier ViewBuilder. Its role-specific names
are now `resumeCopy` and `resumeReceipt`; geometry, assertions and all product
sources are unchanged. Re-run the full shared suite and exact-head hosted native
validation; prior local Xcode 27 results are not evidence for this CI toolchain.
After the rename, the full local suite passed all 401 tests with zero failures
or skips using the existing 2.4 GiB Swift scratch cache. Documentation index and
diff checks passed. Hosted validation must be checked against the live PR #34
head; local results do not establish CI success. This test-only fix does not
complete the outstanding visual/device gates.

Remaining gates: current-head hosted CI, the final macOS visual checks above,
physical iPhone compact/Dynamic Type
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
- [x] Existing contracts preserved (boundary hash and 401 shared tests)
- [x] Focused continuation tests pass (21 mounted/state regressions)
- [x] Local continuation validation passes (unsigned iOS build; no local Simulator)
- [ ] Current-head hosted CI passes
- [ ] macOS continuation visible acceptance recorded
- [ ] iPhone compact/Dynamic Type native acceptance recorded
- [x] Current-state and source docs synchronized
- [ ] Branch merged into `dev`
- [ ] Status changed to Delivered
