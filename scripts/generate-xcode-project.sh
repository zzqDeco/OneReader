#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v xcodegen >/dev/null
xcodegen generate --spec "$repo_root/project.yml" --project "$repo_root"

echo "Generated $repo_root/OneReader.xcodeproj"
