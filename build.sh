#!/bin/bash
# Builds BadgersBLELock.app. Requires only the Xcode Command Line Tools, not Xcode.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="BadgersBLELock.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/BadgersBLELock"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BadgersBLELock"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>BadgersBLELock</string>
    <key>CFBundleDisplayName</key>       <string>BadgersBLELock</string>
    <key>CFBundleExecutable</key>        <string>BadgersBLELock</string>
    <key>CFBundleIdentifier</key>        <string>local.badgersblelock</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>12.0</string>
    <!-- Menu-bar only: no Dock icon, no main window. -->
    <key>LSUIElement</key>               <true/>
    <!-- Required, or CoreBluetooth terminates the process on first use. -->
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>BadgersBLELock uses Bluetooth to measure how far away your phone is.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for a locally built app, and keeps the Bluetooth
# permission grant stable across rebuilds as long as the bundle id doesn't change.
codesign --force --deep --sign - "$APP"

echo "Built $(pwd)/$APP"
