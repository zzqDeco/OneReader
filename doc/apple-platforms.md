# Apple Platforms

## Target model

OneReader ships one native product across macOS, iPhone, and iPad. The shared
Swift package target named `OneReader` owns domain contracts, GRDB persistence,
managed snapshots, deterministic adapters, the Reading Agent runtime, and most
SwiftUI views. `Apps/OneReaderApp/OneReaderAppMain.swift` is a thin executable
wrapper around the public `OneReaderScene`.

`project.yml` is the source of truth for two application targets:

| Target | Platform behavior |
| --- | --- |
| `OneReader-macOS` | native AppKit application, Sandbox, read-only user-selected files, client network entitlement |
| `OneReader-iOS` | native universal iPhone/iPad application with device families 1 and 2; Catalyst disabled |

`OneReader.xcodeproj` is checked in so the app can be opened immediately, but it
must match a fresh XcodeGen rendering of `project.yml`. Both targets consume the
local `OneReader` package product and the same exact `Package.resolved` graph.
There is no copied mobile module, second database schema, or format-specific
mobile product mode.

## Adaptive application shell

The root is one `NavigationSplitView` on every platform. macOS and regular-width
iPad keep Library navigation beside a content-first reader workspace. iPhone
uses the system compact split-view collapse, presents Outline/Sources/Route/
Search in a navigation sheet, and presents annotations, evidence, Activity,
and questions in a separate Inspector sheet. The reading content remains the
primary surface in every size class.

macOS alone owns menu commands, Settings scene, window presets, `NSOpenPanel`,
and Finder handoff. iOS/iPadOS expose equivalent import and settings actions in
the toolbar, use `fileImporter`, accept Open In URLs, and hand explicit external
links to `UIApplication`. iPad supports pointer, keyboard, drag/drop, split
screen, and all four orientations through native SwiftUI behavior.

## Import, storage, and removal

Each installation owns its own Application Support root and `Library.sqlite`.
This release does not synchronize Libraries across devices. A selected URL is
accessed only while the Managed Library inspects and copies it into an immutable
content-addressed snapshot. Reading that managed snapshot never depends on the
original URL remaining authorized.

macOS stores a read-only security-scoped bookmark. iOS/iPadOS stores a minimal
bookmark when Foundation permits it; bookmark resolution and
`startAccessingSecurityScopedResource` are best-effort. If refresh cannot regain
the original, the app asks the user to select the exact source again. Bookmark
failure affects refresh only and never invalidates an already committed copy.

On macOS, exclusive managed bytes move to the user Trash before the database
removal transaction. iOS has no public Trash API, so the app first moves those
bytes to a private temporary rollback area, commits metadata removal, then
deletes the staged copy. A failed metadata transaction restores the copy on
both platforms. The user-selected original is never modified.

## Native presentation bridges

PDFKit, controlled WebKit, and Quick Look exist on both native platforms but
use platform-specific representables. macOS uses `NSTextView`; iOS/iPadOS use
`UITextView`. Both surfaces share `NativeMarkdownRenderer` source mappings and
emit the same Snapshot-bound selection and position Locators. Web content uses
the same sanitizer, read-only scheme handler, no-source-script policy, and
explicit external-link handoff. Quick Look keeps its source-level capability
limit on every OS.

Platform branches must remain below the presentation and application-shell
boundary. A platform-specific adapter ID, Locator schema, graph, progress model,
Provider protocol, or Agent tool would violate the shared-product contract.

## Permissions and privacy

- macOS entitlements allow App Sandbox, outbound client network, and read-only
  access to user-selected files.
- iOS/iPadOS add no private entitlement. File access comes from the document
  picker; ordinary client networking follows the platform sandbox.
- The iOS plist explains local-network access used only for a user-configured
  local Provider such as Ollama and permits local endpoint transport without
  broadly allowing insecure internet traffic.
- Provider secrets remain in the device Keychain. Source bytes leave a device
  only after the existing endpoint-bound Provider disclosure.

## Build and validation

Run `scripts/generate-xcode-project.sh` after changing `project.yml`, then commit
the regenerated project and plists together. `scripts/check-xcode-project.sh`
recreates the project in a temporary same-named root and rejects drift.
`scripts/check-apple-platform-metadata.py` verifies platform declarations,
bundle/version metadata, and every icon slot.

`scripts/build-ios-simulator.sh` produces an unsigned universal iPhone/iPad
Simulator build with dependency versions constrained by `Package.resolved`.
The authoritative `scripts/validate-native.sh` additionally runs all shared
tests, a SwiftPM Release build, macOS Sandbox packaging, signature/entitlement
checks, documentation gates, and lock-digest checks. CI uses the same script;
real Provider credentials are never present.
