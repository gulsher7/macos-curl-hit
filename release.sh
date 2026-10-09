#!/bin/bash
# Builds a universal (arm64 + x86_64) CurlHit.app and zips it for distribution.
# build.sh targets only the host architecture; this one targets both, so the
# download runs on Intel Macs as well as Apple silicon.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
APP="build/CurlHit.app"
ZIP="build/CurlHit-${VERSION}-macOS.zip"
MIN_MACOS="13.0"

rm -rf "$APP" "$ZIP" build/universal
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/universal
cp Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
  swift Tools/make-icon.swift >/dev/null
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

for ARCH in arm64 x86_64; do
  echo "Compiling ${ARCH}…"
  swiftc -O -whole-module-optimization \
    -target "${ARCH}-apple-macos${MIN_MACOS}" \
    -parse-as-library \
    -framework SwiftUI -framework AppKit \
    Sources/CurlHit/*.swift \
    -o "build/universal/CurlHit-${ARCH}"
done

echo "Merging into a universal binary…"
lipo -create -output "$APP/Contents/MacOS/CurlHit" \
  build/universal/CurlHit-arm64 build/universal/CurlHit-x86_64

codesign --force --options runtime \
  --entitlements CurlHit.entitlements \
  --sign - "$APP"

# ditto, not zip: it preserves the bundle's symlinks and code signature.
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Built  $APP"
echo "Arches $(lipo -archs "$APP/Contents/MacOS/CurlHit")"
echo "Zip    $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "SHA256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
