#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Packages/BandalCore
python3 -m unittest discover -s Tools/desktop-bridge -p 'test_bridge.py' -v
python3 -m unittest discover -s backend/ppt-converter -p 'test_*.py' -v
if [[ -n "${BANDAL_TEST_BRIDGE_BINARY:-}" ]]; then
  python3 -m unittest discover -s Tools/desktop-bridge -p 'test_binary.py' -v
fi
node Scripts/build-web-editor.mjs
node Scripts/build-web-editor.test.mjs
xcodegen generate
: "${BANDAL_DESTINATION:?Set BANDAL_DESTINATION to an available iPad simulator, e.g. platform=iOS Simulator,id=SIMULATOR_UUID}"
xcodebuild -project Bandal.xcodeproj -scheme Bandal -destination "$BANDAL_DESTINATION" \
  -derivedDataPath .derivedData -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO test
