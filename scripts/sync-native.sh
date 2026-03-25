#!/usr/bin/env bash
set -euo pipefail

# Sync native framework source to the CLI package for publishing.
# Run this before publishing @zappdev/cli.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Syncing native source to packages/cli/native/..."
rsync -av --delete "$ROOT/src/" "$ROOT/packages/cli/native/src/"
rsync -av --delete "$ROOT/vendor/" "$ROOT/packages/cli/native/vendor/"
echo "Done."
