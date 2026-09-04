# `Sources/OneReader/UI/WorkspaceViewV2.swift`

Owns the Library-first Apple-platform composition, generic import surfaces,
toolbar actions, removal/large-import confirmations, and drag/drop.

One outer `NavigationSplitView` owns the leading context. Its sidebar shows
Library navigation while browsing, then replaces that content with reading
navigation when a Space opens. The detail therefore contains the reader and at
most one optional 338-point Reading Assistance panel, never four simultaneous
columns. The panel becomes a trailing overlay drawer below 760 points.
Regular-width iPad uses the shared in-layout workspace. Compact iPhone preserves
a full-width reader, uses one inline native navigation bar and a fixed four-item
bottom bar, and presents reading navigation and Reading Assistance in independent
sheets. `fileImporter` owns iOS/iPadOS selection;
the AppModel routes its result without adding format-specific entry points.
The scene lifecycle flushes the latest debounced reading position whenever it
leaves the active state, before suspension can discard it. Animation is
disabled when Reduce Motion is active. Search requests travel through a
host-owned reveal token: a hidden regular-width leading column is reopened, and
compact iPhone presents the navigation sheet, so toolbar and keyboard search
never change an invisible tab.

Each mounted workspace owns a stable reading-capture target. A narrow native
window observer activates that target only when its `NSWindow` or `UIWindow`
becomes key, keeping shared-model capture requests tied to the window the user
is actually reading.
