#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
CFLAGS="${CFLAGS:-} ${EXTRA_CFLAGS:-}"

rm -rf build && mkdir -p build/SplitRef.app

clang \
    -isysroot "$SDK" \
    -target arm64-apple-ios15.0-simulator \
    -fobjc-arc \
    -fmodules \
    -framework UIKit \
    -framework Foundation \
    -framework WebKit \
    $CFLAGS \
    src/*.m \
    -o build/SplitRef.app/SplitRef

cp Info.plist build/SplitRef.app/Info.plist

echo "[splitref] build complete: build/SplitRef.app"
echo ""
echo "Run on a booted sim:"
echo "  xcrun simctl install booted build/SplitRef.app && xcrun simctl launch booted dev.zapp.splitref"
