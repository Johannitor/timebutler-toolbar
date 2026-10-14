#!/usr/bin/env bash
# Builds a Release version and installs it to ~/Applications, then (re)launches it.
set -euo pipefail

cd "$(dirname "$0")/.."

xcodegen generate
xcodebuild \
  -project TimebutlerToolbar.xcodeproj \
  -scheme TimebutlerToolbar \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -allowProvisioningUpdates \
  build

APP_SRC="build/Build/Products/Release/TimebutlerToolbar.app"
DEST="$HOME/Applications"
mkdir -p "$DEST"

pkill -x TimebutlerToolbar || true
sleep 1

rm -rf "$DEST/TimebutlerToolbar.app"
cp -R "$APP_SRC" "$DEST/"
open "$DEST/TimebutlerToolbar.app"
echo "Installiert: $DEST/TimebutlerToolbar.app"
