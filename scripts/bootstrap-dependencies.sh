#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$repo_root/Vendor/swift-peer-connectivity"
original_url="https://github.com/1amageek/swift-peer-connectivity.git"
expected_revision="447dfb9f6587a5f38ade79e1e5d3096c02c2717c"

isolated_git() {
  env \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_GLOBAL=/dev/null \
    git \
      -c commit.gpgSign=false \
      -c tag.gpgSign=false \
      -c core.hooksPath=/dev/null \
      -c core.attributesFile=/dev/null \
      -c core.autocrlf=false \
      "$@"
}

source_digest="$(
  cd "$source_dir"
  {
    find . -type f -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 shasum -a 256
  } | shasum -a 256 | awk '{print $1}'
)"
mirror_dir="$repo_root/.swiftpm/local-mirrors/swift-peer-connectivity-$source_digest"

if [[ ! -d "$mirror_dir/.git" ]]; then
  mkdir -p "$mirror_dir"
  cp -R "$source_dir/." "$mirror_dir/"
  isolated_git -C "$mirror_dir" init --quiet
  isolated_git -C "$mirror_dir" config --local user.name "OneReader Dependency Bootstrap"
  isolated_git -C "$mirror_dir" config --local user.email "noreply@onereader.local"
  isolated_git -C "$mirror_dir" add .
  GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" \
    GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
    isolated_git -C "$mirror_dir" commit --quiet --no-gpg-sign \
      -m "Provide unused PeerConnectivity product"
  isolated_git -C "$mirror_dir" tag --no-sign 0.2.5
fi

actual_revision="$(isolated_git -C "$mirror_dir" rev-parse HEAD)"
tag_revision="$(isolated_git -C "$mirror_dir" rev-parse 'refs/tags/0.2.5^{commit}')"
if [[ "$actual_revision" != "$expected_revision" || "$tag_revision" != "$expected_revision" ]]; then
  echo "Generated dependency mirror does not match the pinned revision." >&2
  exit 1
fi
if [[ -n "$(isolated_git -C "$mirror_dir" status --porcelain --untracked-files=all)" ]]; then
  echo "Generated dependency mirror has unexpected working-tree changes." >&2
  exit 1
fi

swift package --package-path "$repo_root" config unset-mirror \
  --original "$original_url" >/dev/null 2>&1 || true
swift package --package-path "$repo_root" config set-mirror \
  --original "$original_url" \
  --mirror "$mirror_dir"

echo "Configured SwiftPM mirror for unused swift-peer-connectivity dependency."
