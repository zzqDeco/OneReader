# ReaderChrome.swift

Owns small native application-chrome primitives shared by Library, import,
notes and OCR controls. It does not render source content or own application
state, Providers, persistence, gestures or progress capture.

- `ReaderActionLabel` places the platform's minimum hit height inside the
  Button label. The rendered text uses semantic system fonts and colors.
- `ReaderAdaptiveActions` tries a natural-width horizontal action group before
  stacking it; accessibility Dynamic Type sizes always stack. Controls remain
  separate accessibility children through `.contain`, never `.combine`.
- `ReaderSectionHeading`, `ReaderPanelHeading` and `ReaderStatusBadge` express
  hierarchy/status with text and SF Symbols rather than decorative elevation.
- `ReaderChromeMetrics` separates touch and pointer target metrics and the
  shelf's compact/enlarged card widths. These tokens are not reading-body sizes.

NotesCenterFooter retains its real native `notes-export` AppKit button and
keyboard equivalent. `ReaderChromeLayoutTests` adds a narrow, enlarged-type
mounted-control regression for that export action. Tests/build/native screenshots
are distinct gates; no static token test proves visible application acceptance.
