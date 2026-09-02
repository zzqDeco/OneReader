# Reading Workspace Overrides

> These rules refine `../MASTER.md` for the main OneReader workspace.

## Information architecture

The regular-width workspace has four semantic regions:

1. Library sidebar — Spaces, recents, processing, and favorites.
2. Reading navigation — Outline, Sources, Route, and Search.
3. Reader canvas — the selected native presentation.
4. Inspector — annotations, evidence, Agent Activity, and questions.

The Inspector is auxiliary. It becomes a Mac drawer at constrained widths and
a sheet on compact iPhone. Reading navigation is also a separate iPhone sheet.

## Library and reading navigation

- Library default width: 250 pt; reading navigation: 210–245 pt.
- Sources and units use native list selection, not card grids.
- Completion state uses both an SF Symbol and a text/accessibility value.
- Revision metadata is abbreviated visually but available to accessibility.

## Reader canvas

- Treat the canvas as the visual anchor.
- Keep prose to a comfortable measure with generous vertical rhythm.
- Place title, revision, presentation type, explicit source handoff, and
  appearance controls in a stable header.
- Markdown uses the shared source-mapped native attributed-text renderer.
- PDF uses `PDFView` in continuous vertical mode with stable page and selection
  Locators.
- Compact iPhone uses a horizontally scrollable icon footer with explicit
  accessibility labels instead of compressing every action.

## Inspector

- Regular-width default: 338 pt.
- Goal selection is explicit: systematic, quick overview, or review.
- Generated routes explain why each unit exists and which evidence anchors it.
- AI-derived material remains visually distinct from source material.

## States

- Loading: progress indicator plus the resource being resolved.
- Empty: concrete next action, such as selecting a unit or importing a source.
- Error: recoverable explanation in a native alert.
- Stale: warning that the Locator revision is historical; never silently remap.
- Reading/completed: visible in navigation and reader UI, persisted locally.

## Acceptance

- At 1440 × 900, all regular-width regions are comfortably readable.
- At 900 × 650, the Mac sidebar and reader remain usable with a drawer Inspector.
- On iPhone portrait, reader content is not squeezed by navigation or Inspector.
- On iPad regular width, reading navigation and Inspector can coexist without
  reducing content below a useful measure.
- Light and dark appearance use native semantic colors without special cases.
