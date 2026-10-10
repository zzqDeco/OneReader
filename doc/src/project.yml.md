# `project.yml`

Owns generated native target metadata: macOS and universal iPhone/iPad
application targets, deployment versions, local package-product linkage,
document declarations, platform plists, entitlements, app-icon catalog, bundle
version, and shared schemes. `OneReader.xcodeproj` is derived output and must be
regenerated with `scripts/generate-xcode-project.sh` after this file changes.

The project intentionally excludes Catalyst and does not copy shared Swift
sources into app targets. Both applications depend on the local `OneReader`
package product so compile-time platform checks exercise the same module.

iOS bundle identity and display name have dedicated build variables whose
defaults remain `io.github.zzqDeco.OneReader` and `OneReader`. Physical import/zoom
acceptance overrides only those variables, producing an independently signed
`OneReader Fix Preview` without installing over the production application or
opening its Library. The iOS plist resolves `PRODUCT_BUNDLE_IDENTIFIER` and
enables Files access to Documents, not private Application Support storage.

The iOS plist explicitly enables `CADisableMinimumFrameDurationOnPhone` for
ProMotion frame rates. Native UIKit/SwiftUI/PDFKit retain adaptive frame pacing;
the app does not install a permanent display link or force a fixed 120 Hz rate.
Metadata checks and an on-device host-plist regression prevent this opt-in from
being dropped during project generation or packaging.
