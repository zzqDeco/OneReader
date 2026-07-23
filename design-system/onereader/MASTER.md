# OneReader macOS Design System

> This file is the visual source of truth for the native application. Page
> overrides live under `pages/` and only document intentional deviations.

**Project:** OneReader  
**Platform:** macOS 14+  
**Framework:** SwiftUI with AppKit/PDFKit bridges  
**Updated:** 2026-07-23

## Product character

OneReader should feel like a calm research desk: information-dense enough for
serious reading, but quieter than an IDE. The interface follows macOS window,
toolbar, menu, focus, selection, and accessibility conventions.

## Color and materials

Use semantic platform colors before fixed RGB values so light mode, dark mode,
increased contrast, and vibrancy remain correct.

| Role | SwiftUI token | Use |
| --- | --- | --- |
| Window/background | `Color(nsColor: .windowBackgroundColor)` | Primary surfaces |
| Secondary surface | `Color(nsColor: .underPageBackgroundColor)` | Reading canvas |
| Primary text | `.primary` | Titles and body |
| Secondary text | `.secondary` | Metadata and hints |
| Selection/focus | `.tint` with teal accent | Current source, unit, and controls |
| Completion | `.green` | Completed units only |
| Warning/action | `.orange` | Stale evidence and exceptional actions |
| Separator | `Color(nsColor: .separatorColor)` | Structural boundaries |

The app accent is a restrained teal. Orange is semantic, not decorative. Never
place body text directly on a saturated accent.

## Typography

- Use the system font so Dynamic Type, Chinese glyph fallback, and platform
  metrics work without bundled fonts.
- Reader body: system serif, 17 pt, comfortable line spacing.
- Interface body: system default, 13–14 pt.
- Titles: system rounded or default semibold; avoid oversized marketing type.
- Monospaced text is reserved for revision IDs, locators, and source paths.

## Spacing and shape

Use a 4 pt base grid: 4, 8, 12, 16, 24, and 32 pt. Reading text uses a maximum
line width rather than filling the window. Corner radii are 6 pt for compact
controls and 10–12 pt for reading/evidence cards.

Do not add decorative shadows to ordinary panels. Platform sheets, popovers,
menus, split views, and materials provide their own elevation.

## Native interaction rules

- Use `NavigationSplitView`, `List`, `ToolbarItem`, `Commands`, `sheet`, and
  `fileImporter` for their standard behaviors and keyboard support.
- Use SF Symbols only; labels pair an icon with text when meaning is not
  obvious.
- Selection must remain visible with keyboard navigation.
- Every toolbar action has a help string; primary actions also have menu
  commands and shortcuts where useful.
- Avoid animation unless it explains state continuity. Respect Reduce Motion
  implicitly by relying on platform control transitions.
- Loading, empty, error, stale-revision, and completed states are explicit.
- Never use hover-only disclosure or mobile gestures as the sole interaction.

## Window sizes

| Preset | Content size | Behavior |
| --- | --- | --- |
| Compact | 900 × 650 | Source sidebar + reader; route inspector hidden |
| Reading | 1440 × 900 | Source sidebar + reader + route inspector |

The user may resize beyond presets. At constrained widths, preserve the reader
before auxiliary inspection UI. Comparison mode divides the reader canvas into
equal Repo/PDF panes and must not force the window to grow.

## Accessibility checklist

- Semantic labels and help on icon-only buttons.
- Full keyboard operation for sources, reading units, goals, and commands.
- System colors remain legible in light/dark and increased-contrast modes.
- Status is conveyed by text or symbol as well as color.
- Reader content remains selectable and scrollable.
- No fixed font family that breaks Chinese fallback.
- No geometry with negative sizes during split-view compression.

## Delivery checklist

- [ ] Light and dark appearance checked in the packaged `.app`.
- [ ] Compact and reading window presets checked.
- [ ] Repo, PDF, and comparison presentations checked.
- [ ] Progress survives relaunch.
- [ ] Stale revision is visible and cannot be silently treated as current.
- [ ] Keyboard shortcuts and native menus work.
- [ ] No AppKit constraint or negative-geometry warnings during normal use.
