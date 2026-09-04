#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${ONEREADER_IOS_DEVICE_ID:?Set ONEREADER_IOS_DEVICE_ID to a connected physical iPhone UDID}"
: "${ONEREADER_DEVELOPMENT_TEAM:?Set ONEREADER_DEVELOPMENT_TEAM to the Apple development team ID}"

device_listing="$(xcrun devicectl list devices --columns Identifier Reality Platform State)"
device_line="$(printf '%s\n' "$device_listing" | grep -F "$ONEREADER_IOS_DEVICE_ID" || true)"
if [[ -z "$device_line" ]] || [[ "$device_line" != *"physical"* ]] || [[ "$device_line" != *"iOS"* ]]; then
  echo "Refusing to run: $ONEREADER_IOS_DEVICE_ID is not an available physical iOS device." >&2
  exit 1
fi

xcodebuild \
  -project "$repo_root/OneReader.xcodeproj" \
  -scheme OneReader-iOS \
  -configuration Debug \
  -destination "platform=iOS,id=$ONEREADER_IOS_DEVICE_ID" \
  -only-testing:OneReader-iOSLayoutTests \
  -skipMacroValidation \
  -onlyUsePackageVersionsFromResolvedFile \
  DEVELOPMENT_TEAM="$ONEREADER_DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  test
