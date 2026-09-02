# `project.yml`

Owns generated native target metadata: macOS and universal iPhone/iPad
application targets, deployment versions, local package-product linkage,
document declarations, platform plists, entitlements, app-icon catalog, bundle
version, and shared schemes. `OneReader.xcodeproj` is derived output and must be
regenerated with `scripts/generate-xcode-project.sh` after this file changes.

The project intentionally excludes Catalyst and does not copy shared Swift
sources into app targets. Both applications depend on the local `OneReader`
package product so compile-time platform checks exercise the same module.
