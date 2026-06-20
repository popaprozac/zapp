#!/usr/bin/env bash
# SwiftUI → Nim interop spike build. Usage: ./build.sh [baseline|bridge|swiftui]
# Each stage prints the resulting binary size so FINDINGS.md can record deltas.
set -euo pipefail
cd "$(dirname "$0")"
STAGE="${1:-baseline}"

nim_build() {
  # $1 = extra --passL flags (may be empty)
  nim c --cc:clang --mm:orc -d:release --opt:size --hints:off \
    ${1:+--passL:"$1"} -o:probe probe.nim
}

case "$STAGE" in
  baseline)
    nim_build ""
    ;;
  *)
    echo "stage '$STAGE' not implemented until later tasks"; exit 2
    ;;
esac

echo "--- built: $(pwd)/probe ($(du -h probe | cut -f1)) ---"
