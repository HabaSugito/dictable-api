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

# Ad-hoc signature so macOS will run it locally. For distribution, sign with a Developer ID and notarize.
codesign --force --sign - "$APP"

(cd build && rm -f "DictableAPI-${VERSION}.zip" && ditto -c -k --keepParent "Dictable API.app" "DictableAPI-${VERSION}.zip")
echo "Built $APP and build/DictableAPI-${VERSION}.zip"
