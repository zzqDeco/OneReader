# iPhone File Import and PDF Zoom

Status: Active

Branch: `fix/ios-import-pdf-zoom`

Milestone: `v0.3.3`

Dependencies: [Cross-format reading recovery](cross-format-reading-recovery.plan.md), [Markdown full-text search recovery](markdown-fulltext-index.plan.md)

## Summary

Repair the iOS file picker completion lifecycle and PDF zoom ownership. A
selected file must reach the managed Library; native pinch zoom must survive
reading-position updates. Provide accessible PDF zoom controls in the reader.

## User Behavior

- Local files can be added from the Library or to the current Space. Cancelling
  and reopening the picker leaves no stale import request.
- A new PDF initially fits the reader width. Pinch gestures, zoom-in/out, and
  fit-width controls operate on the mounted PDF and keep working after scrolling.
- The Files app can place input files in OneReader's Documents folder; Library
  databases, managed Sources, and credentials remain outside that folder.
- ProMotion-capable iPhone reading opts into high refresh rates while leaving
  native frame pacing adaptive. Scrolling frame rate and hitches are measured
  independently; configuration alone is not a smoothness acceptance result.

## Contracts/Migration

- File-picker visibility is independent of its retained typed purpose. The
  completion/cancellation callback owns purpose cleanup. A custom import sheet
  finishes dismissing before the host presents the picker.
- iOS PDF defaults are relative to fit width; PDFKit owns the live gesture
  scale. The default is reapplied only when explicitly changed or a new PDF is
  mounted. Discrete zoom requests are consumed once. Width changes preserve the
  live relative zoom. No database, Locator, or provider migration is required.
- Device fixtures use a validated UUID Library/UserDefaults namespace. Only
  generated input files are made visible to the system picker. Observations
  read the actual mounted PDFView rather than saved settings or positions.

## Implementation

1. Separate importer presentation and request state, with dismissal and
   cancellation hooks in the native root view.
2. Add a UIKit PDF zoom controller for layout-time fit, gesture preservation,
   default changes, and single-consumption button commands.
3. Add compact accessible PDF zoom controls and a live relative percentage.
4. Add isolated shared/native unit regressions and full system-picker/pinch/
   button UI regressions. Synchronize current and source documentation.
5. Address the reported high-refresh omission with the iOS ProMotion plist
   key, a metadata regression gate, and native scrolling performance metrics.
6. Use the recovered physical-device trace to test one narrow UI isolation:
   retain the exact live Locator without a global AppModel publication, and
   update only an independently observed position badge. Keep existing
   position capture, 350 ms durability and revision guards.
   Compare the same six-burst/pause fixture and Instruments frames before/after;
   this does not presume that all observed hitches share one cause.
7. The first experiment still correlates costly frames with successful progress
   publication. Isolate position-only durability from the global reader model
   while the workspace is open; keep the exact cache and database up to date,
   and publish the current durable position to the small position projection.
   Other progress mutations and the return to Library retain normal global
   publication. The DEBUG persistence receipt observes that same small
   projection, not a stale label or a database read on each frame. Repeat the
   trace before treating this as a smoothness improvement.
8. The same-device A/B recovery gate exposed a Markdown drag regression when
   both position notifications were suppressed for every surface. Limit quiet
   live/durable updates to the measured PDFKit surface; other presentations
   retain their existing global refresh contract. Do not broaden this PDF slice
   into an unproven TextKit lifecycle rewrite. Keep the unchanged native drag,
   persistence and relaunch assertions and rerun the full physical suite.
9. Integrate accepted Markdown-index PR #20 from dev through a normal merge,
   without rebasing published history. Preserve PDF-only notification/zoom
   ownership and the new read-only TextKit line-geometry observations together.
   Resolve documentation conflicts by retaining both contracts. Run fresh
   integrated shared/native/physical tests and exact-head hosted CI; separate
   green results from either predecessor cannot stand in for this gate.

## Test Plan

- Successful new/add-to-Space completion after visibility becomes false;
  cancellation/retry, failure cleanup, and custom-sheet handoff.
- Mounted native PDF scale survives unrelated updates; explicit default,
  zoom-in/out, fit width, width changes, and finite bounds behave correctly.
