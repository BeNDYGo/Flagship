#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="$PWD/build/Flagship.app"
DMG="$PWD/build/Flagship.dmg"

if [ ! -d "$APP" ]; then
    echo "Flagship.app not found in build/. Running ./build.sh first..."
    ./build.sh
fi

echo "Creating DMG..."
mkdir -p "$PWD/build"
rm -f "$DMG"

DMG_TMP=$(mktemp -d "/tmp/flagship_dmg.XXXXXX")
trap 'rm -rf "$DMG_TMP"' EXIT

cp -R "$APP" "$DMG_TMP/"
ln -s /Applications "$DMG_TMP/Applications"

hdiutil create -volname "Flagship" -srcfolder "$DMG_TMP" -ov -format UDZO "$DMG" > /dev/null

echo "DMG created: $DMG"
