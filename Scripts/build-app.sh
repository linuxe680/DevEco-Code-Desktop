#!/bin/zsh
set -euo pipefail

# 构建指定架构/最低系统的 .app。macOS 11 目标必须以 macOS 12 SDK 编译
# （本机 Xcode 27 仅支持 >= 12.0），产物仍可在 macOS 11 上运行。
ROOT="${0:A:h:h}"
ARCH="${1:-$(uname -m)}"
MIN_MACOS="${2:-12.0}"
case "$ARCH" in
    arm64) TRIPLE="arm64-apple-macosx$MIN_MACOS" ;;
    x86_64|intel) ARCH="x86_64"; TRIPLE="x86_64-apple-macosx$MIN_MACOS" ;;
    *) echo "usage: build-app.sh [arm64|x86_64] [min-macos] (got: $ARCH)" >&2; exit 1 ;;
esac

swift build --disable-sandbox -c release --triple "$TRIPLE" --package-path "$ROOT"

BIN="$(swift build -c release --triple "$TRIPLE" --package-path "$ROOT" --show-bin-path)/DevEcoCodeDesktop"
# 产物统一放在 build/：仓库根目录不再出现 .app，避免 Spotlight/Launchpad
# 把构建产物当成第二份已安装应用收录。
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/DevEco Code Desktop ($ARCH).app"

mkdir -p "$BUILD_DIR"
# 告诉 Spotlight 不要索引构建目录（否则 build/ 里的 .app 仍会出现在搜索结果里）。
touch "$BUILD_DIR/.metadata_never_index"

# 清掉旧版脚本遗留在仓库根目录的 .app（gitignore 已忽略，但会污染启动台）。
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
for legacy in "$ROOT"/DevEco\ Code\ Desktop*.app(N); do
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$legacy" >/dev/null 2>&1 || true
    rm -rf "$legacy"
done

SIGN_ID="DevEco Code Desktop Dev"
SIGN_DIR="$HOME/Library/Application Support/DevEcoCodeDesktop/signing"
SIGN_KEYCHAIN="$SIGN_DIR/dev-signing.keychain-db"
SIGN_KEYCHAIN_PASS="deveco-code-desktop-dev-signing"

ensure_signing_identity() {
    mkdir -p "$SIGN_DIR"
    if [ ! -f "$SIGN_KEYCHAIN" ]; then
        security create-keychain -p "$SIGN_KEYCHAIN_PASS" "$SIGN_KEYCHAIN" >/dev/null
        security set-keychain-settings -lut 21600 "$SIGN_KEYCHAIN"
        local work
        work="$(mktemp -d "${TMPDIR:-/tmp}/deveco-sign.XXXXXX")"
        openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
            -keyout "$work/key.pem" -out "$work/cert.pem" \
            -subj "/CN=$SIGN_ID/O=Local Development/C=CN" \
            -addext "basicConstraints=critical,CA:false" \
            -addext "keyUsage=critical,digitalSignature" \
            -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
        openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" \
            -out "$work/identity.p12" -passout pass:deveco -name "$SIGN_ID" >/dev/null 2>&1
        security import "$work/identity.p12" -k "$SIGN_KEYCHAIN" -P deveco \
            -T /usr/bin/codesign -T /usr/bin/security >/dev/null
        security set-key-partition-list -S apple-tool:,apple:,codesign: \
            -s -k "$SIGN_KEYCHAIN_PASS" "$SIGN_KEYCHAIN" >/dev/null 2>&1
        rm -rf "$work"
    fi
    security unlock-keychain -p "$SIGN_KEYCHAIN_PASS" "$SIGN_KEYCHAIN" >/dev/null 2>&1
    security find-certificate -c "$SIGN_ID" "$SIGN_KEYCHAIN" >/dev/null 2>&1
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DevEcoCodeDesktop"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :DevEcoBuildTime string $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :DevEcoBuildTime $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APP/Contents/Info.plist"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
/usr/libexec/PlistBuddy -c "Add :DevEcoGitCommit string $COMMIT" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :DevEcoGitCommit $COMMIT" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/Resources/zh-Hans.lproj" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/en.lproj" "$APP/Contents/Resources/"

if ensure_signing_identity; then
    codesign --force --sign "$SIGN_ID" --keychain "$SIGN_KEYCHAIN" "$APP"
else
    echo "warning: persistent signing identity unavailable; falling back to ad-hoc" >&2
    codesign --force --sign - "$APP"
fi

# 构建目录里的 .app 只是打包中间产物，不应出现在聚焦/启动台。LaunchServices
# 会按 bundle id 收录它，必须在构建后立即注销；安装脚本会把正式副本重新登记。
[ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
