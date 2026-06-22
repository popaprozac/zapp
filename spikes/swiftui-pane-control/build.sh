#!/usr/bin/env bash
# SwiftUI pane-control spike (2c risk gate). Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/macos
swiftc -O -target arm64-apple-macos14.0 spike.swift -o build/macos/spike
echo "--- built build/macos/spike ($(du -h build/macos/spike | cut -f1)) ---"
echo "run it:  ./build/macos/spike"
