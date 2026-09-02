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
All readable surfaces also emit position Locators; PDFKit observes page changes
and applies an incoming page/quote anchor only once rather than snapping the
reader back after later scrolling.

The presentation descriptor makes Quick Look limitations machine-readable so
the workspace does not expose unsupported search or structured highlight UI.
