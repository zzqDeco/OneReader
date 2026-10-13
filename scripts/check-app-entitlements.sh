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
assert_true "com.apple.security.files.user-selected.read-write"
# Notes export needs write access to a user-selected directory, never a blanket
# filesystem exception or automatic access to a user's media/download folders.
for key in \
  com.apple.security.temporary-exception.files.absolute-path.read-write \
  com.apple.security.temporary-exception.files.home-relative-path.read-write \
  com.apple.security.files.downloads.read-write \
  com.apple.security.assets.movies.read-write \
  com.apple.security.assets.music.read-write \
  com.apple.security.assets.pictures.read-write; do
  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    echo "Packaged app unexpectedly has broad write access: $key" >&2
    exit 1
  fi
done

echo "Sandbox entitlement validation passed."
