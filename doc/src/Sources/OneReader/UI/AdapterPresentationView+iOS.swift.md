# `Sources/OneReader/UI/AdapterPresentationView+iOS.swift`

Owns native UIKit bridges for the shared presentation registry. `UITextView`
renders selectable Markdown/text/code and maps selections and scroll positions
to the same source UTF-16 Locators as the macOS text bridge. `PDFView` emits page
and rectangle anchors, then restores the clipped rectangle before ambiguous
quote-only fallback and validates a recovered selection against its exact quote.
`QLPreviewController` preserves Quick Look's source-level capability limit.

The iOS `WKWebView` is non-persistent, disables Source JavaScript, loads only
the shared read-only `onereader-content` scheme, and hands an activated external
HTTP(S) link to `UIApplication`. Host-owned selection and position user scripts
produce DOM/quote Locators but cannot widen navigation or network authority.
