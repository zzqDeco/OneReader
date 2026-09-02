#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$repo_root/dist"
app_dir="$dist_dir/OneReader.app"
info_plist="$repo_root/Resources/Info.plist"
release_metadata="$repo_root/Resources/ReleaseMetadata.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
tag="${RELEASE_TAG:-v$version}"
commit="$(git -C "$repo_root" rev-parse HEAD)"
base_name="OneReader-v${version}-macos-developer-preview"
zip_name="$base_name.zip"
dmg_name="$base_name.dmg"
manifest_name="release-manifest.json"
zip_path="$dist_dir/$zip_name"
dmg_path="$dist_dir/$dmg_name"
manifest_path="$dist_dir/$manifest_name"
dmg_staging="$(mktemp -d "$dist_dir/.dmg.XXXXXX")"
manifest_plist="$(mktemp "$dist_dir/.manifest.XXXXXX.plist")"
trap 'find "$dmg_staging" "$manifest_plist" -depth -delete 2>/dev/null || true' EXIT

test -d "$app_dir"
codesign --verify --deep --strict "$app_dir"
plutil -lint "$release_metadata" >/dev/null
find "$zip_path" "$dmg_path" "$manifest_path" \
  "$zip_path.sha256" "$dmg_path.sha256" "$manifest_path.sha256" \
  -maxdepth 0 -type f -delete 2>/dev/null || true

ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$zip_path"
ditto "$app_dir" "$dmg_staging/OneReader.app"
diskutil image create from \
  --volumeName "OneReader $version Developer Preview" \
  --format UDZO \
  "$dmg_staging" \
  "$dmg_path" >/dev/null

zip_digest="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
dmg_digest="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
lock_digest="$(shasum -a 256 "$repo_root/Package.resolved" | awk '{print $1}')"
license_digest="$(shasum -a 256 "$repo_root/LICENSE" | awk '{print $1}')"
notices_digest="$(shasum -a 256 "$repo_root/THIRD_PARTY_NOTICES.md" | awk '{print $1}')"
swift_version="$(swift --version 2>/dev/null | head -n 1)"
xcode_version="$(xcodebuild -version | paste -sd ';' -)"
manifest_schema="$(/usr/libexec/PlistBuddy -c 'Print :ManifestSchemaVersion' "$release_metadata")"
database_schema="$(/usr/libexec/PlistBuddy -c 'Print :DatabaseSchemaVersion' "$release_metadata")"
adapter_schema="$(/usr/libexec/PlistBuddy -c 'Print :AdapterSchemaVersion' "$release_metadata")"
agent_schema="$(/usr/libexec/PlistBuddy -c 'Print :AgentRuntimeSchemaVersion' "$release_metadata")"

plutil -create xml1 "$manifest_plist"
plutil -insert manifestSchemaVersion -integer "$manifest_schema" "$manifest_plist"
plutil -insert tag -string "$tag" "$manifest_plist"
plutil -insert commit -string "$commit" "$manifest_plist"
plutil -insert version -string "$version" "$manifest_plist"
plutil -insert swift -string "$swift_version" "$manifest_plist"
plutil -insert xcode -string "$xcode_version" "$manifest_plist"
plutil -insert dependencyLockSHA256 -string "$lock_digest" "$manifest_plist"
plutil -insert license -string "Apache-2.0" "$manifest_plist"
plutil -insert licenseSHA256 -string "$license_digest" "$manifest_plist"
plutil -insert thirdPartyNoticesSHA256 -string "$notices_digest" "$manifest_plist"
plutil -insert databaseSchemaVersion -integer "$database_schema" "$manifest_plist"
plutil -insert adapterSchemaVersion -integer "$adapter_schema" "$manifest_plist"
plutil -insert agentRuntimeSchemaVersion -integer "$agent_schema" "$manifest_plist"
plutil -insert signing -string "ad-hoc" "$manifest_plist"
plutil -insert sandboxed -bool true "$manifest_plist"
plutil -insert notarized -bool false "$manifest_plist"
plutil -insert artifacts -dictionary "$manifest_plist"
plutil -insert artifacts.zip -dictionary "$manifest_plist"
plutil -insert artifacts.zip.filename -string "$zip_name" "$manifest_plist"
plutil -insert artifacts.zip.sha256 -string "$zip_digest" "$manifest_plist"
plutil -insert artifacts.dmg -dictionary "$manifest_plist"
plutil -insert artifacts.dmg.filename -string "$dmg_name" "$manifest_plist"
plutil -insert artifacts.dmg.sha256 -string "$dmg_digest" "$manifest_plist"
plutil -convert json -o "$manifest_path" "$manifest_plist"

(
  cd "$dist_dir"
  shasum -a 256 "$zip_name" >"$zip_name.sha256"
  shasum -a 256 "$dmg_name" >"$dmg_name.sha256"
  shasum -a 256 "$manifest_name" >"$manifest_name.sha256"
)

echo "Packaged release artifacts in $dist_dir."
