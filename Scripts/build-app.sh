#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
swift build --disable-sandbox -c release --package-path "$ROOT"

BIN="$ROOT/.build/release/DevEcoCodeDesktop"
APP="$ROOT/DevEco Code Desktop.app"

# Sign with a persistent self-signed development certificate. Ad-hoc signing
# produces a new CDHash on every build, which makes macOS treat each build as
# a different app and forget folder-access permissions (TCC) every time.
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
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Localized UI strings (SwiftUI literals look these up at runtime).
cp -R "$ROOT/Resources/en.lproj" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/zh-Hans.lproj" "$APP/Contents/Resources/"

# Signing keeps Launch Services from treating the bundle as damaged.
if ensure_signing_identity; then
    codesign --force --sign "$SIGN_ID" --keychain "$SIGN_KEYCHAIN" "$APP"
else
    echo "warning: persistent signing identity unavailable; falling back to ad-hoc" >&2
    codesign --force --sign - "$APP"
fi

echo "Built $APP"
