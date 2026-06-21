#!/usr/bin/env bash
# SwiftUI + WKWebView + .inspector spike. Usage: ./build.sh [macos|ios-sim]
set -euo pipefail
cd "$(dirname "$0")"
STAGE="${1:-macos}"
mkdir -p build
BUNDLE_ID="dev.zapp.spike.swiftuiwebview"

case "$STAGE" in
  macos)
    # NOTE: macOS uses a case-INSENSITIVE filesystem, so build/probe and
    # build/Probe would collide. Keep macOS + iOS artifacts in separate subdirs.
    mkdir -p build/macos
    swiftc -O -target arm64-apple-macos14.0 Probe.swift -o build/macos/probe
    echo "--- built build/macos/probe ($(du -h build/macos/probe | cut -f1)) ---"
    echo "run it:  ./build/macos/probe"
    ;;
  ios-sim)
    mkdir -p build/ios
    SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    swiftc -O -sdk "$SDK" -target arm64-apple-ios17.0-simulator Probe.swift -o build/ios/ProbeBin
    APP="build/ios/Probe.app"
    rm -rf "$APP"; mkdir -p "$APP"
    cp build/ios/ProbeBin "$APP/Probe"
    cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Probe</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UILaunchScreen</key><dict/>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>MinimumOSVersion</key><string>17.0</string>
</dict></plist>
PLIST
    echo "--- built $APP ---"
    echo "boot a sim (iPhone for the SHEET, iPad for the COLUMN), then:"
    echo "  xcrun simctl install booted $APP && xcrun simctl launch booted ${BUNDLE_ID}"
    ;;
  *) echo "stage '$STAGE' unknown (macos|ios-sim)"; exit 2 ;;
esac
