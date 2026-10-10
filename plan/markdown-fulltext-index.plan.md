# Markdown Full-text Search Recovery

Status: Active

Branch: `fix/markdown-fulltext-index`

Milestone: `v0.3.3`

Dependencies: [v0.3.2 release](release-v0.3.2.plan.md), [Source adapters](source-adapters-v2.plan.md)

## Summary

Fix [#19](https://github.com/zzqDeco/OneReader/issues/19): heading-based Markdown
currently indexes heading lines without their paragraphs. Deliver complete
bounded text coverage independently of the navigation outline, rebuild old
derived projections, and preserve existing source/position identities.

## User Behavior

- Library, Space, and Source search can find Markdown paragraph and preamble
  text even when a heading already matches the query.
- Results retain exact Source/Snapshot evidence and navigate to the matched
  text, including later chunks, Unicode, and long lines.
- Previously imported materials rebuild their derived search index in the
  background without requiring reimport or opening every Space. Basic reading
  stays available; incomplete indexes are never reported as ready.
- Existing bookmarks, annotations, immutable snapshots, and reading positions
  retain their identities. No Provider or account is required.

## Contracts/Migration

- Add an optional host-only indexing protocol behind the registered read
  adapter. It is not an Agent tool or a new model-selected capability. Adapters
  without it keep existing page/spine/node indexing behavior.
- Text/Markdown/code produce bounded source-text observations independently of
  their outline. Directory composition applies the same path-bound behavior to
  child files; PDF/EPUB traversal remains unchanged.
- Index chunks carry absolute UTF-16 and line coordinates, an exact quote,
  and the existing Source/Snapshot/Adapter envelope. Query anchors rebase onto
  these coordinates rather than treating every fragment as document offset 0.
- Schema v10 invalidates derived search projections and completion records in
  one migration. It does not alter Sources, Snapshots, evidence Observations,
  annotations, progress, history, or Agent records. Bootstrap already schedules
  all active incomplete plans and publishes rebuilt projections transactionally.
- Locator/adapter schema 1 and Agent runtime schema 5 stay unchanged. Existing
  outline and viewport semantics must not be repurposed as indexing ranges.

## Implementation

1. Start from current dev; incorporate the tree-identical v0.3.2 main promotion
   by fast-forward on this new topic branch, preserving release ancestry.
2. Introduce a host indexing hook and bounded overlapping text chunks (64K
   Swift grapheme clusters, 512-cluster overlap; coordinates remain UTF-16).
   Load a permitted UTF-8 text file once;
   emit/stage each chunk serially with cancellation checks, not a whole array.
   Existing 64 MiB input admission limits remain in force.
   A process-wide cancellable FIFO permits one Source index at a time, including
   bootstrap and separate coordinators. A run accepts at most 10,000 directory
   entries/expanded nodes, 10,000 fragments, and 128 MiB of staged UTF-8 plus
   metadata. List one extra sentinel node to detect overflow; truncated reads
   fail rather than marking a partial projection ready. The capacity gate keeps
   the 2 GiB storage floor plus at least 32 MiB or eight times the current
   projection size for publication/FTS/WAL, checked before writes and commit.
   Failed/cancelled staging is deleted transactionally; reclaimable SQLite pages
   remain reusable, without a blocking VACUUM. Failed plans retry on next open or
   bootstrap, never in an automatic tight loop. Sources/progress are untouched.
3. Preserve navigation list/read behavior. Define explicit source-range reads
   for indexed text, exact query anchors, and safe quote-based relocation;
   deduplicate overlap hits without dropping format/path identity.
4. Add schema v10 invalidation and metadata updates. Keep interrupted, cancelled,
   stale-generation, and inactive-plan projections hidden until atomic commit.
5. Add focused adapter/coordinator, database migration, and AppModel regression
   tests; add native search-to-reading acceptance where tooling permits.
6. Synchronize current/source docs, close v0.3.2's source plan with the published
   evidence, then use protected PRs and exact-head gates for v0.3.3 delivery.

## Test Plan

- Ordinary import of Markdown with preamble, nested headings, body-only and
  mixed heading/body matches, and no headings. Compare Library, Space, and
  Source scopes rather than relying on direct adapter fallback alone.
- More than one chunk and more than the previous 1M-character read cap; Unicode
  offsets, long lines, and a phrase across a chunk boundary. Read/resolve a hit
  and verify its absolute source range. Preserve outline locators and viewport
  recovery behavior; deduplicate overlapping hits.
- Directory Markdown/text/code composition plus retained PDF/EPUB tests.
- A real schema-v9 completed heading-only projection migrates, becomes pending,
  and rebuilds on bootstrap while user records and source bytes remain intact.
  Interrupted staging, late generation, cancellation, and failed rebuild gates
  remain covered.
- Focused and full shared tests, release build, metadata/docs/project checks,
  Sandbox packaging and entitlements, hosted exact-head native CI. Do not boot
  or create Simulator devices; generic SDK compilation is a separate gate.
- macOS visual and physical-iPhone search -> original text -> restart/resume
  acceptance require actual visible evidence, isolated data, and available
  permissions/device ownership. Do not relabel historical device results as new.
- Physical search acceptance starts from the separate HTML Space and selects
  the Library scope (so a failed scope switch cannot pass via a direct-adapter
  fallback), searches the body-only `Visible marker 90` in the managed Markdown
  fixture, observes the mounted TextKit viewport against independent source
  offsets, captures the visible result/original, and verifies process recovery.
  Each launch uses a UUID-isolated Library; native scrolling/recovery cases also
  rerun on the currently authorized iPhone. No production Library is opened.
- For native Markdown, recovery compares the source UTF-16 anchor and the
  visible glyph line's viewport-relative Y (same 64-UTF-16-unit/16-point
  tolerances), not the whole document's absolute scroll offset. TextKit layout
  can change absolute coordinates after a deep jump while leaving the visible
  text unchanged. This read-only test metric comes from mounted glyph geometry,
  not the persisted position; PDF/Web assertions keep their existing geometry.

