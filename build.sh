#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/Flagship.app"
mkdir -p "$PWD/build"
BUILD_TEMP=$(mktemp -d "$PWD/build/.compile.XXXXXX")
trap 'rm -rf "$BUILD_TEMP"' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_TEMP/module-cache"
cp Flagship/Flagship/Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
for arch in arm64 x86_64; do
    swiftc -O -module-cache-path "$BUILD_TEMP/module-cache" \
        -target "$arch-apple-macos13.0" \
        Flagship/Flagship/*.swift \
        -framework Cocoa -framework Foundation -framework SystemConfiguration \
        -framework Network -framework IOKit -framework ServiceManagement \
        -o "$BUILD_TEMP/Flagship-$arch"
done
lipo -create "$BUILD_TEMP/Flagship-arm64" "$BUILD_TEMP/Flagship-x86_64" \
    -output "$APP/Contents/MacOS/Flagship"
codesign --force --sign - "$APP"
echo "Built: $APP"
