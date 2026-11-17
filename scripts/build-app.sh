#!/bin/sh
# Builds "Hark Server.app" (a menu bar app) into ./build and zips it for a GitHub release.
# Requires macOS 26+ and Xcode 26+.
set -e
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^public let harkVersion = "\(.*\)"/\1/p' Sources/HarkCore/Server.swift)
APP="build/Hark Server.app"

swift build -c release --product HarkServer

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/HarkServer "$APP/Contents/MacOS/HarkServer"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hark Server</string>
  <key>CFBundleDisplayName</key><string>Hark Server</string>
  <key>CFBundleIdentifier</key><string>io.github.habasugito.HarkServer</string>
  <key>CFBundleExecutable</key><string>HarkServer</string>
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

(cd build && rm -f "HarkServer-${VERSION}.zip" && ditto -c -k --keepParent "Hark Server.app" "HarkServer-${VERSION}.zip")
echo "Built $APP and build/HarkServer-${VERSION}.zip"
