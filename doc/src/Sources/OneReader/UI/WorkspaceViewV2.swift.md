# `Sources/OneReader/UI/WorkspaceViewV2.swift`

Owns the Library-first macOS window composition, generic import surfaces,
toolbar commands, removal/large-import confirmations, and drag/drop.

One outer `NavigationSplitView` owns Library navigation. The open Space uses a
SwiftUI horizontal layout rather than a nested `HSplitView`. Its Inspector is a
338-point in-layout column when the detail is wide and a trailing overlay
drawer below 920 points. This keeps 900 x 650 usable and prevents AppKit
constraint feedback with PDFKit or long selectable text. Overlay animation is
disabled when Reduce Motion is active.
