#!/bin/bash
# Builds CurlHit.app with nothing but the Swift compiler. No Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/CurlHit.app"
MIN_MACOS="13.0"
ARCH_FLAGS=(-target "$(uname -m)-apple-macos$MIN_MACOS")

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

# App icon (generated from code, see Tools/make-icon.swift)
if [ ! -f build/AppIcon.icns ]; then
  swift Tools/make-icon.swift >/dev/null
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "Compiling…"
swiftc -O -whole-module-optimization \
  "${ARCH_FLAGS[@]}" \
  -parse-as-library \
  -framework SwiftUI -framework AppKit \
  Sources/CurlHit/*.swift \
  -o "$APP/Contents/MacOS/CurlHit"

# Ad-hoc signature + App Sandbox, same entitlements the App Store build uses.
codesign --force --options runtime \
  --entitlements CurlHit.entitlements \
  --sign - "$APP"

echo "Built $APP  ($(du -sh "$APP" | cut -f1))"
