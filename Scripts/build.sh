#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
node Scripts/build-web-editor.mjs
xcodegen generate
xcodebuild -project Bandal.xcodeproj -scheme Bandal \
  -destination "${BANDAL_DESTINATION:-generic/platform=iOS Simulator}" \
  -derivedDataPath .derivedData -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO build
