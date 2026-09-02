#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_parent="$(mktemp -d "${TMPDIR:-/tmp}/OneReaderXcodeGen.XXXXXX")"
temporary_root="$temporary_parent/OneReader"
mkdir -p "$temporary_root"
trap 'find "$temporary_parent" -depth -delete 2>/dev/null || true' EXIT

command -v xcodegen >/dev/null

cp "$repo_root/project.yml" "$temporary_root/project.yml"
cp "$repo_root/Package.swift" "$temporary_root/Package.swift"
cp "$repo_root/Package.resolved" "$temporary_root/Package.resolved"
cp -R "$repo_root/Apps" "$temporary_root/Apps"
cp -R "$repo_root/Resources" "$temporary_root/Resources"

xcodegen generate \
  --spec "$temporary_root/project.yml" \
  --project "$temporary_root" \
  --project-root "$temporary_root" \
  --quiet

cmp \
  "$repo_root/OneReader.xcodeproj/project.pbxproj" \
  "$temporary_root/OneReader.xcodeproj/project.pbxproj"
cmp \
  "$repo_root/OneReader.xcodeproj/project.xcworkspace/contents.xcworkspacedata" \
  "$temporary_root/OneReader.xcodeproj/project.xcworkspace/contents.xcworkspacedata"
diff -ru \
  "$repo_root/OneReader.xcodeproj/xcshareddata/xcschemes" \
  "$temporary_root/OneReader.xcodeproj/xcshareddata/xcschemes"
cmp "$repo_root/Resources/Info.plist" "$temporary_root/Resources/Info.plist"
cmp "$repo_root/Resources/Info-iOS.plist" "$temporary_root/Resources/Info-iOS.plist"

echo "Xcode project matches project.yml."
