# `Sources/OneReader/UI/AdapterPresentationView+iOS.swift`

Owns native UIKit bridges for the shared presentation registry. `UITextView`
uses Dynamic Type-scaled serif prose (and monospaced code), renders selectable
Markdown/text/code, and maps selections and scroll positions
to the same source UTF-16 Locators as the macOS text bridge. `PDFView` emits page
and rectangle anchors, then restores the clipped rectangle before ambiguous
quote-only fallback and validates a recovered selection against its exact quote.
`QLPreviewController` preserves Quick Look's source-level capability limit.

Every UIKit bridge emits the same rich position update as its AppKit peer:
text fraction and source line, PDF page fraction, controlled-Web DOM/quote and
scroll fraction, or Quick Look document granularity. Incoming Web positions try
DOM/quote relocation before the fraction fallback.

Live `UITextView` scrolling coalesces position sampling for 150 ms and flushes
immediately when dragging or deceleration ends. Presentation IDs, rather than
full-content hashing during view updates, guard expensive Markdown rendering.

Compact reader chrome is composed outside these bridges, so every format keeps
the same native navigation and four-action bottom bar.

The iOS `WKWebView` is non-persistent, disables Source JavaScript, loads only
the shared read-only `onereader-content` scheme, and hands an activated external
HTTP(S) link to `UIApplication`. Host-owned selection and position user scripts
produce DOM/quote Locators but cannot widen navigation or network authority.