- A saved page in a mixed-width PDF fits its own width, not PDFKit's temporary
  first page; deferred navigation preserves any live relative zoom.
- Physical iPhone: start with empty isolated Library, select a generated PDF in
  the real system Files picker, verify it becomes readable, pinch in/out,
  scroll/wait for position updates, and use all three PDF controls.
- Shared tests, native unit/UI tests, release build, docs/metadata/project and
  diff checks. Use connected physical iPhone; do not create or boot Simulators.
- Capture native PDF scrolling/deceleration frame-rate and hitch metrics before
  and after high-refresh opt-in. Do not claim a fixed 120 FPS or treat callback
  preferences as evidence that frames were displayed.
- Repeat slow/fast scrolling at native pinch scale with pauses long enough for
  position persistence. Record hitches and verify that later bursts never reset
  the mounted scale; a generated fixture still cannot disprove an intermittent
  issue with arbitrary real PDFs.
- Assert that a valid live position updates the exact Locator and local badge
  without a global model broadcast, deduplicates unchanged badge text, and still
  durably saves/flushes before transitions. Rerun cross-format recovery.
- Preserve immediate first/last-content navigation state and menu shortcuts;
  a failed save restores the durable badge and last-Source removal clears it.
- Successful position-only saves update the database/cache and local durable
  projection without a global reader notification. Returning to Library and
  unit/plan mutations still publish; the DEBUG receipt cannot fabricate a save.
- Quiet publication is PDF-only. Assert non-PDF live updates and successful
  durable saves still publish globally, then repeat Markdown native recovery.
- Cross-format device diagnostics assert the managed Markdown content extends
  beyond its viewport before dragging, retain before/after geometry and images,
  and capture Library-back failures with the current accessibility hierarchy.
  Keep the original movement/persistence assertions; do not silently retry a
  failed gesture or weaken acceptance because a notification was present.
- Integrated physical suite additionally retains the body-only Library search
  from the separate HTML Space, source/snapshot identity, and native visible-line
  recovery assertions brought in by PR #20. Use the same independent preview
  identity and UUID Library, never the production app's migration state.

## Acceptance Evidence

2026-10-10, physical iPhone 18 Pro Max (iPhone19,7), iOS 27.0.1, Xcode 27
beta 6. The independent `OneReader Fix Preview` app uses UUID-isolated Libraries;
the production application and its newer database schema are not overwritten.

- `native-validation-final.log`: 238 shared tests, release build, Sandbox
  packaging/signature, docs, dependency, metadata, generated project and release
  gates, plus generic iOS SDK compilation passed. No Simulator was booted.
- `device-04/device-tests.xcresult`: 18 native tests and all five original
  import/zoom UI cases passed. Attachments cover actual picker selection,
  cancellation with an unblocked Library, retry, two-source Space, native pinch,
  controls, and mixed-width PDF relaunch.
- `fps-before.xcresult` (before the plist key, after the zoom runtime fix): OS
  scroll/deceleration metric averages 86.083 FPS. `device-04` (with the key)
  averages 85.848 FPS. Both record zero hitches on the generated PDF. This does
  not establish a measurable frame-rate improvement, a fixed 120 FPS, or the
  absence of intermittent hitches on real material. The OS frame-count field is
  zero in these bundles and is not used as a displayed-frame counter.
- Implementation commit `8a448c1f1b517ed24b5290b42cadb9545c09de8c` passed the
  same authoritative validation in `native-validation-8a448c1.log`.
- `device-final/device-tests.xcresult`: full 18-native/15-UI rerun passed,
  including six cross-format position cases and four Library/text/code touch
  cases. Its short PDF scroll metric averaged 86.143 FPS with no reported hitch.
- `device-pressure.xcresult`: the 18 native tests and new zoomed-scroll pressure
  case passed. Viewport movement, a changed matching persisted position, native
  zoom preservation and fit width were independently asserted. Average scroll
  metric was 82.986 FPS; two iterations recorded one 8.333 ms hitch each. Mean
  hitch ratio was 1.230 ms/s. Functional correctness passed; intermittent
  scrolling smoothness remains open pending frame/call-stack correlation.
- The attempted follow-up profile did not launch: CoreDevice's connection was
  invalidated and both device inventories marked the iPhone offline. Do not
  classify this transport failure as an app regression or a completed trace.
