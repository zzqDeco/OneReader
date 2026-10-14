# `Sources/OneReader/UI/PDFReadingPosition.swift`

Owns shared PDFKit viewport capture for AppKit and UIKit. The native scroll view
retains its own delegate and gesture recognizers. Offset/bounds notifications
are coalesced for 150 ms; a matching window/Source/Snapshot capture request or
view teardown captures immediately before the existing AppModel persistence
boundary.

The Locator preserves `pageIndex` and page-coordinate `rect`. Viewport positions
add optional `positionKind=viewport`, `viewportX`, and `viewportY` payload fields;
they use a PDFDestination rather than selection scrolling, which intentionally
does nothing when a rectangle is already visible. Coordinates are measured from
the mounted view, checked for finiteness, and confined to the displayed page.
The view's top edge is converted with the platform's coordinate orientation.
AppKit captures optional `viewportScreenX`/`viewportScreenY` in [0, 1], measured
from the left/top edges of the viewport to that bounded page anchor. These retain
side/page-gap whitespace without weakening page-coordinate validation. UIKit
capture removes these AppKit-only fields rather than retaining stale metadata.
`restore` applies the PDFDestination, converts the anchor and requested screen
placement into native clip coordinates, and constrains the corrected bounds.
This works with scaled clip views, mixed page widths and rotated pages. Missing
or invalid placement uses legacy destination behavior; invalid page coordinates
or quote-bearing positions never enter this viewport restore path. Equal-layout
regressions compare actual PDFView screen X/Y and validate constrained native
clip origin X/Y, not twice-clamped page X. Absolute clip origins belong to each document
view's coordinate space and are not a cross-view restoration contract.
Page fraction is measured on the displayed vertical axis, so rotations of
0/90/180/270 degrees neither reverse progress nor confuse the page-space axes.
`ReadingPDFView` waits for a nonzero laid-out viewport before applying a pending
destination once. Teardown discards pending restoration; capture stays suspended
until it completes. Repeated equal zoom values do not reset PDFKit layout.
AppKit also requires PDFKit's enclosing scroll view after document layout; an
unmounted clip leaves the pending anchor intact rather than consuming it. The
deferred mixed-width test mounts from zero bounds with legacy scroller layout,
checks both screen axes and constrained clip origins, then repeats layout in that
same restored view to reject duplicate application or raw clip-origin drift.
The UIKit view also reports post-layout viewport bounds to its PDF zoom
coordinator. That callback does not intercept gestures; initial fitting waits
for usable bounds and ordinary position updates cannot reset native pinch zoom.

A saved viewport is not a text selection. A quote-bearing Locator still uses
selection geometry, and new PDF selections remove viewport-only metadata.
Native capture always removes OCR identity and both generic/page-relative text
offsets, including a returned fragment that already uses the native PDF adapter.
Only the freshly measured page/viewport geometry describes ordinary scrolling.
Old page/rect Locators remain readable without migration. The observer is
cancelled and disconnected when its native view is dismantled.
