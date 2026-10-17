#!/bin/bash
# Archive the current build number, upload it to App Store Connect, then bump
# project.yml so the next run uploads the next build. Needs ASC_KEY_ID and
# ASC_ISSUER_ID in the environment; the .p8 lives outside the repo.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[ -f "$KEY" ] || { echo "API key not found: $KEY" >&2; exit 1; }

build=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml)
version=$(sed -n 's/.*MARKETING_VERSION: "\([0-9.]*\)".*/\1/p' project.yml)
archive=".build/archives/Bandal-$version-$build.xcarchive"
auth=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

xcodegen generate -q
xcodebuild -project Bandal.xcodeproj -scheme Bandal -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  -derivedDataPath .build/DerivedData-release -clonedSourcePackagesDirPath .build/SourcePackages \
  "${auth[@]}" DEVELOPMENT_TEAM=VUZ7Z98BW3 CODE_SIGN_STYLE=Automatic archive
# Export signs manually with the profile from `fastlane profile`; the App Manager
# key cannot use Xcode cloud signing. The archive step still uses automatic signing.
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist Scripts/ExportOptions.plist \
  -exportPath ".build/export-$version-$build" -authenticationKeyPath "$KEY" \
  -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"

next=$((build + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$build\"/CURRENT_PROJECT_VERSION: \"$next\"/" project.yml
xcodegen generate -q
echo "Uploaded $version ($build). project.yml now at build $next; commit it."
