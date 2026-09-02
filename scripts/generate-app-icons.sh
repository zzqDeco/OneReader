#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
master="$repo_root/Design/AppIcon/OneReader-AppIcon-1024.png"
catalog="$repo_root/Resources/Assets.xcassets/AppIcon.appiconset"

test -f "$master"
mkdir -p "$catalog"

render() {
  local pixels="$1"
  local filename="$2"
  sips -z "$pixels" "$pixels" "$master" --out "$catalog/$filename" >/dev/null
}

render 16 AppIcon-mac-16.png
render 32 AppIcon-mac-16@2x.png
render 32 AppIcon-mac-32.png
render 64 AppIcon-mac-32@2x.png
render 128 AppIcon-mac-128.png
render 256 AppIcon-mac-128@2x.png
render 256 AppIcon-mac-256.png
render 512 AppIcon-mac-256@2x.png
render 512 AppIcon-mac-512.png
render 1024 AppIcon-mac-512@2x.png

render 40 AppIcon-iphone-20@2x.png
render 60 AppIcon-iphone-20@3x.png
render 58 AppIcon-iphone-29@2x.png
render 87 AppIcon-iphone-29@3x.png
render 80 AppIcon-iphone-40@2x.png
render 120 AppIcon-iphone-40@3x.png
render 120 AppIcon-iphone-60@2x.png
render 180 AppIcon-iphone-60@3x.png

render 20 AppIcon-ipad-20.png
render 40 AppIcon-ipad-20@2x.png
render 29 AppIcon-ipad-29.png
render 58 AppIcon-ipad-29@2x.png
render 40 AppIcon-ipad-40.png
render 80 AppIcon-ipad-40@2x.png
render 76 AppIcon-ipad-76.png
render 152 AppIcon-ipad-76@2x.png
render 167 AppIcon-ipad-83.5@2x.png
render 1024 AppIcon-marketing-1024.png

iconset_root="$(mktemp -d)"
trap 'rm -rf "$iconset_root"' EXIT
iconset="$iconset_root/OneReader.iconset"
mkdir -p "$iconset"
sips -z 16 16 "$master" --out "$iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$master" --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$master" --out "$iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$master" --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$master" --out "$iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$master" --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$master" --out "$iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$master" --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$master" --out "$iconset/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$master" --out "$iconset/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$iconset" --output "$repo_root/Resources/AppIcon.icns"

echo "Generated OneReader AppIcon assets."
