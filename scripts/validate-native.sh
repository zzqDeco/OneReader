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
plutil -lint "$repo_root/Resources/ReleaseMetadata.plist" >/dev/null
"$repo_root/scripts/test-release-gates.sh"
"$repo_root/scripts/test-entitlement-gate.sh"
if [[ "${GITHUB_EVENT_NAME:-}" == "pull_request" && -n "${GITHUB_BASE_REF:-}" ]]; then
  git -C "$repo_root" diff --check "origin/${GITHUB_BASE_REF}...HEAD"
elif [[ -n "${CI:-}" ]]; then
  git -C "$repo_root" diff-tree --check --no-commit-id -r HEAD
else
  git -C "$repo_root" diff --check
  git -C "$repo_root" diff --cached --check
fi
swift test --package-path "$repo_root"
swift build --package-path "$repo_root" --configuration release
lock_digest_after_build="$(shasum -a 256 "$repo_root/Package.resolved" | awk '{print $1}')"
[[ "$lock_digest_before" == "$lock_digest_after_build" ]]
"$repo_root/scripts/package-app.sh"
lock_digest_after_package="$(shasum -a 256 "$repo_root/Package.resolved" | awk '{print $1}')"
[[ "$lock_digest_before" == "$lock_digest_after_package" ]]
codesign --verify --deep --strict --verbose=2 "$repo_root/dist/OneReader.app"
"$repo_root/scripts/check-app-entitlements.sh" "$repo_root/dist/OneReader.app"

echo "Native validation passed."
