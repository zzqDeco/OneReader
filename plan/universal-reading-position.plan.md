# Universal Reading Position

Status: Active

Branch: `feature/universal-reading-position`

Milestone: `v0.3.1`

Dependencies: [Apple multiplatform reader](apple-multiplatform-v1.plan.md)

## Summary

Make resume position a shared reader capability instead of a collection of
surface-specific Locators. Every presentation publishes one normalized,
Snapshot-bound `ReadingPositionUpdate`; the host owns validation, debouncing,
lifecycle flushing, persistence, Library progress, and restart restoration.

## User Behavior

- Closing a Space, switching Source, or sending the app to the background does
  not lose the last visible reading position.
- Reopening a Space resumes its most recently read Source and restores the
  strongest position supported by that material.
- PDF shows page progress; Markdown, text, code, directories, and repositories
  show child path plus line/range progress; HTML, web snapshots, and EPUB show
  spine/path plus DOM/quote and scroll progress.
- Quick Look participates honestly at document granularity: OneReader remembers
  that the Source was opened, but does not claim access to the system preview's
  private internal page or scroll state.
- The reader footer and Library cards expose the saved position without
  requiring a Provider or Reading Graph.

## Contracts/Migration

- `SourcePosition` retains Locator, update time, optional normalized fraction,
  granularity, and a bounded user-facing label.
- New optional fields decode from existing schema-v1 progress JSON without a
  database schema migration; invalid fractions or oversized labels fail closed
  on persistence.
- Source revision relocation preserves position metadata only when the Locator
  resolves to the new immutable Snapshot. Failed resolution removes the current
  position instead of presenting a stale anchor as current.
- Source-position progress, graph-unit completion, frozen-plan step, and reading
  history remain independent facts.

## Implementation

- Normalize PDFKit, native text/Markdown/code, controlled WebKit, EPUB, and
  Quick Look callbacks to `ReadingPositionUpdate` on macOS, iOS, and iPadOS.
- Preserve directory/repository child identity through Locator `path`/`href`
  payloads while recording the child surface's page, text, or DOM position.
- Keep the 350 ms write debounce during continuous scrolling, but retain a
  pending update and synchronously flush it before Source/Space transitions and
  whenever the SwiftUI scene leaves the active phase.
- Restore WebKit by structural/quote anchor first and normalized scroll fraction
  second. Preserve existing exact text and PDF page restoration behavior.
- Show the current saved label in the reader footer and the latest resume target
  on Library cards. Use aggregate Source fractions when present and graph-unit
  completion only as a fallback.

## Test Plan

- Cover rich position round trips, existing metadata-free decoding, validation,
  explicit lifecycle flush, immediate Source switch, restart restoration,
  refresh relocation, and no-Provider Library progress.
- Compile both native presentation implementations and exercise the complete
  shared test suite and release validation.
- Keep Simulator device instances empty and rebuild, sign, install, and launch
  the exact implementation commit on a connected physical iPhone.
- Request one final Sol max review and accept only its conclusion, not an
  intermediate process transcript.

## Acceptance Evidence

Record the exact implementation commit, test total, macOS release/package and
entitlement gates, generic universal-target compile, empty Simulator device
list, physical-device build/install/launch evidence, unavailable physical iPad
scope, and final reviewer disposition.

## Non-goals

Cross-device sync, percentage inference for unknown Quick Look content, OCR,
background source refresh, arbitrary private preview APIs, or merging source
position with AI route completion.

## Delivery Checklist

- [x] Shared position contract and presentation callbacks implemented
- [x] Transition and lifecycle flush implemented
- [x] Library and reader resume affordances implemented
- [x] Focused persistence and AppModel tests pass
- [ ] Current-state and source docs synchronized
- [ ] Full local and physical-device validation passes at exact head
- [ ] Final Sol max review accepted
- [ ] Branch merged into `dev`
