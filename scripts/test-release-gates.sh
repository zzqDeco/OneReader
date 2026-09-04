#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/OneReaderReleaseGate.XXXXXX")"
trap 'find "$fixture" -depth -delete 2>/dev/null || true' EXIT

git -C "$fixture" init --quiet
git -C "$fixture" config user.name "OneReader Release Test"
git -C "$fixture" config user.email "noreply@onereader.local"
mkdir -p "$fixture/Resources"
cp "$repo_root/Resources/Info.plist" "$fixture/Resources/Info.plist"
git -C "$fixture" add Resources/Info.plist
git -C "$fixture" commit --quiet -m "fixture"
commit="$(git -C "$fixture" rev-parse HEAD)"
git -C "$fixture" update-ref refs/remotes/origin/main "$commit"
git -C "$fixture" tag -a v0.3.1 -m "fixture release"

RELEASE_REPO_ROOT="$fixture" \
  RELEASE_TAG="v0.3.1" \
  "$repo_root/scripts/validate-release-ref.sh" >/dev/null

git -C "$fixture" tag -d v0.3.1 >/dev/null
git -C "$fixture" tag v0.3.1
if RELEASE_REPO_ROOT="$fixture" RELEASE_TAG="v0.3.1" \
  "$repo_root/scripts/validate-release-ref.sh" >/dev/null 2>&1; then
  echo "Lightweight release tags must be rejected." >&2
  exit 1
fi

git -C "$fixture" tag -d v0.3.1 >/dev/null
git -C "$fixture" tag -a v0.3.1 -m "fixture release" "$commit"
git -C "$fixture" commit --quiet --allow-empty -m "new main tip"
git -C "$fixture" update-ref refs/remotes/origin/main HEAD
if RELEASE_REPO_ROOT="$fixture" RELEASE_TAG="v0.3.1" \
  "$repo_root/scripts/validate-release-ref.sh" >/dev/null 2>&1; then
  echo "A tag behind origin/main tip must be rejected." >&2
  exit 1
fi

echo "Release gate tests passed."
