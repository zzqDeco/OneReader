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

## Non-goals

New formats, AI Provider smoke tests, iPad acceptance, hosted Xcode 27 migration,
notarization, TestFlight, cloud sync, or changes to user Library content.

## Delivery Checklist

- [x] v0.3.1 publication documentation synchronized
- [x] Isolated persistent fixtures and physical tests implemented
- [ ] PDF/EPUB/HTML visible recovery acceptance recorded
- [ ] Existing native-scroll tests remain green
- [ ] Shared and native build gates pass
- [ ] Current-state and source docs synchronized
- [ ] Sol max review passes
- [ ] PR opened against `dev`
- [ ] Branch merged and status changed to Delivered
