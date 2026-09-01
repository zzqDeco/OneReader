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
  --product OneReader

binary_path="$(swift build \
  --package-path "$repo_root" \
  --configuration "$configuration" \
  --show-bin-path)/OneReader"

mkdir -p "$binary_dir" "$resource_dir"
cp "$binary_path" "$binary_dir/OneReader"
cp "$repo_root/Resources/Info.plist" "$contents_dir/Info.plist"
chmod +x "$binary_dir/OneReader"

plutil -lint "$contents_dir/Info.plist"
plutil -lint "$entitlements"
test -x "$binary_dir/OneReader"
codesign --force --sign - --entitlements "$entitlements" "$app_dir"
codesign --verify --deep --strict "$app_dir"

rm -rf "$final_app_dir"
mv "$app_dir" "$final_app_dir"
echo "Packaged $final_app_dir"
