# PDF native order and viewport recovery

Status: Delivered

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
6. After supplemental acceptance, submit the repair topic as a PR against dev
   for fresh hosted validation. Merge/main promotion/release stay separate.

## Test Plan

- First run new regressions against the old behavior and record real failures.
- On the pinned macOS CI runner, compare page placement in PDFView coordinates;
  document-local clip origins are not shared between independently initialized
  document views. Exercise legacy scroller layout in the deferred fixture,
  validate constrained native origins and same-view no-relayout-drift at 2 pt.
- Run focused and complete shared tests, dependency/doc/project checks, release
  build, Sandbox package, strict codesign/entitlement and diff validation.
- Compile the iOS device target if available; no iPad or device UI claim.
- Fresh independent Sandbox acceptance copy/container; normal picker import of
  the same public 252-page book, verify first page, enlarge to 150%, scroll/pan,
  normal quit/relaunch and compare actual placement. Recheck source switching,
  search, Markdown recovery and light/dark wide/narrow surfaces as appropriate.
- Hash production SQLite/WAL before/after; use no private Source or Provider.
- No Instruments environment export, raw trace, quantitative FPS claim, merge,
  tag or release in this slice. PR submission follows completed bounded
  acceptance; hosted CI is a separate exact-head gate.

## Acceptance Evidence

Local implementation checks pass on 2026-10-10: final shared suite 265/265;
the unified native script includes those 265 tests and passes dependency lock,
doc/project metadata, release/entitlement gates, macOS release/Sandbox packaging,
strict codesign and generic iOS device compilation. No Simulator was created or
booted. Sol max final-only review finds no confirmed defect and accepts code risk.

Red/green and build logs are separate ignored local files under
`.onereader/acceptance/pdf-native-order-viewport-*.log`. New isolated acceptance
is recorded in `.onereader/acceptance/v033-pdf-order-viewport-repair/acceptance.md`:
after control resumed, the real 252-page PDF visibly opens its cover/page 1.
At 150% on a narrow tail page with non-endpoint horizontal pan, normal quit
and relaunch returns to page 249/252 and retains actual horizontal/vertical
content placement. At unchanged 1440x900 geometry, the PDF surface pixels in
the foreground recheck are identical to the pre-quit surface; this is bounded
static position evidence, not FPS or smoothness evidence. Settings confirm
150% survived relaunch. Full native/scroller readback is distinguished from
the pre-quit capture's menu-only AX and the foreground recheck's title-only
AX. The sparse captures are not used as numeric scrollbar evidence. Sol max
independently recomputed the pixel comparison and accepts these two bounded
PDF visible gates, not the supplemental checks or publication.
Supplemental checks pass on 2026-10-12 with unchanged implementation. Real
Markdown import is visibly readable; returning across Spaces preserves the
PDF placement. Entire-Library search shows source/version/context and its
result visibly jumps to marker 90. The user confirmed real pointer scrolling
after native automation returned `noWindowsAvailable`; normal quit/relaunch
retains actual visible Markdown section 86 and line 341 / 70%. The transient
search selection does not persist; raw normalized scrollers are not claimed
invariant. Paper/Dark wide (1440x900) and compact (900x702) screenshots show
readable native surfaces. The existing minimum window height means 900x650
itself remains unverified. Original System theme / 100% PDF default and text
settings are restored, then the independent App quits normally. Four fresh
production SQLite/WAL baseline hashes match; production data was not opened.
Sol max final-only supplemental review accepts these bounded checks and
independently recomputes the screenshot comparisons. Its sparse-AX attribution
correction is incorporated; merge/publication approval is not inferred.
The authoritative local script was rerun successfully on 2026-10-12: fresh
265/265 tests, macOS release/Sandbox/codesign gates and generic iOS device
compilation. Only plan/evidence records changed afterwards; the upcoming PR
still requires its own exact-head hosted validation.
Initial hosted run `38196057698` fails only the deferred test's two absolute
clip-Y comparisons (11.7 pt); both actual screen-axis assertions pass. Keep
this failed run as evidence. The mounted legacy-scroller fixture passes locally
and does not reproduce the runner-specific raw-origin difference. Correct the
cross-document coordinate assumption using AppKit's documented semantics:
retain actual page X/Y at 2 pt, validate constrained native origin X/Y, and compare
raw clip origins before/after later layout only within the same restored view.
Runtime source and all visual tolerances remain unchanged.
After this test-only correction, 12/12 PDF tests and the full authoritative
local pipeline pass again: 265/265 plus release/Sandbox/signing/document/lock
and generic iOS device build. A fresh hosted run on the corrected head is still
required; neither the original failure nor local checks certify that gate.
Sol max final-only review accepts the test-coordinate correction without
substantive regression weakening. Its origin-versus-entire-bounds wording
clarification is incorporated; runtime code remains unchanged.

Historical failure evidence stays in
`.onereader/acceptance/v033-integrated-macos/acceptance.md`; it is not relabeled
as repair acceptance. No merge, release or Provider call occurred. PR submission
and its fresh hosted CI are recorded separately from local/visible evidence.
The repair is submitted as [PR #22](https://github.com/zzqDeco/OneReader/pull/22)
against dev. At submission its live `CI / Native validation` check had to
succeed on the final topic head before merge; the plan remained Active until
delivery was authorized.

Dev delivery and integration acceptance (2026-10-12): the user authorized
merging PR #22; it merged as `0aec9a232d744bcd1b6e4d84e4eb5c8f1546c480`.
Exact dev push [CI 38199092477](https://github.com/zzqDeco/OneReader/actions/runs/38199092477)
passes 265 tests, zero failures, native build/package and metadata gates.
An independent copy of that CI artifact passes renewed native macOS first-page,
150% two-axis relaunch, cross-Space return, Markdown Library search/jump,
native AX scrolling and actual line-347 viewport recovery. Paper/Dark are
readable at 1440x900 and actual 900x702; 900x650 remains unverified. Test settings
are restored, the app quits normally, and four production SQLite/WAL hashes
still match. Sol max final-only review accepts these bounded integration gates
without blockers. Raw native JPEG/AX and read-only image comparisons remain
under `.onereader/acceptance/v033-dev-pr22-integration-oct12/` in the primary
checkout. No FPS/120-Hz, pointer-success extrapolation, iPhone or release claim
is inferred. Publication is now owned by the separate v0.3.3 release plan.

## Non-goals

Visual redesign, other formats' new features, iPad acceptance, Provider calls,
credential changes, performance claims, main promotion and publication.

## Delivery Checklist

- [x] Both PDF repair visible gates pass at unchanged geometry
- [x] Red/green focused regressions recorded
- [x] Complete local validation passes
- [x] Independent PDF repair visible acceptance recorded
- [x] Production data unchanged during PDF acceptance
- [x] Bounded supplemental macOS acceptance and test-preference cleanup completed
- [x] Current-state/source docs and indexes synchronized
- [x] Sol max final conclusions addressed
- [x] Supplemental Sol max final evidence review completed
- [x] Repair PR submitted against dev
- [x] Fresh exact-head hosted CI passes before merge
- [x] Separate merge authority and exact-dev integration CI recorded
- [x] Bounded exact-dev macOS integration acceptance completed
- [x] Publication handed to the separately authorized v0.3.3 release plan
