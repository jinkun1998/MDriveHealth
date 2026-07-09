#!/bin/bash
# release.sh — builds, signs, notarizes and packages MDriveHealth.dmg.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in the login keychain.
#   2. Notarytool credentials stored:
#        xcrun notarytool store-credentials mdrivehealth \
#          --apple-id you@example.com --team-id TEAMID --password app-specific-pw
#
# Usage:
#   scripts/release.sh "Developer ID Application: Your Name (TEAMID)" [profile]
#
# This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
set -euo pipefail

IDENTITY="${1:?Usage: release.sh \"Developer ID Application: ...\" [notary-profile]}"
PROFILE="${2:-mdrivehealth}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/MDriveHealth.app"
VERSION=$(grep -m1 'CFBundleShortVersionString' "$ROOT/project.yml" | sed 's/[^0-9.]//g')
DMG="$DIST/MDriveHealth-$VERSION.dmg"

cd "$ROOT"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Generating project + running tests"
xcodegen generate
(cd Packages/MDriveHealthCore && swift test)

echo "==> Archiving Release build"
xcodebuild -project MDriveHealth.xcodeproj -scheme MDriveHealth \
  -configuration Release archive -archivePath "$DIST/MDriveHealth.xcarchive" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_HARDENED_RUNTIME=YES | tail -2

cp -R "$DIST/MDriveHealth.xcarchive/Products/Applications/MDriveHealth.app" "$APP"
codesign --verify --deep --strict "$APP"
echo "==> Signature OK"

echo "==> Notarizing (this can take a few minutes)"
ditto -c -k --keepParent "$APP" "$DIST/MDriveHealth.zip"
xcrun notarytool submit "$DIST/MDriveHealth.zip" \
  --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

echo "==> Building DMG"
STAGE="$DIST/dmg-stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MDriveHealth $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Gatekeeper check"
spctl -a -vv "$APP"
echo ""
echo "DONE: $DMG"
