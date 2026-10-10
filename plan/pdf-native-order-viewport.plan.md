# PDF native order and viewport recovery

Status: Active

Branch: `fix/pdf-native-order-viewport`

Milestone: `v0.3.3`

Dependencies: [Cross-format reading recovery](cross-format-reading-recovery.plan.md), [Universal reading position](universal-reading-position.plan.md)

## Summary

Fix the two defects observed against integrated dev `447e29b`: a new PDF opens
its alphabetically first outline title instead of its first page, and a zoomed
mixed-width PDF loses horizontal viewport placement after normal relaunch.

## User Behavior

- A Source without saved progress starts at its adapter's first readable node.
  PDF page and EPUB spine order are not filename or outline-title order.
- Directory/repository imports still prefer their README/index document.
- Explicit navigation and saved Source positions retain precedence.
- At the same window geometry and zoom, PDF relaunch/source switching restores
  the actual page placement in both axes, including a narrow page's side margin.

## Contracts/Migration

- No database or Locator schema migration. Source/Snapshot/Adapter identity and
  validation remain unchanged; existing positions are not overwritten or reset.
- Add optional normalized screen-position metadata to PDF viewport payloads.
  Page-space X/Y remain finite and page-bounded; quotes/selection anchors take
  precedence and clear viewport-only fields.
- Old page/rect and viewport Locators remain readable with their existing
  semantics. New screen metadata cannot recover information already absent
  from an old saved position.
- Keep platform-specific restoration in the AppKit bridge; do not replace
  PDFKit scrolling, delegates, gesture recognizers, or native zoom ownership.

## Implementation

1. Scope directory README/index ranking to directory plans. Other adapters use
   their ordered readable nodes with stable ties.
2. Capture a validated page anchor and its normalized position in the mounted
   viewport. AppKit applies the destination then a constrained clip correction.
3. Regress normal managed import/default selection and saved/explicit priority;
   use misleading PDF outline titles and EPUB spine filenames.
4. Regress actual screen X/Y and native clip bounds with a 150% mixed-width PDF,
   fresh native views, invalid metadata and legacy/selection anchors.
5. Synchronize current-state/source-boundary docs; build and package without
   creating/booting a Simulator; independently review the final patch.

## Test Plan

- First run new regressions against the old behavior and record real failures.
- Run focused and complete shared tests, dependency/doc/project checks, release
  build, Sandbox package, strict codesign/entitlement and diff validation.
- Compile the iOS device target if available; no iPad or device UI claim.
- Fresh independent Sandbox acceptance copy/container; normal picker import of
  the same public 252-page book, verify first page, enlarge to 150%, scroll/pan,
  normal quit/relaunch and compare actual placement. Recheck source switching,
  search, Markdown recovery and light/dark wide/narrow surfaces as appropriate.
- Hash production SQLite/WAL before/after; use no private Source or Provider.
- No Instruments environment export, raw trace, quantitative FPS claim, push,
  merge, tag or release in this repair/acceptance slice.

## Acceptance Evidence

Local implementation checks pass on 2026-10-10: final shared suite 265/265;
the unified native script includes those 265 tests and passes dependency lock,
doc/project metadata, release/entitlement gates, macOS release/Sandbox packaging,
strict codesign and generic iOS device compilation. No Simulator was created or
booted. Sol max final-only review finds no confirmed defect and accepts code risk.

Red/green and build logs are separate ignored local files under
`.onereader/acceptance/pdf-native-order-viewport-*.log`. New isolated acceptance
is recorded in `.onereader/acceptance/v033-pdf-order-viewport-repair/acceptance.md`:
the empty Library is visible, but native control times out after the normal
public-PDF import action, including after reconnect. Read-only data confirms
one imported Source and page-1 initial progress; it does not prove actual reader
placement. Real first-open, 150% zoom/pan, relaunch and source-switch visible
gates remain pending. The user has been asked to foreground the independent app.
Four production SQLite/WAL hashes match; no production Library was opened.

Historical failure evidence stays in
`.onereader/acceptance/v033-integrated-macos/acceptance.md`; it is not relabeled
as repair acceptance. No push, merge, release or Provider call occurred.

## Non-goals

Visual redesign, other formats' new features, iPad acceptance, Provider calls,
credential changes, performance claims, main promotion and publication.

## Delivery Checklist

- [ ] Both user-visible defects repaired
- [x] Red/green focused regressions recorded
- [x] Complete local validation passes
- [ ] Independent macOS visible acceptance recorded
- [ ] Production data unchanged after acceptance
- [x] Current-state/source docs and indexes synchronized
- [x] Sol max final conclusions addressed
- [ ] Separate authorization before merge/release
