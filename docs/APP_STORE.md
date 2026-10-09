# Submitting Curl Hit to the Mac App Store

Everything in the repo is already shaped for submission. What's left is the part only you can do: the parts tied to your Apple Developer account.

## What's already done

- App Sandbox is on, with exactly one entitlement — `com.apple.security.network.client` (`CurlHit.entitlements`). No subprocesses, no file access, nothing App Review will ask about.
- Hardened Runtime enabled.
- `LSApplicationCategoryType` = `public.app-category.developer-tools`.
- A complete macOS icon set (16pt → 512pt @2x) in `Resources/Assets.xcassets`.
- `MARKETING_VERSION` 1.0 / `CURRENT_PROJECT_VERSION` 1, and a shared `CurlHit` scheme so `xcodebuild archive` works from the command line.
- `xcodebuild` already runs Apple's `-validate-for-store` check on every Release build, and it passes.

## 0. Your signing identity stays out of the repo

The Xcode project reads `DEVELOPMENT_TEAM` from `Local.xcconfig`, which is gitignored.
Create it once:

```bash
cp Local.xcconfig.example Local.xcconfig   # then put your team ID in it
```

`Signing.xcconfig` includes it with `#include?`, so the project still builds when the
file is absent — which is what CI and a fresh clone do. `docs/ExportOptions.plist` ships
with a `YOUR_TEAM_ID` placeholder for the same reason; copy it to
`docs/ExportOptions.local.plist` (also gitignored) with your real value before archiving.

Note that a team ID is not a secret — it is embedded in every signed binary and readable
with `codesign -dv` on any app you ship. Keeping it out of the repo is tidiness, not
protection.

## 1. Set your team and bundle ID

The bundle ID is currently `com.gulsher.curlhit`. Register that ID (or your own) at
[developer.apple.com → Identifiers](https://developer.apple.com/account/resources/identifiers/list), then:

```bash
open CurlHit.xcodeproj
```

Target **CurlHit** → **Signing & Capabilities**:

1. Check **Automatically manage signing**.
2. Pick your **Team**.
3. Confirm **Bundle Identifier** matches the ID you registered.

Xcode will create the "Apple Distribution" and "Mac Installer Distribution" certificates it needs.

If you change the bundle ID, change it in both places:

- `CurlHit.xcodeproj` → `PRODUCT_BUNDLE_IDENTIFIER` (both Debug and Release)
- `Info.plist` → `CFBundleIdentifier`

## 2. Create the App Store Connect record

At [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Apps** → **+** → **New App**:

- Platform: **macOS**
- Bundle ID: the one from step 1
- SKU: anything, e.g. `curlhit-1`

Then fill in, under the version:

- **Category**: Developer Tools
- **Screenshots**: at least one, 1280×800 / 1440×900 / 2560×1600 / 2880×1800. Resize the window, then `⇧⌘4` + Space to capture just the window.
- **Description / keywords / support URL** — the support URL can be your GitHub repo.
- **Privacy policy URL**: required even though the app collects nothing. A short page saying "this app collects no data" is enough.
- **App Privacy**: answer **No** to data collection. The app has no analytics and no accounts.
- **Encryption**: the app uses only HTTPS via Apple's own APIs, so it qualifies for the standard exemption. If App Store Connect asks, add this to `Info.plist`:

  ```xml
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
  ```

## 3. Archive and upload

From Xcode: **Product → Destination → Any Mac**, then **Product → Archive**, then **Distribute App → App Store Connect**.

Or from the terminal:

```bash
xcodebuild -project CurlHit.xcodeproj -scheme CurlHit \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath build/CurlHit.xcarchive archive

xcodebuild -exportArchive \
  -archivePath build/CurlHit.xcarchive \
  -exportOptionsPlist docs/ExportOptions.local.plist \
  -exportPath build/export
```

Make `docs/ExportOptions.local.plist` from the template first, as described above.
Then upload:

```bash
xcrun altool --upload-app -f build/export/CurlHit.pkg -t macos \
  --apple-id <your-apple-id> --password <app-specific-password>
```

Generate the app-specific password at [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords. Don't use your real Apple ID password, and don't commit it.

## 4. Bumping versions

For each new submission, raise both values in `CurlHit.xcodeproj` (and keep `Info.plist` in step):

- `MARKETING_VERSION` — what users see, e.g. `1.1`
- `CURRENT_PROJECT_VERSION` — must increase on every upload, even for the same marketing version

## Notes on review

A request-replaying tool is ordinary developer tooling and sits squarely in the Developer Tools category. Two things keep it uncontroversial, and both are worth preserving if you extend the app:

- Parallelism is **bounded at 50** and defaults to 1. Keep a hard cap if you raise it: a tool that can generate unbounded traffic against arbitrary third-party servers is a different review conversation than a developer utility for testing your own API.
- It has no bundled binaries and no subprocess execution, which is what makes the single network entitlement sufficient.

## Distributing outside the App Store too

Notarisation is a separate path from App Store review, and it needs a Developer ID certificate rather than an Apple Distribution one:

```bash
# Sign with Developer ID instead of the ad-hoc signature build.sh uses
codesign --force --options runtime --timestamp \
  --entitlements CurlHit.entitlements \
  --sign "Developer ID Application: Your Name (TEAMID)" build/CurlHit.app

ditto -c -k --keepParent build/CurlHit.app build/CurlHit.zip
xcrun notarytool submit build/CurlHit.zip \
  --apple-id <your-apple-id> --team-id <TEAMID> \
  --password <app-specific-password> --wait
xcrun stapler staple build/CurlHit.app
```

The ad-hoc signature from `build.sh` is fine on your own machine but will be refused on anyone else's.
