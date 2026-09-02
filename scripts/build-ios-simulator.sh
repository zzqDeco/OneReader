#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${CONFIGURATION:-Debug}"
destination="${ONEREADER_IOS_DESTINATION:-generic/platform=iOS Simulator}"
derived_data="${ONEREADER_IOS_DERIVED_DATA_PATH:-$repo_root/.onereader/DerivedData-iOS}"

"$repo_root/scripts/bootstrap-dependencies.sh"
"$repo_root/scripts/check-xcode-project.sh"
python3 "$repo_root/scripts/check-apple-platform-metadata.py"

xcodebuild \
  -project "$repo_root/OneReader.xcodeproj" \
  -scheme OneReader-iOS \
  -configuration "$configuration" \
  -destination "$destination" \
  -derivedDataPath "$derived_data" \
  -skipMacroValidation \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  build

echo "Universal iPhone/iPad Simulator build passed."
