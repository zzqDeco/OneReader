# Reading Workspace Overrides

> These rules refine `../MASTER.md` for the main OneReader window.

## Information architecture

The workspace has three semantic regions:

1. Source sidebar — sources, units, status, and import/reload actions.
2. Reader canvas — the selected unit rendered as Repo, PDF, or an equal
   comparison.
3. Route inspector — goal, generated sequence, evidence, and provenance.

The route inspector is auxiliary. It automatically closes in the 900 × 650
compact preset and is user-toggleable from the toolbar.

## Source sidebar

- Default width: 250 pt; usable range 220–340 pt.
- Sources and units use native list selection, not card grids.
- Completion state is shown with both an SF Symbol and a text/accessibility
  value.
- Revision metadata is abbreviated visually but exposed in full via help text.

## Reader canvas

- Treat the canvas as the visual anchor.
- Keep prose to a comfortable measure with generous vertical rhythm.
- Place title, source badge, revision, locator, presentation control, and
  completion action in a stable header.
- Markdown presentation is intentionally small and deterministic for the MVP:
  headings, paragraphs, quotes, lists, code, links, and separators.
- PDF uses `PDFView` in single-page horizontal mode to avoid unconstrained
  intrinsic geometry inside SwiftUI split views.
- Comparison uses equal-width panes separated by a platform divider.

## Route inspector

- Default width: 300 pt.
- Goal selection is explicit: systematic, quick overview, or review.
- Generated routes show why each unit exists and which evidence anchors it.
- AI-derived material must remain visually distinct from source material.

## States

- Loading: progress indicator plus the resource being resolved.
- Empty: concrete next action, such as selecting a unit or importing a source.
- Error: recoverable explanation in a native alert.
- Stale: warning that the locator revision no longer matches the current
  snapshot; never silently remap.
- Reading/completed: visible in sidebar and reader header, persisted locally.

## Acceptance

- At 1440 × 900, all three regions are comfortably readable.
- At 900 × 650, the sidebar and reader remain usable with the inspector hidden.
- Repo/PDF comparison does not resize the window.
- Light and dark appearance use native semantic colors without special-case
  overrides.
