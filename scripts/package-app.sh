#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${CONFIGURATION:-release}"
dist_dir="$repo_root/dist"
final_app_dir="$dist_dir/OneReader.app"
mkdir -p "$dist_dir"
package_dir="$(mktemp -d "$dist_dir/.package.XXXXXX")"
trap 'rm -rf "$package_dir"' EXIT
app_dir="$package_dir/OneReader.app"
contents_dir="$app_dir/Contents"
binary_dir="$contents_dir/MacOS"
resource_dir="$contents_dir/Resources"
entitlements="$repo_root/Resources/OneReader.entitlements"

"$repo_root/scripts/bootstrap-dependencies.sh"

swift build \
  --package-path "$repo_root" \
  --configuration "$configuration" \
  --product OneReaderApp

binary_path="$(swift build \
  --package-path "$repo_root" \
  --configuration "$configuration" \
  --show-bin-path)/OneReaderApp"

mkdir -p "$binary_dir" "$resource_dir"
cp "$binary_path" "$binary_dir/OneReader"
cp "$repo_root/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$repo_root/Resources/AppIcon.icns" "$resource_dir/AppIcon.icns"
cp "$repo_root/LICENSE" "$resource_dir/LICENSE"
cp "$repo_root/THIRD_PARTY_NOTICES.md" "$resource_dir/THIRD_PARTY_NOTICES.md"
license_dir="$resource_dir/Licenses"
mkdir -p "$license_dir"

license_sources=(
  "GRDB.swift:.build/checkouts/GRDB.swift/LICENSE"
  "JSONSchema:.build/checkouts/JSONSchema/LICENSE.md"
  "OpenFoundationModels:.build/checkouts/OpenFoundationModels/LICENSE"
  "SwiftSoup:.build/checkouts/SwiftSoup/LICENSE"
  "ZIPFoundation:.build/checkouts/ZIPFoundation/LICENSE"
  "eventsource:.build/checkouts/eventsource/LICENSE.md"
  "swift-actor-runtime:.build/checkouts/swift-actor-runtime/LICENSE"
  "swift-atomics:.build/checkouts/swift-atomics/LICENSE.txt"
  "swift-cmark:.build/checkouts/swift-cmark/COPYING"
  "swift-collections:.build/checkouts/swift-collections/LICENSE.txt"
  "swift-configuration:.build/checkouts/swift-configuration/LICENSE.txt"
  "swift-configuration-NOTICE:.build/checkouts/swift-configuration/NOTICE.txt"
  "swift-distributed-tracing:.build/checkouts/swift-distributed-tracing/LICENSE.txt"
  "swift-log:.build/checkouts/swift-log/LICENSE.txt"
  "swift-log-NOTICE:.build/checkouts/swift-log/NOTICE.txt"
  "swift-markdown:.build/checkouts/swift-markdown/LICENSE.txt"
  "swift-markdown-NOTICE:.build/checkouts/swift-markdown/NOTICE.txt"
  "swift-metrics:.build/checkouts/swift-metrics/LICENSE.txt"
  "swift-metrics-NOTICE:.build/checkouts/swift-metrics/NOTICE.txt"
  "swift-nio:.build/checkouts/swift-nio/LICENSE.txt"
  "swift-nio-NOTICE:.build/checkouts/swift-nio/NOTICE.txt"
  "swift-sdk:.build/checkouts/swift-sdk/LICENSE"
  "swift-service-context:.build/checkouts/swift-service-context/LICENSE.txt"
  "swift-service-context-NOTICE:.build/checkouts/swift-service-context/NOTICE.txt"
  "swift-service-lifecycle:.build/checkouts/swift-service-lifecycle/LICENSE.txt"
  "swift-service-lifecycle-NOTICE:.build/checkouts/swift-service-lifecycle/NOTICE.txt"
  "swift-syntax:.build/checkouts/swift-syntax/LICENSE.txt"
  "swift-system:.build/checkouts/swift-system/LICENSE.txt"
  "swift-yaml:.build/checkouts/swift-yaml/LICENSE"
)

for entry in "${license_sources[@]}"; do
  name="${entry%%:*}"
  relative_path="${entry#*:}"
  source_path="$repo_root/$relative_path"
  test -f "$source_path"
  cp "$source_path" "$license_dir/$name.txt"
done
chmod +x "$binary_dir/OneReader"

plutil -lint "$contents_dir/Info.plist"
plutil -lint "$entitlements"
test -x "$binary_dir/OneReader"
test -f "$resource_dir/LICENSE"
test -f "$resource_dir/THIRD_PARTY_NOTICES.md"
test -n "$(find "$license_dir" -type f -print -quit)"
codesign --force --sign - --entitlements "$entitlements" "$app_dir"
codesign --verify --deep --strict "$app_dir"

rm -rf "$final_app_dir"
mv "$app_dir" "$final_app_dir"
echo "Packaged $final_app_dir"
