#!/usr/bin/env bash
set -euo pipefail

repo_root="${RELEASE_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
tag="${RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
remote_main_ref="${REMOTE_MAIN_REF:-refs/remotes/origin/main}"

if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Release tag must match vX.Y.Z." >&2
  exit 1
fi
if [[ "$(git -C "$repo_root" cat-file -t "refs/tags/$tag" 2>/dev/null || true)" != "tag" ]]; then
  echo "Release tag must be annotated." >&2
  exit 1
fi

tag_commit="$(git -C "$repo_root" rev-list -n 1 "refs/tags/$tag")"
head_commit="$(git -C "$repo_root" rev-parse HEAD)"
main_commit="$(git -C "$repo_root" rev-parse "$remote_main_ref")"
if [[ "$tag_commit" != "$head_commit" || "$tag_commit" != "$main_commit" ]]; then
  echo "Release tag, checkout, and origin/main tip must be the same commit." >&2
  exit 1
fi

version="${tag#v}"
actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repo_root/Resources/Info.plist")"
if [[ "$actual" != "$version" ]]; then
  echo "Info.plist version $actual does not match tag $tag." >&2
  exit 1
fi

echo "Release ref validation passed for $tag at $tag_commit."
