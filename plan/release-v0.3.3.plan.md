# v0.3.3 Reader Maintenance Release

Status: Active

Branch: `release/v0.3.3`

Milestone: `v0.3.3`

Dependencies: [Markdown full-text search](markdown-fulltext-index.plan.md), [iPhone import and PDF zoom](ios-import-pdf-zoom.plan.md), [PDF native order and viewport](pdf-native-order-viewport.plan.md)

## Summary

Deliver the accepted dev reader repairs as v0.3.3 (6), with a fresh physical
iPhone candidate regression before protected dev/main promotion and immutable
Developer Preview publication. The user authorized this ordered delivery on
2026-10-12. Start from dev `0aec9a232d744bcd1b6e4d84e4eb5c8f1546c480`.

## User Behavior

- Markdown paragraph search reaches actual matched text and restores reading.
- iPhone file selection imports into a managed Library; native PDF pinch and
  zoom buttons survive position updates.
- New PDFs begin on page one and EPUBs follow native spine order. Saved and
  explicit navigation retain priority; macOS zoomed PDFs restore both axes.
- Existing sources, notes and reading positions remain local and readable
  without a Provider. The download remains an unnotarized macOS preview.

## Contracts/Migration

- Both native targets change 0.3.2 (5) to 0.3.3 (6); dependency pins stay fixed.
- Database schema 10 rebuilds old derived search projections, without changing
  source bytes, annotations, progress or history. Adapter/Locator schema 1 and
  Agent runtime schema 5 remain unchanged.
- Real-document screenshot review found that a fitted iPhone page can be
  shifted horizontally inside PDFKit's wider continuous-document canvas.
  Repair only initial/page navigation and explicit fit-width alignment; do not
  recenter during scrolling, pinch, position saves, or ordinary host updates.
  If a saved zoomed position remounts at default fit, normalize only horizontal
  placement; a still-enlarged page retains its saved pan and all cases retain
  vertical reading position. Selection/quote navigation stays unchanged.
  DEBUG geometry must observe page edges, not infer visibility from its width
  or a 100% label. Public PDFs remain uncommitted.
- Use independent acceptance identities/UUID Libraries. Preserve production
  data; never copy private source material or credentials into artifacts.

## Implementation

1. Create an isolated topic worktree and synchronize version/project metadata,
   release notes, document indexes and delivered dev evidence.
2. Run the complete physical iPhone suite on the candidate. Add a seeded public
   252-page PDF case for first page, pinch/buttons, real scrolling and relaunch;
   its bytes are transferred only to the independent preview's Documents.
   Review original screenshots before admission. Reproduce any offset with
   actual page-edge assertions, then repeat the strengthened full suite after
   the narrow mixed-width canvas repair.
3. Record actual results, failures and limitations. Require current-head hosted
   native CI and Sol max final-only review before merging preparation to dev.
4. Verify exact dev CI, create a separate dev-to-main PR, and require fresh
   protected checks/review before merge. Re-query main tip and its push CI.
5. Tag that exact main tip with annotated v0.3.3 only after validation. Release
   rebuilds the tag and publishes DMG/ZIP, checksums and schema/toolchain manifest.
6. Download the published assets, verify checksums/version/signing/Sandbox and
   read-only archive equality, then isolate downloaded-app launch/read smoke.
   Close issue #19 and milestone 3 only after verified delivery. Keep final
   publication evidence local/on GitHub rather than editing the immutable tag.

## Test Plan

- Metadata, pinned XcodeGen project drift, docs, lock, release-tag rejection,
  Sandbox/entitlement rejection and whitespace checks locally.
- Complete shared tests/release build/package on exact candidate hosted CI,
  dev and main integrations, and exact tag Release. Generic SDK compilation
  does not create/boot a Simulator or constitute device acceptance.
- Physical iPhone: actual Files picker import/cancel/retry/join-Space, native
  pinch and buttons, slow/fast PDF scrolling with persistence gaps, native
  cross-format search/gestures and process-position recovery. Preserve unchanged
  tolerances; a failed/skipped required case blocks acceptance.
- The real PDF is explicit local-only opt-in; prove 252 pages from mounted
  PDFKit, not a saved Locator. Assert first page, changed viewport, preserved
  live scale, matching source/snapshot persistence and actual relaunch placement.
  At default/explicit fit width both displayed page edges must lie inside the
  viewport (2pt tolerance), with at least 90% width utilization. Mixed-width
  navigation must align the page without rewriting arbitrary live pan/zoom.
  Assert both page edges immediately after the real-book process restart,
  before tapping fit, and retain the existing page/Y recovery tolerance.
- Keep prior dev 0aec9a2 macOS visible evidence separate: page 1, 150% two-axis
  restart/Space return, Markdown search/AX scrolling/restart, Paper/Dark at
  1440x900 and actual 900x702. Do not claim untested 900x650 or quantitative FPS.
- Strict downloaded binary/manifest/entitlement verification and independent
  macOS source-open smoke. Do not infer visible behavior from a process alone.
- No live LLM secrets, production Library mutation, security bypass, new trace
  environment export, iPad acceptance or Simulator boot.

## Acceptance Evidence

Baseline dev push [CI 38199092477](https://github.com/zzqDeco/OneReader/actions/runs/38199092477)
passes 265 shared tests, zero failures, packaging and metadata gates. Independent
macOS visible integration acceptance and Sol max final conclusions are retained
under ignored `.onereader/acceptance/v033-dev-pr22-integration-oct12/`; production
SQLite/WAL hashes match and test preferences were restored before normal exit.
These baseline results do not certify the new candidate or physical iPhone.
Candidate `1e2a087` passes its own [CI 38215012340](https://github.com/zzqDeco/OneReader/actions/runs/38215012340),
including 265 shared tests. The second physical attempt passes 18 native and
18 UI cases with zero failures/skips, including the real 252-page PDF. However,
original screenshots expose first-open horizontal whitespace not covered by
those assertions. This is not visual admission: the page-edge regression,
repair and fresh exact-head/full-device gates are pending. The first attempt's
automation-bootstrap failure is retained separately; no security setting was
changed. New merges, Release and downloaded-product gates remain pending.

## Non-goals

New reader features, dependency/toolchain upgrades, zero-hitch/120-FPS promises,
private documents, Provider calls, iPad physical acceptance, TestFlight/App Store,
Developer ID/notarization, main force-push or overriding existing releases.

## Delivery Checklist

- [x] Accepted dev baseline and user delivery authority verified
- [x] Version/project metadata and release documents synchronized
- [ ] Complete candidate physical-iPhone and seeded real-PDF gates pass
- [ ] Current-head native CI and Sol max final review pass
- [ ] Preparation PR merged and exact dev push CI passes
- [ ] Separate promotion PR merged and exact main push CI passes
- [ ] Annotated exact-main v0.3.3 publishes without overwrite
- [ ] Published assets and independent downloaded-product smoke verified
- [ ] Issue #19 and milestone closed after delivery
