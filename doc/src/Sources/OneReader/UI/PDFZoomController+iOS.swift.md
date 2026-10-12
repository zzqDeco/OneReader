# `Sources/OneReader/UI/PDFZoomController+iOS.swift`

Owns iOS PDF scale updates without taking native pinch-gesture ownership.
Fit width derives from the current PDF page's displayed width, rotation, page
break margins, and the mounted viewport. Zero-sized layout cannot consume a
default or command. Bounds allow 50% through 600% of fit width; persisted
defaults remain limited to 50% through 300%.

The controller tracks the last applied default, viewport width, and command
UUID. Repeated host position updates cannot rewrite a user pinch scale or
reapply a button action. Explicit commands multiply the live native scale by
1.25 or its inverse, or return to fit width. A viewport-width change retains
relative zoom; a new document resets this state. PDFKit notifications emitted
by host writes are guarded against reentry.

Initial fitting uses the requested restore page rather than PDFKit's temporary
first `currentPage`. Deferred anchor navigation reconciles the fit basis with
its actual target page while retaining relative zoom. Mixed-width PDFs therefore
cannot reopen a wider saved page at the first page's scale while claiming 100%.

Continuous layout can retain the widest page's canvas around narrower pages.
After page-start navigation and explicit fit-width requests, horizontal
alignment converts the actual page/view centers into native scroll coordinates
and clamps only the horizontal content offset to adjusted-inset bounds. Vertical
placement is retained. The helper neither installs gestures nor replaces a
delegate, and it is not run on scrolling, pinch, position saves or repeated
host updates. Exactly-once command consumption also prevents repeated recentering.
Viewport restoration may remount at the configured fit scale rather than the
previous ephemeral pinch. If the target page fits, normalize horizontal canvas
placement while retaining vertical offset; otherwise preserve the saved pan.
Do not apply this normalization to selection/quote navigation.

Native-device unit tests use real PDFView geometry, including rotated pages,
zero-to-nonzero layout, invalid defaults, bounds, width changes, and exactly-once
commands. UI tests separately use actual pinch and swipe gestures and observe
the mounted PDFView, not a stored preference or reading Locator.
Mixed-width fixtures additionally exercise next-page navigation and process
relaunch on a wider page through the real system picker. Narrow-first-page tests
assert both actual page edges are inside the viewport, not merely its width;
the opt-in real 252-page book exercises the same native canvas condition.
