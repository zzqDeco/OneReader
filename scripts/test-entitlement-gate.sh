#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/OneReaderEntitlementGate.XXXXXX")"
trap 'find "$fixture" -depth -delete 2>/dev/null || true' EXIT
good="$fixture/good.plist"
missing="$fixture/missing.plist"
broad="$fixture/broad.plist"
read_only="$fixture/read-only.plist"
cp "$repo_root/Resources/OneReader.entitlements" "$good"
cp "$good" "$missing"
cp "$good" "$broad"
cp "$good" "$read_only"

"$repo_root/scripts/check-app-entitlements.sh" --plist "$good" >/dev/null
/usr/libexec/PlistBuddy \
  -c 'Delete :com.apple.security.app-sandbox' "$missing"
if "$repo_root/scripts/check-app-entitlements.sh" --plist "$missing" \
  >/dev/null 2>&1; then
  echo "Missing Sandbox entitlement must fail validation." >&2
  exit 1
fi
/usr/libexec/PlistBuddy \
  -c 'Add :com.apple.security.temporary-exception.files.absolute-path.read-write array' "$broad"
if "$repo_root/scripts/check-app-entitlements.sh" --plist "$broad" \
  >/dev/null 2>&1; then
  echo "Broad absolute-path write access must fail validation." >&2
  exit 1
fi
/usr/libexec/PlistBuddy \
  -c 'Delete :com.apple.security.files.user-selected.read-write' "$read_only"
/usr/libexec/PlistBuddy \
  -c 'Add :com.apple.security.files.user-selected.read-only bool true' "$read_only"
if "$repo_root/scripts/check-app-entitlements.sh" --plist "$read_only" \
  >/dev/null 2>&1; then
  echo "Read-only access cannot satisfy explicit note export." >&2
  exit 1
fi

echo "Entitlement gate tests passed."
