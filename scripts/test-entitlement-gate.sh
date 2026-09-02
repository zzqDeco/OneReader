#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/OneReaderEntitlementGate.XXXXXX")"
trap 'find "$fixture" -depth -delete 2>/dev/null || true' EXIT
good="$fixture/good.plist"
missing="$fixture/missing.plist"
write="$fixture/write.plist"
cp "$repo_root/Resources/OneReader.entitlements" "$good"
cp "$good" "$missing"
cp "$good" "$write"

"$repo_root/scripts/check-app-entitlements.sh" --plist "$good" >/dev/null
/usr/libexec/PlistBuddy \
  -c 'Delete :com.apple.security.app-sandbox' "$missing"
if "$repo_root/scripts/check-app-entitlements.sh" --plist "$missing" \
  >/dev/null 2>&1; then
  echo "Missing Sandbox entitlement must fail validation." >&2
  exit 1
fi
/usr/libexec/PlistBuddy \
  -c 'Add :com.apple.security.files.user-selected.read-write bool true' "$write"
if "$repo_root/scripts/check-app-entitlements.sh" --plist "$write" \
  >/dev/null 2>&1; then
  echo "User-selected write access must fail validation." >&2
  exit 1
fi

echo "Entitlement gate tests passed."
