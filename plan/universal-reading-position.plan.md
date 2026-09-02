# Universal Reading Position

Status: Delivered

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
- Source revision relocation preserves only an anchor that resolves to the new
  immutable Snapshot. Its old fraction, granularity, and label are cleared until
  the revised presentation measures them again; failed resolution removes the
  current position instead of presenting a stale anchor as current.
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
- Bind every callback and pending write to a host-owned presentation token.
  Child navigation and Source refresh replace that token, so late callbacks can
  never overwrite the current child or a newer immutable Snapshot.
- Restore WebKit by structural/quote anchor first and normalized scroll fraction
  second. Preserve existing exact text and PDF page restoration behavior.
- Show the current saved label in the reader footer and the latest resume target
  on Library cards. Use aggregate Source fractions when present and graph-unit
  completion only as a fallback.

## Test Plan

- Cover rich position round trips, existing metadata-free decoding, validation,
  explicit lifecycle flush, immediate Source switch, same-Source child callback
  rejection, restart restoration, refresh/debounce interleaving, historical
  Snapshot rejection, refresh relocation, and no-Provider Library progress.
- Inject failures on both sides of the refresh commit boundary: pre-commit
  failure must reopen the old readable Snapshot, while a committed but
  unrenderable revision must end in an explicit unavailable state, never an
  indefinite loading surface.
- Compile both native presentation implementations and exercise the complete
  shared test suite and release validation.
- Keep Simulator device instances empty and rebuild, sign, install, and launch
  the exact implementation commit on a connected physical iPhone.
- Request one final Sol max review and accept only its conclusion, not an
  intermediate process transcript.

## Acceptance Evidence

Implementation commit `dc87f405bc6bae9c45aad93f0ead442dcc89bb9e`
passed 204 tests. Xcode 27 beta 6 built and signed the universal iOS target with
the iOS 27 SDK, then installed and launched it on the connected iPhone 13 Pro
Max running iOS 27.0 beta. The device imported the public
`xiaolai/time-as-a-friend` README, persisted its Snapshot-bound Markdown
Locator, text granularity, label, quote, range, and normalized fraction, then
restored and republished that position after a terminated-process relaunch.

The stable Xcode 26.6 validation path passed dependency-lock, documentation,
project-drift, release-fixture, entitlement, 204-test, release-build, Sandbox
package, codesign, and generic universal-target compilation gates. The generic
target compilation created or booted no Simulator device, and the Simulator
device list remained empty. No physical iPad was connected, so physical iPadOS
gesture and regular-width layout evidence remains unavailable.

The final Sol max reviewer returned `APPROVE` with no P0, P1, P2, or P3 finding
and no delivery blocker.

## Non-goals

Cross-device sync, percentage inference for unknown Quick Look content, OCR,
background source refresh, arbitrary private preview APIs, or merging source
position with AI route completion.

## Delivery Checklist

- [x] Shared position contract and presentation callbacks implemented
- [x] Transition and lifecycle flush implemented
- [x] Library and reader resume affordances implemented
- [x] Focused persistence and AppModel tests pass
- [x] Current-state and source docs synchronized
- [x] Full local and physical-device validation passes at exact head
- [x] Final Sol max review accepted
- [x] Branch merged into `dev`
