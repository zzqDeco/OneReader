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
Page fraction is measured on the displayed vertical axis, so rotations of
0/90/180/270 degrees neither reverse progress nor confuse the page-space axes.
`ReadingPDFView` waits for a nonzero laid-out viewport before applying a pending
destination once. Teardown discards pending restoration; capture stays suspended
until it completes. Repeated equal zoom values do not reset PDFKit layout.

A saved viewport is not a text selection. A quote-bearing Locator still uses
selection geometry, and new PDF selections remove viewport-only metadata.
Old page/rect Locators remain readable without migration. The observer is
cancelled and disconnected when its native view is dismantled.
