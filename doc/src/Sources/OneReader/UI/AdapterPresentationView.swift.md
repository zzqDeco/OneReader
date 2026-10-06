# `Sources/OneReader/UI/AdapterPresentationView.swift`

Owns platform-neutral presentation-surface registration, content loading, and
the macOS native bridges for PDFKit, selectable Markdown/text/code, sanitized
WebKit, and Quick Look. The iOS/UIKit representables live in the adjacent
`AdapterPresentationView+iOS.swift`; both consume the same descriptors,
sanitizer, resource scheme handler, and Locators.

WebKit is non-persistent and has JavaScript disabled. Managed resources are
served through a read-only custom scheme rooted at one snapshot directory;
automatic and cross-scheme navigation is cancelled. A user-activated HTTP(S)
link is the only path to the default browser. Resource loads reject path and
symlink escape, apply an explicit MIME allowlist and 32 MiB per-resource cap,
stream in 256 KiB chunks, and stop without another callback after cancellation.
The scheme lifecycle serializes response, data, terminal callback, and stop;
stop waits for an in-progress callback and no callback starts after it returns.
The system theme follows the current platform color scheme.

Locator changes do not merely reopen the containing document. Native text and
Markdown select/scroll to the quote with prefix/suffix disambiguation, PDFKit
goes to the recorded page and prefers a validated, page-clipped rect anchor,
and the host-owned WebKit bridge scrolls to a safely escaped DOM/quote anchor
while suppressing synthetic selection callbacks. The shared
`PDFPageRectAnchor` parser rejects malformed, non-finite, empty, and out-of-page
geometry before either platform bridge uses it.
All readable surfaces emit normalized `ReadingPositionUpdate` values. PDFKit
observes the native viewport and reports rotation-aware page fraction; native Markdown/text/code
reports source range, line, quote, and text fraction; controlled WebKit reports
the visible-element DOM path, a separate nearest outline-heading path, quote,
and scroll fraction. Same-Snapshot restoration uses the fraction for the exact
viewport after resolving DOM/quote evidence; relocation can still use that
evidence when layout changes. Directory/repository and EPUB child `path`/`href`
identity stays in the Locator. Incoming anchors are applied only once rather
than snapping the reader back after later scrolling.
Native text viewport Locators additionally retain a source-anchor-relative line
offset (`positionKind=textViewport`, `textViewportOffsetY`, `textViewportX`).
The AppKit and UIKit bridges apply these only after layout and clear them from
explicit selections. Existing quote-only Locators keep selection semantics.

The AppKit text bridge uses one 150 ms coalescer for an entire live-scroll
burst, rather than creating work or deriving a Locator on every bounds change.
It samples immediately when live scrolling ends. Before a Source, Space, or
scene transition flushes progress, the host also sends a synchronous capture
signal to the active native bridge; the fresh sample reaches `AppModel` before
its generation token changes. Native and Web bridges claim that request only
when both their window presentation target and Source/Snapshot match; one
main-actor claim is exclusive. Render identity comes from the immutable
presentation ID instead of re-hashing the complete chapter whenever SwiftUI
updates, and non-contiguous TextKit layout remains enabled for long chapters.
Dynamic Markdown positions replace a heading-only structural path with the
current file path and line so outline navigation follows the section currently
being read. If the viewport begins on an image or another intentionally
unselectable Markdown leaf, position capture uses its real source range or the
nearest mapped source run rather than retaining the previous position.

The presentation descriptor makes Quick Look limitations machine-readable so
the workspace does not expose unsupported search or structured highlight UI.
Quick Look emits only a document-granular last-open update.
