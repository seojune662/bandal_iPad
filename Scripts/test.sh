#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${BANDAL_DESTINATION:?Set BANDAL_DESTINATION to an available iPad simulator, e.g. platform=iOS Simulator,id=SIMULATOR_UUID}"
swift test --package-path Packages/BandalCore
# This Python service is deployed separately; it is not part of the app runtime.
python3 -m unittest discover -s backend/ppt-converter -p 'test_*.py' -v
xcodegen generate
# Use every test target in the generated Bandal scheme, including native UI flows.
xcodebuild -project Bandal.xcodeproj -scheme Bandal -destination "$BANDAL_DESTINATION" \
  -derivedDataPath .derivedData -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  test "$@"
