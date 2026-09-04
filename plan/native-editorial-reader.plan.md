# Native Editorial Reader

Status: Active

Branch: `feature/native-editorial-reader`

Milestone: `v0.3.1`

Dependencies: [Apple multiplatform reader](apple-multiplatform-v1.plan.md), [Universal reading position](universal-reading-position.plan.md)

## Summary

Replace the feature-complete but engineering-oriented macOS and iPhone shell
with a coherent native editorial reader. The slice changes information
hierarchy, reader chrome, typography, and presentation consistency without
changing Source, Snapshot, Locator, annotation, progress, or Agent contracts.

The release target is a calm book-first Library and a content-first reader.
Physical iPad acceptance and Xcode 27 migration are explicitly deferred and do
not gate v0.3.1.

## User Behavior

- Library opens with a compact continuation surface followed by a scannable
  shelf. A single Space no longer leaves most of a large Mac window empty or
  consumes most of an iPhone screen in one dashboard card.
- Entering a Space replaces Library navigation with reading navigation. macOS
  shows content plus an optional Reading Assistance panel, never Library,
  content navigation, reader, and Inspector as four simultaneous columns.
- iPhone uses one native navigation bar and one stable bottom reading bar.
  Directory, position, annotation, and reading assistance are the persistent
  actions; import, settings, and advanced activity move out of the reading
  chrome.
- Primary Chinese UI uses reader language such as 资料库、阅读空间、阅读辅助、
  引用 and 运行详情. Adapter and persistence implementation names appear only
  in an explicitly opened advanced detail.
- All existing formats remain immediately readable without a Provider. Saved
  positions, annotations, search, evidence jumps, source refresh, and frozen
  routes retain their current behavior.

## Contracts/Migration

- No database, Source, Snapshot, Locator, annotation, graph, plan, or progress
  schema changes are allowed in this slice.
- `ReaderTheme` becomes the single semantic token surface for window, sidebar,
  paper, grouped background, selection, highlight, spacing, shape, and prose
  measure. Platform dynamic colors remain authoritative in light, dark, and
  increased-contrast appearances.
- Reader chrome can relocate actions but must call the same `AppModel`
  operations and preserve presentation-generation cancellation.
- Native Markdown resource rendering must remain within the current immutable
  Snapshot and use existing host resolution; it may not read arbitrary paths
  or weaken Web/EPUB resource isolation.
- Existing user preferences decode unchanged. New visual defaults must have
  safe fallback values and require no destructive migration.

## Implementation

1. Rewrite the design-system source of truth as Native Editorial Reader tokens
   and component rules; reject generic landing-page or ornamental styles.
2. Change regular-width navigation so Library and reading navigation are
   mutually exclusive leading contexts. Keep only reader plus optional trailing
   assistance in the detail region.
3. Recompose Library into continuation and shelf components with compact Mac
   and iPhone layouts, restrained generated covers, useful progress, and no
   decorative gradients or ubiquitous Material cards.
4. Make the reader canvas dominant. Use a quiet document header on Mac and
   native inline navigation on iPhone; replace the horizontally scrolling
   iPhone footer with four stable, minimum-44-point actions.
5. Rename and restructure Inspector as Reading Assistance. Notes, citations,
   and assistant output are primary; raw Snapshot, digest, adapter, and event
   data move into an advanced run-detail disclosure.
6. Share prose, code, quote, table, and background tokens across native
   Markdown and controlled HTML/EPUB presentations. Preserve PDFKit and system
   preview fidelity while aligning surrounding chrome and capability notices.
7. Synchronize current-state docs and source notes, then update exact-head
   visual evidence before delivery.

## Test Plan

- Run focused AppModel, presentation, reader-persistence, Markdown renderer,
  and release metadata tests after each structural slice.
- Run `scripts/validate-native.sh`, dependency-lock, doc-index, project-drift,
  release packaging, Sandbox entitlement, codesign, and diff gates.
- Capture the exact implementation build at 1,440 × 900 and 900 × 650 on
  macOS in Library and reader states, with assistance open and closed.
- Build, sign, install, and launch the exact head on the connected physical
  iPhone. Capture Library and reader states in portrait and verify position
  restoration after process termination. Do not create or boot a Simulator.
- Check light/dark, Dynamic Type, VoiceOver labels, keyboard focus, Reduce
  Motion, long titles, one/20-Space Library, and PDF/EPUB/Markdown/HTML/code/
  system-preview surfaces.
- Request a final Sol max review and use only its conclusion as review evidence.

## Acceptance Evidence

Runtime implementation commit
`e3440e91cf25d186477dc196bf6bc41646fad5e6` is version 0.3.1 (4). Local Xcode 27
beta 6 `scripts/validate-native.sh` passes 227 tests plus release build, Sandbox
package, codesign/entitlement, project/documentation/release gates, and generic
iPhone/iPad SDK compilation. Hosted Xcode 26.6 baseline run
[`33618325465`](https://github.com/zzqDeco/OneReader/actions/runs/33618325465)
passes predecessor `f043198` through the same authoritative native validation;
hosted exact-head evidence for `e3440e9` is pending the feature-branch push.

Visual and performance evidence is local-only under `.onereader/acceptance/`:

- `ui-redesign-macos-library-exact-f043198.png` is the latest 900-pixel-wide
  Library state; `e3440e9` changes capture identity and Markdown resource/position
  behavior without changing that editorial layout;
- `ui-redesign-macos-reader-exact.png`,
  `ui-redesign-macos-library-exact.png`, and their 900 x 650 variants record the
  unchanged editorial layout at ancestor `57e8d81`;
- `ui-redesign-macos-scroll-exact.sample.txt` contains no application stack
  sample for whole-content hashing, `publishPosition`, database
  `saveReadingProgress`, or attributed-string replacement after the responsive
  scroll change;
- `ui-redesign-iphone-exact-83e52fc.png` records the valid connected-iPhone
  Library state at the named ancestor. The predecessor `f043198` build is signed
  and installed on the same iPhone 13 Pro Max with Xcode 27 beta 6; an exact
  `e3440e9` device build/install/launch remains open while the device is locked.

The real `WKWebView` tests cover exact capture/reload/restore, a delayed outgoing
capture across a Space switch, and exclusive capture by one of two mounted Web
views. Markdown tests cover image-range position fallback and parent-relative
book assets confined to the Snapshot. No Simulator device was created or booted.
Final physical launch and Sol max conclusion remain delivery gates.

## Non-goals

Physical iPad acceptance, Xcode 27 hosted migration, cloud sync, OCR, accounts,
new Agent tools, new Provider behavior, schema changes, new format adapters, a
new icon, or notarized/App Store distribution.

## Delivery Checklist

- [x] Native Editorial Reader design system recorded
- [x] Library and continuation shelf implemented
- [x] macOS reading hierarchy reduced to three or fewer semantic regions
- [x] iPhone reader chrome reduced to stable native controls
- [x] Reading Assistance replaces implementation-first Inspector presentation
- [x] Presentation typography and capability messaging unified
- [x] Existing reading position and annotation behavior preserved
- [x] Focused and unified validation passes
- [ ] Exact-head Mac and physical-iPhone acceptance recorded
- [x] Current-state and source docs synchronized
- [ ] Sol max final review passes
- [ ] Branch merged into `dev`
- [ ] Status changed to Delivered
