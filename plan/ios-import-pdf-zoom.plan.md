# iPhone File Import and PDF Zoom

Status: Active

Branch: `fix/ios-import-pdf-zoom`

Milestone: `v0.3.3`

Dependencies: [Cross-format reading recovery](cross-format-reading-recovery.plan.md)

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
- Sol max code review has no remaining findings. PR targets `dev` only; merge
  and release have not been requested for this slice.

Local logs, xcresults and screenshots are retained under
`.onereader/acceptance/ios-import-pdf-zoom/` and are not committed.

## Non-goals

iPad acceptance, Provider calls, changes to production Library contents,
unrelated Markdown-index PR changes, or release/tag publication.

## Delivery Checklist

- [x] Import and PDF behavior implemented
- [x] Shared and native regression tests pass
- [x] Physical file-picker, pinch and button acceptance pass
- [x] Cross-format/touch rerun and zoomed-scroll pressure case pass
- [ ] Remaining intermittent PDF hitch classified with a frame trace
- [x] Required validation passes
- [x] Sol max review has no blockers
- [x] Current-state/source docs synchronized
- [ ] Branch reviewed through a PR to `dev`
- [x] Plan status reflects observed delivery (Active: integration/profile pending)
