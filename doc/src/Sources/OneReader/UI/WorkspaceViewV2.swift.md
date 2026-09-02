# `Sources/OneReader/UI/WorkspaceViewV2.swift`

Owns the Library-first Apple-platform composition, generic import surfaces,
toolbar actions, removal/large-import confirmations, and drag/drop.

One outer `NavigationSplitView` owns Library navigation. The open Space uses a
SwiftUI horizontal layout rather than a nested `HSplitView`. Its Inspector is a
338-point in-layout column when the Mac detail is wide and a trailing overlay
drawer below 920 points. Regular-width iPad uses the shared in-layout workspace.
Compact iPhone preserves a full-width reader and presents reading navigation
and Inspector in independent sheets. `fileImporter` owns iOS/iPadOS selection;
the AppModel routes its result without adding format-specific entry points.
Animation is disabled when Reduce Motion is active.
