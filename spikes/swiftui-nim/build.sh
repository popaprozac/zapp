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

SWIFT_LIBDIR="$(dirname "$(xcrun --find swiftc)")/../lib/swift/macosx"

build_swift_lib() {
  swiftc -emit-library -static -O -module-name zappswift -o libzappswift.a probe.swift
}

swift_link_flags() {
  echo "-L. -lzappswift -L${SWIFT_LIBDIR} -lswiftCore -lswiftFoundation -Xlinker -rpath -Xlinker ${SWIFT_LIBDIR} -Xlinker -rpath -Xlinker /usr/lib/swift"
}

case "$STAGE" in
  baseline)
    nim_build ""
    ;;
  bridge)
    build_swift_lib
    nim_build "$(swift_link_flags)"
    ;;
  swiftui)
    build_swift_lib
    nim_build "$(swift_link_flags) -framework SwiftUI -framework AppKit"
    ;;
  *)
    echo "stage '$STAGE' not implemented until later tasks"; exit 2
    ;;
esac

echo "--- built: $(pwd)/probe ($(du -h probe | cut -f1)) ---"
