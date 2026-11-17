#!/bin/sh
# Builds "Dictable API.app" (a menu bar app) into ./build and zips it for a GitHub release.
# Requires macOS 26+ and Xcode 26+.
set -e
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^public let appVersion = "\(.*\)"/\1/p' Sources/DictableCore/Server.swift)
APP="build/Dictable API.app"

swift build -c release --product DictableAPI

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DictableAPI "$APP/Contents/MacOS/DictableAPI"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dictable API</string>
  <key>CFBundleDisplayName</key><string>Dictable API</string>
  <key>CFBundleIdentifier</key><string>io.github.habasugito.DictableAPI</string>
  <key>CFBundleExecutable</key><string>DictableAPI</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# ---- Signing ----
# Uses the first "Developer ID Application" certificate in the keychain (override with SIGN_IDENTITY).
# Without one, falls back to an ad-hoc signature, which runs locally but is blocked by Gatekeeper elsewhere.
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null |
  sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}

ZIP="build/DictableAPI-${VERSION}.zip"
make_zip() { (cd build && rm -f "$(basename "$ZIP")" && ditto -c -k --keepParent "Dictable API.app" "$(basename "$ZIP")"); }

if [ -n "$IDENTITY" ]; then
  # Hardened runtime + secure timestamp are required for notarization.
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "No Developer ID certificate found: ad-hoc signed (local use only)."
fi
make_zip

# ---- Notarization ----
# One-time setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials dictable-notary --team-id <TEAM_ID>
# Then every build is notarized and the ticket is stapled to the app.
NOTARY_PROFILE=${NOTARY_PROFILE:-dictable-notary}
if [ -n "$IDENTITY" ] && [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Submitting to Apple for notarization (usually 1-5 minutes)…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    make_zip  # re-zip so the download contains the stapled ticket
    spctl --assess --type execute --verbose=2 "$APP"
  else
    echo "Notarization skipped: no keychain profile '$NOTARY_PROFILE'."
    echo "Run once: xcrun notarytool store-credentials $NOTARY_PROFILE --team-id <TEAM_ID>"
  fi
fi

echo "Built $APP and $ZIP"
