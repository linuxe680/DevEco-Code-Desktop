#!/bin/zsh
set -euo pipefail

# Builds the .app and packages it into a distributable DMG with a standard
# drag-to-Applications layout:  build/DevEco Code Desktop-<version>.dmg
ROOT="${0:A:h:h}"

"$ROOT/Scripts/build-app.sh"

VERSION=$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")
BUILD_DIR="$ROOT/build"
APP="$ROOT/DevEco Code Desktop.app"
DMG="$BUILD_DIR/DevEco Code Desktop-$VERSION.dmg"

mkdir -p "$BUILD_DIR"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "DevEco Code Desktop" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"

echo "Built $DMG"
