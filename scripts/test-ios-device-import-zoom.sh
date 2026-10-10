#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${ONEREADER_IOS_DEVICE_ID:?Set the connected physical iPhone UDID}"
: "${ONEREADER_DEVELOPMENT_TEAM:?Set the Apple development team ID}"

device_listing="$(xcrun devicectl list devices --columns Identifier Reality Platform State)"
device_line="$(printf '%s\n' "$device_listing" | rg -F "$ONEREADER_IOS_DEVICE_ID" || true)"
if [[ "$device_line" != *"physical"* || "$device_line" != *"iOS"* || "$device_line" != *"available"* || "$device_line" == *"unavailable"* ]]; then
  echo "A connected physical iPhone is required." >&2
  exit 1
fi

result_dir="${ONEREADER_IOS_TEST_RESULT_DIR:-$repo_root/.onereader/acceptance/ios-import-pdf-zoom/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$result_dir"

test_selection=(-only-testing:OneReader-iOSLayoutTests)
if [[ "${ONEREADER_IOS_TEST_ALL:-0}" == "1" ]]; then
  test_selection+=(-only-testing:OneReader-iOSUITests)
else
  test_selection+=(-only-testing:OneReader-iOSUITests/FileImportAndPDFZoomUITests)
fi

xcodebuild \
  -project "$repo_root/OneReader.xcodeproj" \
  -scheme OneReader-iOS -configuration Debug \
  -destination "platform=iOS,id=$ONEREADER_IOS_DEVICE_ID" \
  -derivedDataPath "$repo_root/.onereader/DerivedData-iOS-scroll-fix" \
  -resultBundlePath "$result_dir/device-tests.xcresult" \
  "${test_selection[@]}" \
  -skipMacroValidation -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$ONEREADER_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
  ONEREADER_IOS_BUNDLE_IDENTIFIER=io.github.zzqDeco.OneReader.ImportZoomAcceptance \
  'ONEREADER_IOS_DISPLAY_NAME=OneReader Fix Preview' \
  test 2>&1 | tee "$result_dir/device-tests.log"
