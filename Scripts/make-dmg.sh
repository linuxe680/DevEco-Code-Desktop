#!/bin/zsh
set -euo pipefail

# 构建 arm64 + Intel 两个 DMG 安装包。本机 Xcode 无法把部署目标设为 11，
# 使用 12.0 SDK 构建但 Info.plist 声明 LSMinimumSystemVersion=11.0。
ROOT="${0:A:h:h}"
MIN_MACOS="${1:-12.0}"
BUILD_DIR="$ROOT/build"
mkdir -p "$BUILD_DIR"

"$ROOT/Scripts/build-app.sh" arm64 "$MIN_MACOS"
"$ROOT/Scripts/build-app.sh" x86_64 "$MIN_MACOS"

VERSION=$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")
DMGS=()
for ARCH in arm64 x86_64; do
    APP="$ROOT/DevEco Code Desktop ($ARCH).app"
    DMG="$BUILD_DIR/DevEco Code Desktop-$VERSION-$ARCH.dmg"
    STAGING=$(mktemp -d)
    trap 'rm -rf "$STAGING"' EXIT
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "DevEco Code Desktop ($ARCH)" \
      -srcfolder "$STAGING" -ov -format UDZO "$DMG"
    hdiutil verify "$DMG" >/dev/null
    codesign --verify --deep --strict "$APP"
    shasum -a 256 "$DMG" > "$DMG.sha256"
    DMGS+=("$DMG")
    rm -rf "$STAGING"
done

echo "Built installers:"
printf '  %s\n' "${DMGS[@]}"
