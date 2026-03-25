#!/usr/bin/env bash
set -euo pipefail

# Run all Zen-C interop tests
# Each .zc file is a standalone test that compiles and runs

DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
SKIP=0

for f in "$DIR"/tests/*.zc; do
    name="$(basename "$f" .zc)"

    # Check for platform skip markers
    if grep -q '@skip_on_linux' "$f" && [[ "$(uname)" == "Linux" ]]; then
        echo "SKIP  $name (linux)"
        SKIP=$((SKIP + 1))
        continue
    fi

    out="/tmp/zenc_test_$name"
    if zc "$f" -o "$out" 2>/dev/null; then
        if "$out" 2>/dev/null; then
            echo "PASS  $name"
            PASS=$((PASS + 1))
        else
            echo "FAIL  $name (runtime)"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL  $name (compile)"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$out" "${out}.c"
done

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] || exit 1
