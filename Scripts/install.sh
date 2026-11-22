#!/bin/zsh
set -euo pipefail

# Usage: ./Scripts/install.sh [destination]
# Copies this project to the destination (skipping build artifacts), builds
# the .app there, and launches it.
SRC="${0:A:h:h}"
DST="${1:-/Users/godlims/Documents/iCodeSpace/DevEco Code Desktop}"

mkdir -p "$DST"
pkill -f 'DevEcoCodeDesktop' 2>/dev/null || true
tar -C "$SRC" --exclude='.build' --exclude='*.app' --exclude='.DS_Store' -cf - . | tar -C "$DST" -xf -
cd "$DST"
chmod +x Scripts/build-app.sh
ARCH="$(uname -m)"
MIN_MACOS="${MIN_MACOS:-12.0}"
./Scripts/build-app.sh "$ARCH" "$MIN_MACOS"
open "DevEco Code Desktop ($ARCH).app"
echo "Installed and launched $DST"
