#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
  echo "usage: $0 <tool-cache-directory>" >&2
  exit 64
fi

tool_cache_directory="$1"
version="2.45.3"
expected_sha256="0c90f4d28ca57335f9fa78cf5bf6dabfe20a232036dabe36de2eef79cb7c0878"
install_directory="$tool_cache_directory/xcodegen-$version"
binary="$install_directory/xcodegen/bin/xcodegen"

if [[ ! -x "$binary" ]]; then
  if [[ -e "$install_directory" ]]; then
    echo "refusing to replace incomplete XcodeGen cache: $install_directory" >&2
    exit 1
  fi

  mkdir -p "$tool_cache_directory"
  archive="$(mktemp "$tool_cache_directory/xcodegen-$version.XXXXXX.zip")"
  staging="$(mktemp -d "$tool_cache_directory/xcodegen-$version.XXXXXX")"
  trap 'find "$archive" "$staging" -depth -delete 2>/dev/null || true' EXIT

  curl --fail --silent --show-error --location \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip" \
    --output "$archive"

  actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "XcodeGen archive checksum mismatch: expected $expected_sha256, found $actual_sha256" >&2
    exit 1
  fi

  unzip -q "$archive" -d "$staging"
  mv "$staging" "$install_directory"
  trap 'find "$archive" -delete 2>/dev/null || true' EXIT
fi

actual_version="$($binary --version)"
if [[ "$actual_version" != "Version: $version" ]]; then
  echo "unexpected XcodeGen binary version: $actual_version" >&2
  exit 1
fi

printf '%s\n' "$(dirname "$binary")"
