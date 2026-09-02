# OneReader Apple-Platform Design System

> This file is the visual source of truth for the native application. Page
> overrides live under `pages/` and document only intentional deviations.

**Project:** OneReader

**Platforms:** macOS, iOS, and iPadOS 26.1+

**Framework:** SwiftUI with narrow AppKit/UIKit/PDFKit bridges

**Updated:** 2026-09-01

## Product character

OneReader should feel like a calm research desk: information-dense enough for
serious reading, but quieter than an IDE. The interface follows each platform's
navigation, toolbar, menu, focus, selection, and accessibility conventions.
Reading content is always more prominent than Agent Activity or chat.

## Color and materials

Use semantic platform colors before fixed RGB values so light mode, dark mode,
increased contrast, and native materials remain correct.

| Role | SwiftUI token | Use |
| --- | --- | --- |
| App/background | `ReaderTheme.window` | Primary surfaces |
| Reading surface | `ReaderTheme.paper` | Reader canvas |
| Primary text | `.primary` | Titles and body |
| Secondary text | `.secondary` | Metadata and hints |
| Selection/focus | `.tint` with teal accent | Current source, unit, and controls |
| Completion | `.green` | Completed units only |
| Warning/action | `.orange` | Stale evidence and exceptional actions |
| Separator | semantic platform separator | Structural boundaries |

The app accent is a restrained teal. Orange is semantic, not decorative. Never
place body text directly on a saturated accent.

## Typography

- Use the system font so Dynamic Type, Chinese glyph fallback, and platform
  metrics work without bundled fonts.
- Reader body defaults to 17 pt with comfortable line spacing; iPhone and iPad
  text views opt into Dynamic Type.
- Interface text uses the active platform's standard metrics.
- Titles are system semibold; avoid oversized marketing typography.
- Monospaced text is reserved for revision IDs, locators, code, and source paths.

## Spacing and shape

Use a 4 pt base grid: 4, 8, 12, 16, 24, and 32 pt. Reading text uses a maximum
line width rather than filling a wide window. Corner radii are 6 pt for compact
controls and 10–12 pt for reading/evidence cards.

Do not add decorative shadows to ordinary panels. Platform sheets, popovers,
menus, split views, and materials provide their own elevation.

## Native interaction rules

- Use `NavigationSplitView`, `NavigationStack`, `List`, `ToolbarItem`,
  `Commands`, `sheet`, and `fileImporter` for standard behavior.
- Use SF Symbols only; labels pair an icon with text when meaning is not obvious.
- Selection remains visible with keyboard navigation.
- Every icon-only action has an accessibility label and help where supported.
- Avoid animation unless it explains continuity; respect Reduce Motion.
- Loading, empty, error, stale-revision, and completed states are explicit.
- Never use hover-only disclosure or touch gestures as the sole interaction.

## Adaptive layouts

| Context | Reference size | Behavior |
| --- | --- | --- |
| iPhone portrait | compact width | collapsed Library, full-width reader, navigation and Inspector sheets |
| iPad split/full screen | regular width | Library split plus reading navigation/content/Inspector |
| Mac compact | 900 × 650 | Library/sidebar + reader; Inspector drawer or hidden |
| Mac reading | 1440 × 900 | Library/sidebar + reader + trailing Inspector |

At constrained widths, preserve the reader before auxiliary inspection UI.
Never encode device names as layout rules; use horizontal size class and
measured content width.

## App icon

- Use the full-square 1024 px master under `Design/AppIcon/`; the OS owns masks.
- Layered teal pages represent heterogeneous sources; the warm central path is
  both a reading route and a subtle numeral one.
- Keep the midnight field, book silhouette, and central path readable at 16 px.
- No text, border, device mockup, baked gloss, or separate mobile identity.
- Regenerate every AppIcon slot and the macOS `.icns` with
  `scripts/generate-app-icons.sh`; do not hand-edit derived images.

## Accessibility checklist

- Semantic labels and help on icon-only buttons.
- Full keyboard operation where a keyboard is present.
- System colors remain legible in light/dark and increased-contrast modes.
- Status is conveyed by text or symbol as well as color.
- Reader content remains selectable and scrollable.
- No fixed font family that breaks Chinese fallback.
- No geometry with negative sizes during split-view compression.

## Delivery checklist

- [ ] Light and dark appearance checked in native builds.
- [ ] iPhone compact, iPad regular/split, and Mac compact/reading layouts checked.
- [ ] PDF, Markdown/text/code, HTML/EPUB, and Quick Look surfaces checked.
- [ ] Icon checked at 16, 32, 60, 76, 128, 256, 512, and 1024 px.
- [ ] Progress survives relaunch.
- [ ] Stale revision is visible and cannot be silently treated as current.
- [ ] Keyboard, menu, pointer, and touch controls work where applicable.
- [ ] No AppKit/UIKit constraint or negative-geometry warnings during use.
