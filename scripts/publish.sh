#!/usr/bin/env bash
set -euo pipefail

# Publish Zapp packages to JSR and NPM
#
# Usage:
#   ./scripts/publish.sh <version>                    # publish ALL packages
#   ./scripts/publish.sh <version> --package runtime  # publish one package
#   ./scripts/publish.sh <version> --dry              # dry-run (no publish)
#   ./scripts/publish.sh <version> --package cli --dry
#
# Examples:
#   ./scripts/publish.sh 0.2.0
#   ./scripts/publish.sh 0.2.0 --package runtime
#   ./scripts/publish.sh 0.2.0 --package runtime --dry

VERSION=${1:?"Usage: ./scripts/publish.sh <version> [--package <name>] [--dry]"}
shift

DRY_RUN=""
SINGLE_PKG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry) DRY_RUN="--dry-run"; shift ;;
    --package) SINGLE_PKG="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALL_PACKAGES=("runtime" "cli" "vite")

if [[ -n "$SINGLE_PKG" ]]; then
  PACKAGES=("$SINGLE_PKG")
else
  PACKAGES=("${ALL_PACKAGES[@]}")
fi

if [[ -n "$DRY_RUN" ]]; then
  echo "=== DRY RUN ==="
fi
echo "Publishing: ${PACKAGES[*]} @ v${VERSION}"
echo ""

# --- Update versions ---
for pkg in "${PACKAGES[@]}"; do
  PKG_DIR="$ROOT/packages/$pkg"
  if [[ ! -d "$PKG_DIR" ]]; then
    echo "Package not found: $pkg"
    exit 1
  fi
  echo "[$pkg] Updating version to ${VERSION}..."
  cd "$PKG_DIR"
  bun -e "
    const pkg = JSON.parse(await Bun.file('package.json').text());
    pkg.version = '${VERSION}';
    await Bun.write('package.json', JSON.stringify(pkg, null, 2) + '\n');
  "
  if [ -f "jsr.json" ]; then
    bun -e "
      const jsr = JSON.parse(await Bun.file('jsr.json').text());
      jsr.version = '${VERSION}';
      await Bun.write('jsr.json', JSON.stringify(jsr, null, 2) + '\n');
    "
  fi
done

echo ""

# --- Sync native source to CLI package ---
if [[ " ${PACKAGES[*]} " == *" cli "* ]]; then
  echo "[cli] Syncing native source..."
  "$ROOT/scripts/sync-native.sh"
  echo ""
fi

# --- Build if needed ---
for pkg in "${PACKAGES[@]}"; do
  PKG_DIR="$ROOT/packages/$pkg"
  cd "$PKG_DIR"
  if [[ "$pkg" == "cli" ]]; then
    echo "[$pkg] Building..."
    bun run build
  elif [[ "$pkg" == "vite" ]] && [ -f "tsconfig.json" ]; then
    echo "[$pkg] Building..."
    bunx tsc 2>/dev/null || true
  fi
done

echo ""

# --- Publish to JSR ---
echo "=== JSR ==="
for pkg in "${PACKAGES[@]}"; do
  PKG_DIR="$ROOT/packages/$pkg"
  cd "$PKG_DIR"
  if [ -f "jsr.json" ]; then
    echo "[$pkg] Publishing to JSR..."
    JSR_TOKEN=""
    if [ -f "$HOME/.jsr-token" ]; then
      JSR_TOKEN="--token $(cat "$HOME/.jsr-token")"
    fi
    if [ -n "$DRY_RUN" ]; then
      bunx jsr publish --allow-dirty --dry-run $JSR_TOKEN 2>&1 || echo "  JSR dry-run issue (non-fatal)"
    else
      bunx jsr publish --allow-dirty $JSR_TOKEN 2>&1 || echo "  JSR publish failed"
    fi
  else
    echo "[$pkg] No jsr.json — skipping"
  fi
done

echo ""

# --- Publish to NPM ---
echo "=== NPM ==="
for pkg in "${PACKAGES[@]}"; do
  PKG_DIR="$ROOT/packages/$pkg"
  cd "$PKG_DIR"
  if grep -q '"private": true' package.json 2>/dev/null; then
    echo "[$pkg] Skipped (private)"
    continue
  fi
  echo "[$pkg] Publishing to NPM..."
  if [ -n "$DRY_RUN" ]; then
    npm publish --dry-run 2>&1 || echo "  NPM dry-run issue (non-fatal)"
  else
    npm publish --access public 2>&1 || echo "  NPM publish failed"
  fi
done

echo ""
echo "=== Done ==="
