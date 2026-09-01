#!/usr/bin/env bash
set -euo pipefail

mode="app"
if [[ "${1:-}" == "--plist" ]]; then
  mode="plist"
  shift
fi
input="${1:?usage: check-app-entitlements.sh [--plist] <app-or-plist>}"
temporary=""
if [[ "$mode" == "app" ]]; then
  temporary="$(mktemp "${TMPDIR:-/tmp}/OneReaderEntitlements.XXXXXX")"
  trap 'find "$temporary" -delete 2>/dev/null || true' EXIT
  codesign -d --entitlements :- "$input" >"$temporary" 2>/dev/null
  plist="$temporary"
else
  plist="$input"
fi

plutil -lint "$plist" >/dev/null
assert_true() {
  local key="$1"
  local value
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
  if [[ "$value" != "true" ]]; then
    echo "Required entitlement is missing or false: $key" >&2
    exit 1
  fi
}

assert_true "com.apple.security.app-sandbox"
assert_true "com.apple.security.network.client"
assert_true "com.apple.security.files.user-selected.read-only"
if /usr/libexec/PlistBuddy \
  -c 'Print :com.apple.security.files.user-selected.read-write' \
  "$plist" >/dev/null 2>&1; then
  echo "Packaged app unexpectedly has user-selected write access." >&2
  exit 1
fi

echo "Sandbox entitlement validation passed."
