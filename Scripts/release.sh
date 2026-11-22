#!/bin/zsh
# One-command release: bump version → build → DMG → release notes → SHA-256
# → bundle verification. Produces everything P4 requires in build/.
#
# Usage:
#   Scripts/release.sh                 # bump patch (0.5.0 → 0.5.1)
#   Scripts/release.sh minor           # bump minor
#   Scripts/release.sh major           # bump major
#   Scripts/release.sh --version 1.0.0 # explicit version
#   RELEASE_NOTES="Fixed X, added Y" Scripts/release.sh   # custom release notes
set -euo pipefail

ROOT="${0:A:h:h}"
PLIST="$ROOT/Resources/Info.plist"
ROADMAP="$ROOT/ROADMAP.md"
MODE="${1:-patch}"

# --- 1. compute the next version -------------------------------------------
version=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
build=$(plutil -extract CFBundleVersion raw "$PLIST")

if [[ "$MODE" == "--version" ]]; then
    new_version="${2:?--version needs an explicit x.y.z}"
else
    IFS='.' read -r ma mi pa <<< "$version"
    case "$MODE" in
        major) new_version="$((ma+1)).0.0" ;;
        minor) new_version="$ma.$((mi+1)).0" ;;
        patch) new_version="$ma.$mi.$((pa+1))" ;;
        *) echo "unknown mode: $MODE (use major|minor|patch|--version x.y.z)"; exit 1 ;;
    esac
fi
new_build=$((build+1))

plutil -replace CFBundleShortVersionString -string "$new_version" "$PLIST"
plutil -replace CFBundleVersion -string "$new_build" "$PLIST"
echo "version: $version (build $build) → $new_version (build $new_build)"

# --- 2. build + package ------------------------------------------------------
"$ROOT/Scripts/make-dmg.sh"   # runs build-app.sh itself

DMG="$ROOT/build/DevEco Code Desktop-$new_version-arm64.dmg"

# --- 3. release notes --------------------------------------------------------
BUILD_DIR="$ROOT/build"
NOTES="$BUILD_DIR/ReleaseNotes-$new_version.md"
{
    echo "# DevEco Code Desktop $new_version (build $new_build)"
    echo
    echo "Date: $(date '+%Y-%m-%d')"
    echo
    if [[ -n "${RELEASE_NOTES:-}" ]]; then
        echo "$RELEASE_NOTES"
    else
        echo "## Highlights (latest completed items from ROADMAP)"
        echo
        # 最近 15 条已勾选项作为默认摘要；发布前可手工润色。
        grep -E "^- \[x\]" "$ROADMAP" | tail -15 | sed 's/^- \[x\] /- /'
        echo
        echo "<!-- Auto-generated; edit before publishing. -->"
    fi
    echo
    echo "## Install"
    echo
    echo "Open the arm64 or x86_64 DMG matching your Mac and drag the app to Applications. Signed with a local"
    echo "development certificate (not notarized): if Gatekeeper blocks the"
    echo "first launch, right-click the app → Open, or run"
    echo "\`xattr -dr com.apple.quarantine '/Applications/DevEco Code Desktop.app'\`."
    echo
    echo "Requires the deveco CLI (\`npm i -g deveco\`) and Node.js on PATH."
} > "$NOTES"
echo "notes:   $NOTES"

# --- 4. SHA-256 ---------------------------------------------------------------
for ARCH in arm64 x86_64; do
    DMG="$ROOT/build/DevEco Code Desktop-$new_version-$ARCH.dmg"
    SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
    printf 'SHA256=%s  %s\n' "$SHA" "$(basename "$DMG")" > "$DMG.sha256"
    echo "sha256:  $DMG.sha256"
    echo "         $SHA"
done

# --- 5. verification ----------------------------------------------------------
for ARCH in arm64 x86_64; do
    APP="$ROOT/DevEco Code Desktop ($ARCH).app"
    ARCH_DMG="$ROOT/build/DevEco Code Desktop-$new_version-$ARCH.dmg"
    [[ -f "$ARCH_DMG" ]] || { echo "DMG not found: $ARCH_DMG"; exit 1; }
    codesign --verify --deep --strict "$APP" && echo "codesign ($ARCH): OK"
    hdiutil verify "$ARCH_DMG" >/dev/null && echo "hdiutil ($ARCH):  OK"
    app_version=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
    [[ "$app_version" == "$new_version" ]] || { echo "version mismatch in built app ($ARCH): $app_version"; exit 1; }
done

echo
echo "RELEASE READY: $DMG"

# --- 6. version tag -----------------------------------------------------------
# Tag the release so the DMG can be attached to a GitHub Release later
# (needs a token; `gh release create v$version "$DMG"` when available).
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT" tag -f "v$new_version" >/dev/null && echo "tag:      v$new_version (push with: git push origin v$new_version)"
fi
