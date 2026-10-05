# Cross-format Reading Recovery

Status: Active

Branch: `test/cross-format-reading-recovery`

Milestone: `v0.3.2`

Dependencies: [Native Editorial Reader](native-editorial-reader.plan.md), [Universal reading position](universal-reading-position.plan.md)

## Summary

Extend the physical-iPhone reading gate beyond native text/Markdown/code to PDF,
EPUB, and HTML. Exercise real managed imports and visible reading restoration,
not only persisted Locator values. Close the v0.3.1 publication documentation
before recording new, separately scoped evidence.

## User Behavior

- Scroll a PDF within one page and across pages; reopening the Source restores
  the page and visible position rather than returning to the page top.
- Scroll EPUB and HTML; leave the Space or terminate the App and reopen the same
  material at the saved visible position.
- Search results, highlights, and navigation retain their explicit source,
  snapshot, and anchor semantics. Repeated content cannot create a false pass.
- User Library content remains untouched by deterministic acceptance fixtures.

## Contracts/Migration

- No database, adapter, provider, or shared Locator schema change.
- Any PDF capture correction uses the existing page/rect payload, with geometry
  measured from the actual visible viewport and validated against page bounds.
  Optional viewport-kind/X/Y payload fields distinguish a reading destination
  from an annotation rectangle; old Locators do not require migration.
- Native text viewport payloads add optional line-relative Y and horizontal X
  offsets. Source UTF-16/quote remains authoritative; selections clear these
  viewport-only fields, and old Locators remain readable without migration.
- DEBUG-only fixture selection accepts a UUID namespace, not an arbitrary path;
  it uses a separate managed Library and UserDefaults suite that survive relaunch.
- Fixtures use the ordinary import, adapter, presentation, and persistence paths.
  They do not prepopulate a fake current position or bypass restoration.
- Test-only accessibility observations describe the mounted view. They must not
  reuse a saved Locator as proof that the viewport moved.

## Implementation

1. Close the delivered editorial plan and record the published tag/asset checks.
2. Add isolated, persistent PDF/EPUB/HTML fixture bootstrap for physical UI tests.
3. Add bounded real-swipe, Space-switch, and terminate/relaunch assertions with
   independent visible anchors, stable source identities, and screenshots.
4. Fix any reproduced capture/restore defect at the existing native bridge.
5. Update current-state/source-boundary docs and open a reviewed PR to `dev`.

## Test Plan

- Deterministic tests for PDF viewport geometry, invalid bounds, and restoration
  precedence; run shared tests and the complete native validation bundle.
- Compile the physical iPhone target without creating or booting a Simulator.
- On the connected iPhone, import all three fixtures through normal pipelines;
  assert real scroll advancement, switched-Space restoration, and relaunch
  restoration. Persist the same UUID namespace across each test's relaunch.
- Validate actual viewport position and source/page/spine identity, plus the
  saved position independently; retain screenshots and the result bundle.
- Run existing text/Markdown/code real-touch regressions and request Sol max
  review. A locked/disconnected device is an incomplete gate, never a pass.

## Acceptance Evidence

Implementation and local verification are in progress. Published v0.3.1
evidence remains in [acceptance](../doc/acceptance.md). The first physical
launch attempt on 2026-09-05 stopped in device preflight because the iPhone
locked before the test runner launched; no physical test pass is claimed.
The attempt was explicitly cancelled, and its `.xcresult` is retained locally.

The first completed device run at `17ebd694` executed all six cross-format
cases: HTML and first-spine EPUB passed; four cases failed. PDF returned to the
top after reopening; Markdown restored a visible range with a shifted viewport.
The second-spine EPUB recording showed AssistiveTouch intercepting the Done
button, leaving the navigation sheet open. These are retained as failure
evidence, not acceptance. Native validation and exact-head GitHub CI passed at
that commit, demonstrating why build gates are not physical acceptance.

Follow-up changes defer native anchor application until nonzero layout, retain
native text line-relative offsets, and assert the actual WKWebView DOM chapter
title. The test dismisses the sheet using an unobscured part of Done and checks
that it disappeared without changing device accessibility settings. PDF tests
now cover all four rotations, both page coordinates, and deferred single-shot
application.

At runtime implementation `df4ba5a70774848e6d60bf55b106185ca4b51c64`, all ten
physical UI cases pass (six recovery plus four existing gesture regressions),
234 shared tests and complete native validation pass, exact-head hosted
[CI](https://github.com/zzqDeco/OneReader/actions/runs/33952657065) passes, and
Sol max returns `APPROVE` with no P0/P1/P2 blockers. Eighteen screenshots are
retained; production SQLite and WAL before/after the UI suite are byte-identical.
See [acceptance](../doc/acceptance.md) for exact local result/log paths.

The initial hosted-layout rerun was cancelled in lock preflight; no test method
ran. The fresh attempt on the unlocked phone at documentation checkout
`b86a98c` reused the same runtime/test binaries and passed **9/9**, with zero
failures/skips/runtime warnings. Its result is retained in
`.onereader/acceptance/cross-format-layout-b86a98c-unlocked.xcresult`.
Production SQLite/WAL remain byte-identical after this final device run. There
is no remaining OneReader test process or temporary UI Runner; the main App and
Library were preserved, and the device window was handed back to the other
task. PR #15 can leave Draft with the runtime/review/physical gates complete.

## Non-goals

New formats, AI Provider smoke tests, iPad acceptance, hosted Xcode 27 migration,
notarization, TestFlight, cloud sync, or changes to user Library content.

## Delivery Checklist

- [x] v0.3.1 publication documentation synchronized
- [x] Isolated persistent fixtures and physical tests implemented
- [x] PDF/EPUB/HTML visible recovery acceptance recorded
- [x] Existing native-scroll tests remain green
- [x] Shared and native build gates pass
- [x] Current-state and source docs synchronized
- [x] Sol max review passes
- [x] Supplemental nine hosted iPhone layout tests rerun after device unlock
- [x] PR opened against `dev`: [#15](https://github.com/zzqDeco/OneReader/pull/15), tracked by [issue #14](https://github.com/zzqDeco/OneReader/issues/14) in `v0.3.2`
- [ ] Branch merged and status changed to Delivered