- After reconnect, `device-profile-02.xcresult` passed, while its simultaneous
  85.504-second frame trace found 13 hitches (8.333–25 ms); ten were correlated
  with costly application updates after broad position/progress notifications.
- A live-Locator-only experiment did not remove the durable-save hotspot.
  `device-position-isolation-v3.xcresult` passed after both notifications were
  isolated. Its 81.084-second trace has three 8.333 ms hitches, no expensive app
  update markers and 0.770–1.053 ms app updates for those frames. Measured
  iterations 2–6 are fully captured in all variants: 11 hitches / approximately
  125 ms before, 9 / approximately 125 ms for live-only, 3 / approximately 25 ms
  for live plus durability. This supports the narrow optimization, not a claim
  of zero hitches or fixed 120 FPS. The OS scroll metric remains around 82 FPS.
- The broad experiment passed 242 shared tests but exposed a Markdown native
  drag regression in the full suite (32/34); the same-device two-file baseline
  reversion passed that original gesture and recovery case. Failed bundles are
  retained. The final implementation therefore limits isolation to matching
  active PDF identity and protects the original non-PDF publication contract.
- `native-validation-pdf-scope.log`: 243 shared tests and full native validation
  passed. `device-pdf-scoped-recovery.xcresult` passes both previously failing
  cases. `device-pdf-scoped-final/device-tests.xcresult` passes all 18 native and
  16 UI tests with zero skips: all six cross-format recoveries, true Files-picker
  import/cancel/retry/add-to-Space, native pinch/buttons, mixed-width relaunch,
  pressure scrolling and complete-workspace touch. Short OS scroll averaged
  85.973 FPS; pressure averaged 82.446 FPS, both with zero OS-scroll hitches.
  Final PDF-only frame trace is recorded separately from those OS metrics.
- The first PDF-only recording failed during save because disk space ran out;
  its partial trace is excluded. After clearing only temporary trace data and
  verified inactive build caches, `pdf-scoped-short-02.trace` saved successfully
  (61.188 seconds). Fully captured measured iterations 1–3 compare 5 hitches /
  approximately 66.7 ms / 4 expensive updates before with 1 / approximately
  8.3 ms / 0 expensive updates after PDF-only isolation. The one remaining
  frame has a 0.913 ms app update and 4.77 ms render; internal delay is not fully
  attributed. Its full six-iteration pressure test passes at 83.064 FPS with
  one short OS-scroll hitch. This does not prove every real PDF stays smooth.
- `native-validation-pdf-scope-final.log` repeats all 243 shared tests and full
  native validation after the PDF test uses actual viewport/rect fields.
- Sol max code review has no remaining findings. PR targets `dev` only; merge
  and release have not been requested for this slice.

Local logs, xcresults and screenshots are retained under
`.onereader/acceptance/ios-import-pdf-zoom/` and are not committed.

Integration admission (2026-10-10): the user authorized the topic-PR → dev
sequence. PR #20 merged at `45e44ec77c45560fc15ad7144682b0a05ca8a327`; this
branch combines it with `8a2ba6e` through a normal merge. The only textual
conflicts were the plan index and UIKit source note; both accepted contracts
are retained. The above physical/performance results are predecessor evidence,
not fresh integrated acceptance. New exact-head CI, Sol max review and native
results are tracked in [PR #21](https://github.com/zzqDeco/OneReader/pull/21).
No main promotion, tag, release, device-security change or Simulator boot is
part of this integration slice.

## Non-goals

iPad acceptance, Provider calls, changes to production Library contents,
new Markdown-index algorithm changes beyond integrating accepted PR #20,
or release/tag publication.

## Delivery Checklist

- [x] Import and PDF behavior implemented
- [x] Shared and native regression tests pass
- [x] Physical file-picker, pinch and button acceptance pass
- [x] Cross-format/touch rerun and zoomed-scroll pressure case pass
- [x] PDF position-notification hotspot classified and final-code frame comparison recorded
- [ ] Real-document intermittent smoothness accepted (short native hitch remains)
- [x] Required validation passes
- [x] Sol max review has no blockers
- [x] Current-state/source docs synchronized
- [ ] Branch reviewed through a PR to `dev`
- [x] Plan status reflects observed delivery (Active: integration/real-document acceptance pending)
