#!/bin/bash
# Zapp Bootstrap Script
# Syncs native framework code to CLI and rebuilds CLI for current platform
# Usage: ./bootstrap.sh [--clean]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_DIR="$SCRIPT_DIR/packages/cli"
VITE_DIR="$SCRIPT_DIR/packages/vite"
NATIVE_DIR="$CLI_DIR/native"
SRC_DIR="$SCRIPT_DIR/src"
VENDOR_DIR="$SCRIPT_DIR/vendor"

CLEAN=false
if [[ "$1" == "--clean" ]]; then
    CLEAN=true
fi

echo "[zapp] bootstrapping for $(uname -s)..."

# Clean if requested
if $CLEAN; then
    echo "[zapp] cleaning build artifacts..."
    rm -rf "$SCRIPT_DIR/example/.zapp"
    rm -rf "$SCRIPT_DIR/example/bin"
    echo "[zapp] cleaned"
fi

# Sync src/ directory (exclude generated, tools, node_modules, .git)
echo "[zapp] syncing native/src/..."
rm -rf "$NATIVE_DIR/src"
mkdir -p "$NATIVE_DIR"
cp -r "$SRC_DIR" "$NATIVE_DIR/src"
# Clean unwanted directories
rm -rf "$NATIVE_DIR/src/cli/node_modules"
rm -rf "$NATIVE_DIR/src/cli/dist"
rm -rf "$NATIVE_DIR/src/cli/bun.lock"
rm -rf "$NATIVE_DIR/src/cli/package.json"
rm -rf "$NATIVE_DIR/src/tools"
rm -rf "$NATIVE_DIR/src/generated"

# Run Bun install on packages
echo "[zapp] running Bun install on packages..."
cd "$CLI_DIR"
bun install
cd "$VITE_DIR"
bun install

# Sync vendor/ directory (exclude .git, build, docs)
echo "[zapp] syncing native/vendor/..."
rm -rf "$NATIVE_DIR/vendor"
mkdir -p "$NATIVE_DIR/vendor"

# Sync quickjs-ng (minimal - just source files)
echo "  syncing quickjs-ng..."
mkdir -p "$NATIVE_DIR/vendor/quickjs-ng"
rsync -av --delete \
    --exclude '.git' \
    --exclude 'build' \
    --exclude 'docs' \
    --exclude 'test262*' \
    --exclude '*.md' \
    "$VENDOR_DIR/quickjs-ng/" "$NATIVE_DIR/vendor/quickjs-ng/"

# Sync webview2 (just headers)
if [[ -d "$VENDOR_DIR/webview2" ]]; then
    echo "  syncing webview2..."
    mkdir -p "$NATIVE_DIR/vendor/webview2"
    rsync -av --delete \
        --exclude '.git' \
        "$VENDOR_DIR/webview2/" "$NATIVE_DIR/vendor/webview2/"
fi

# Ensure git submodules are updated
echo "[zapp] updating git submodules..."
cd "$VENDOR_DIR/quickjs-ng"
git submodule update --init --recursive

# Rebuild CLI
echo "[zapp] rebuilding CLI..."
cd "$CLI_DIR"
bun run build

echo "[zapp] bootstrap complete!"
