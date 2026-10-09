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

# Prefer a Developer ID identity so the download opens without a Gatekeeper
# detour. Falls back to an ad-hoc signature, which is fine locally but which
# other Macs will refuse.
IDENTITY="$(security find-identity -v -p codesigning \
            | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
NOTARY_PROFILE="${NOTARY_PROFILE:-curlhit}"

if [ -n "$IDENTITY" ]; then
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp \
    --entitlements CurlHit.entitlements \
    --sign "$IDENTITY" "$APP"
else
  echo "No Developer ID Application certificate found — signing ad-hoc."
  echo "The result runs here but other Macs will refuse it."
  codesign --force --options runtime \
    --entitlements CurlHit.entitlements \
    --sign - "$APP"
fi

# ditto, not zip: it preserves the bundle's symlinks and code signature.
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "$IDENTITY" ]; then
  echo
  echo "Submitting to Apple for notarisation (this usually takes a few minutes)…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

  # Staple the ticket into the bundle so it validates offline, then re-zip the
  # stapled copy — the zip made before stapling does not carry the ticket.
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"

  echo
  echo "Gatekeeper assessment:"
  spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
  xcrun stapler validate "$APP" 2>&1 | sed 's/^/  /'
fi

echo
echo "Built  $APP"
echo "Arches $(lipo -archs "$APP/Contents/MacOS/CurlHit")"
echo "Signed $([ -n "$IDENTITY" ] && echo "Developer ID, notarised and stapled" || echo "ad-hoc (not distributable)")"
echo "Zip    $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "SHA256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
