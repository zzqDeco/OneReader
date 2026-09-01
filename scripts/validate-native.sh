#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_digest_before="$(shasum -a 256 "$repo_root/Package.resolved" | awk '{print $1}')"

"$repo_root/scripts/bootstrap-dependencies.sh"
swift package --package-path "$repo_root" resolve
lock_digest_after_resolve="$(shasum -a 256 "$repo_root/Package.resolved" | awk '{print $1}')"
[[ "$lock_digest_before" == "$lock_digest_after_resolve" ]]
python3 "$repo_root/scripts/check-dependency-lock.py"
python3 "$repo_root/scripts/check-doc-index.py"
git -C "$repo_root" diff --check
swift test --package-path "$repo_root"
swift build --package-path "$repo_root" --configuration release
lock_digest_after_build="$(shasum -a 256 "$repo_root/Package.resolved" | awk '{print $1}')"
[[ "$lock_digest_before" == "$lock_digest_after_build" ]]
"$repo_root/scripts/package-app.sh"
lock_digest_after_package="$(shasum -a 256 "$repo_root/Package.resolved" | awk '{print $1}')"
[[ "$lock_digest_before" == "$lock_digest_after_package" ]]
codesign --verify --deep --strict --verbose=2 "$repo_root/dist/OneReader.app"
codesign -d --entitlements :- "$repo_root/dist/OneReader.app" 2>&1 \
  | grep -q 'com.apple.security.app-sandbox'

echo "Native validation passed."
