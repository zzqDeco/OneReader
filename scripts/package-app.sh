#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${CONFIGURATION:-release}"
app_dir="$repo_root/dist/OneReader.app"
contents_dir="$app_dir/Contents"
binary_dir="$contents_dir/MacOS"
resource_dir="$contents_dir/Resources"

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
test -x "$binary_dir/OneReader"
echo "Packaged $app_dir"

