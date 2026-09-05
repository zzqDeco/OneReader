# `Sources/OneReader/UI/AdapterPresentationView+iOS.swift`

Owns native UIKit bridges for the shared presentation registry. `UITextView`
uses Dynamic Type-scaled serif prose (and monospaced code), renders selectable
Markdown/text/code, and maps selections and scroll positions
to the same source UTF-16 Locators as the macOS text bridge. `PDFView` emits page
and rectangle anchors. Saved viewport positions use the shared
[PDF capture observer](PDFReadingPosition.swift.md) and PDFDestination; selections
restore the clipped rectangle before ambiguous quote-only fallback and validate
a recovered selection against its exact quote.
`QLPreviewController` preserves Quick Look's source-level capability limit.

Every UIKit bridge emits the same rich position update as its AppKit peer:
text fraction and source line, PDF page fraction, controlled-Web DOM/quote and
scroll fraction, or Quick Look document granularity. Incoming Web positions try
the exact visible DOM/quote evidence, preserve the nearest outline heading in a
separate payload field, and use normalized fraction for the same-Snapshot
viewport. Dynamic Markdown positions carry the current line rather than a stale
heading path.

Live `UITextView` scrolling uses one 150 ms coalescer per scroll burst and
flushes immediately when dragging or deceleration ends. It also answers the
same synchronous host capture signal as AppKit before navigation or lifecycle
flushes, but only after an exclusive target and Source/Snapshot match. Image or
unmappable-leaf viewports use a real source-range/nearest-run position fallback
without weakening selection anchors. Presentation IDs, rather than full-content
hashing during view updates, guard expensive Markdown rendering. Markdown image width comes from
the active text container/window scene and is re-rendered when that width
changes; it never depends on a process-global screen singleton.

Compact reader chrome is composed outside these bridges, so every format keeps
the same native navigation and four-action bottom bar.

The iOS `WKWebView` is non-persistent, disables Source JavaScript, loads only
the shared read-only `onereader-content` scheme, and hands an activated external
HTTP(S) link to `UIApplication`. Host-owned selection and position user scripts
produce DOM/quote Locators but cannot widen navigation or network authority.

DEBUG recovery tests use read-only accessibility observations from the mounted
PDFView/WKWebView (page coordinates and native scroll offsets). Saved-position
metadata is exposed separately by AppModel and cannot satisfy the viewport
assertions. These observation subclasses compile to native typealiases in
Release builds and do not enable Source scripts or change gesture ownership.