## Acceptance Evidence

Implementation and isolated shared verification (2026-10-07):

- 244 shared tests passed, zero failures, including 10 new regression tests for
  complete paragraph/preamble indexing, million-character text, real overlap
  deduplication before the 20-result cap, Unicode/CRLF/CR, repeated-quote
  relocation, node/fragment/capacity failure plus retry, FIFO cancellation,
  all three search scopes and position restoration, and real v9 bootstrap rebuild.
- The v9 fixture was created through migrations only up to v9 and contains a
  completed heading-only projection. After v10, bootstrap rebuilds it without
  opening its Space; source bytes, raw evidence, note, history, and progress JSON
  remain unchanged. Existing v8 rebuild also now asserts paragraph matches.
- Dependency lock (28 pins), documentation index, native metadata (28 icon
  slots), generated-project drift, release-policy and entitlement rejection
  tests, and whitespace checks pass. GRDB cursor lifetime/row-reuse guidance was
  checked against its primary documentation through Context7.
- Local release build passed. Sol max patch review identified the production
  `textViewport` discriminator; the range-read guard and regression fixture now
  use that actual AppKit/UIKit payload. Sol max approved `d58b57a` without
  blockers, and its [protected CI](https://github.com/zzqDeco/OneReader/actions/runs/37576349149)
  passed. Sol max also approved the native acceptance changes without blockers;
  their new commit still requires its own exact-head CI. Unit/AppModel position
  evidence is not visible scrolling evidence.
- GitHub issue #19 is assigned to the open [v0.3.3 milestone](https://github.com/zzqDeco/OneReader/milestone/3).
- Fresh physical-iPhone acceptance (2026-10-07): the user completed Developer
  Mode, certificate trust, and UI-automation consent on the authorized iPhone.
  The first two attempts stopped before any test executed. The third reached
  the cross-Space body-search hit and restored the same visible text, but exposed
  an invalid absolute-scroll-Y assertion (15,815 versus 8,534 despite matching
  source anchors and visually identical viewports). The read-only TextKit metric
  now checks visible-line geometry with unchanged tolerances; Apple container
  coordinates were verified through Context7. The focused fourth attempt passed,
  with three retained screenshots confirming Library scope, original text, and
  restoration. The complete physical-iPhone suite then passed all 11 tests,
  zero failures/skips, in 403.6 s: seven search/recovery cases and four Library,
  text, Markdown and code gesture cases. Source/test hashes matched before and
  after the run; 21 screenshots were retained. The 244 shared tests, local
  release build, Sandbox packaging, strict codesign and entitlement validation
  were repeated successfully. macOS visible acceptance still requires restored
  permission or user verification. UUID-isolated Libraries only; no trust
  setting was bypassed and no Simulator was booted or created. Post-run read-only
  inspection found an existing production database with a September 7 timestamp
  and no WAL; it was not used by the tests. No pre-run byte-hash baseline was
  captured, so byte-for-byte preservation is not asserted.

Baseline v0.3.2 main is
`d189d2cc5d91ed86e3bb66ba69931b411fa18aa6`; dev is `e143aea` with an identical
tree. GitHub REST confirmed both current heads after a Git HTTPS fetch failed.
The new branch includes the main promotion without a file change.

Only about 13 GiB is currently free. Reuse existing locked dependencies for
incremental checks; do not initiate a cold dependency resolution below 15 GiB.
Do not work around the previous host rejection of cache deletion or remove user
Sources. Hosted CI remains available for authoritative full rebuilds.

## Non-goals

New UI design, AI runtime expansion, OCR, sync, iPad physical acceptance,
Xcode 27 migration, TestFlight/App Store publication, notarization, changing
provider credentials, rewriting v0.3.2, or modifying the production Library.

## Delivery Checklist

- [x] Full-text indexing and anchored search implemented
- [x] Existing completed indexes safely rebuilt
- [x] Focused and full shared tests pass
- [x] Sol max review concludes without blockers
- [x] Physical-iPhone search, gestures and position recovery accepted
- [ ] macOS visible acceptance recorded with honest permission boundaries
- [x] Current-state and source docs synchronized
- [ ] Exact-head protected CI passes and PR merges to dev
- [ ] New release promotion/artifact gates pass before publication
- [ ] Issue/milestone and plan status reflect observed delivery
