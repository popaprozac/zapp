#!/usr/bin/env bash
# ===========================================================================
# Measure every built benchmark app via bench.sh and append a dated table
# to benchmarks/RESULTS.md.
#
# Runs bench.sh for each app that has a built .app bundle in the expected
# location. Apps that haven't been built yet are skipped with a warning.
#
# Usage:
#   ./scripts/measure-all.sh            # default runs (15)
#   ./scripts/measure-all.sh 25         # 25 startup samples per app
# ===========================================================================

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APPS="$BENCH_DIR/apps"
BENCH="$BENCH_DIR/bench.sh"
RESULTS="$BENCH_DIR/RESULTS.md"
TIMES_FILE="$BENCH_DIR/.build-times.json"
RUNS="${1:-15}"

BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
GREEN="\033[32m"; YELLOW="\033[33m"

if [[ ! -x "$BENCH" ]]; then
    echo "error: $BENCH not executable — run chmod +x" >&2
    exit 1
fi

# Each entry: "label:relative-path-to-app-dir-or-bundle-parent"
# Order here = order in the output table.
ENTRIES=(
    "zapp-jsc:apps/zapp-jsc/release"
    "zapp-txiki:apps/zapp-txiki/release"
    "tauri:apps/tauri/src-tauri/target/release/bundle/macos"
    "wails:apps/wails/bin"
    "electron:apps/electron/out/BenchElectron-darwin-arm64"
    "electrobun:apps/electrobun/build/stable-macos-arm64"
)

# ---------------------------------------------------------------------------
# Framework version resolution
#
# Transparency matters: if Tauri shaves 500 KB between releases or Electron's
# framework grows by 40 MB, readers of RESULTS.md need to know which version
# they're looking at. We read each version from the most authoritative source
# available without running slow tools:
#   - Zapp:       git short SHA of the monorepo (nothing else is pinned)
#   - Tauri:      `tauri` entry in Cargo.lock (skipping our own crate first)
#   - Wails:      github.com/wailsapp/wails/v3 line in go.mod
#   - Electron:   electron devDependency in package.json
#   - Electrobun: electrobun dependency in package.json
# ---------------------------------------------------------------------------
framework_version() {
    local label="$1"
    case "$label" in
        zapp-jsc|zapp-txiki)
            git -C "$BENCH_DIR/.." rev-parse --short HEAD 2>/dev/null || echo "unknown"
            ;;
        tauri)
            # Skip the first "tauri" block (our own crate), read the next one.
            awk '
                /^name = "tauri"$/ { count++; if (count == 2) in_block = 1; next }
                in_block && /^version = / { gsub(/["v]/, "", $3); print $3; exit }
            ' "$BENCH_DIR/apps/tauri/src-tauri/Cargo.lock" 2>/dev/null || echo "unknown"
            ;;
        wails)
            # go.mod line looks like: `require github.com/wailsapp/wails/v3 v3.0.0-alpha.74`
            awk '
                /^require github\.com\/wailsapp\/wails\/v3 / {
                    sub(/^v/, "", $3); print $3; exit
                }
            ' "$BENCH_DIR/apps/wails/go.mod" 2>/dev/null || echo "unknown"
            ;;
        electron)
            python3 -c 'import json; p=json.load(open("'"$BENCH_DIR"'/apps/electron/package.json")); print(p["devDependencies"]["electron"].lstrip("~^"))' 2>/dev/null || echo "unknown"
            ;;
        electrobun)
            python3 -c 'import json; p=json.load(open("'"$BENCH_DIR"'/apps/electrobun/package.json")); print(p["dependencies"]["electrobun"].lstrip("~^"))' 2>/dev/null || echo "unknown"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Electrobun ships as a self-extracting bundle: on first launch its launcher
# unpacks a ~17 MB .tar.zst in Contents/Resources/ into ~60 MB of files in
# Contents/MacOS/ (bun, libasar, etc.), mutating the .app in place. After
# that, bundle_bytes no longer reflects the shipping weight.
#
# To keep bundle_bytes honest across runs, we rebuild electrobun fresh right
# before measuring it. The build is fast (<10s) and writes to the same path.
# Other frameworks don't mutate on launch, so no pre-step is needed for them.
# ---------------------------------------------------------------------------
freshen_bundle() {
    local label="$1"
    case "$label" in
        electrobun)
            (
                cd "$BENCH_DIR/apps/electrobun"
                rm -rf build
                bun run build:stable >/dev/null 2>&1
            )
            ;;
    esac
}

records=()
versions=()
for entry in "${ENTRIES[@]}"; do
    label="${entry%%:*}"
    path_rel="${entry#*:}"
    path_abs="$BENCH_DIR/$path_rel"

    echo -ne "${BOLD}measuring ${label}...${RESET} "

    freshen_bundle "$label"

    if [[ ! -d "$path_abs" ]]; then
        echo -e "${YELLOW}skip (not built: $path_rel)${RESET}"
        continue
    fi

    # Let bench.sh find the .app inside the given directory.
    rec=$("$BENCH" "$path_abs" "$label" "$RUNS" 2>/dev/null || true)
    if [[ -z "$rec" ]]; then
        echo -e "${YELLOW}skip (bench failed)${RESET}"
        continue
    fi
    ver=$(framework_version "$label")
    echo -e "${GREEN}ok${RESET} ${DIM}(v${ver})${RESET}"
    records+=("$rec")
    versions+=("$ver")
done

if [[ ${#records[@]} -eq 0 ]]; then
    echo "no apps measured — run build-all.sh first" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Append a dated section to RESULTS.md
# ---------------------------------------------------------------------------
date_str=$(date "+%Y-%m-%d %H:%M")
host=$(scutil --get ComputerName 2>/dev/null || hostname)
macos_ver=$(sw_vers -productVersion)
arch=$(uname -m)

fmt_size() {
    local b=$1
    if (( b >= 1048576 )); then
        awk -v b="$b" 'BEGIN { printf "%.1f MB", b/1048576 }'
    elif (( b > 0 )); then
        awk -v b="$b" 'BEGIN { printf "%d KB", b/1024 }'
    else
        echo "—"
    fi
}

# ---------------------------------------------------------------------------
# Build time lookup from .build-times.json (populated by build-all.sh).
#
# Returns a pre-formatted string like "12.3s" / "2m 14s" / "—". Missing
# frameworks (not yet built, or built in one mode but not the other) fall
# back to an em dash so the column still aligns.
# ---------------------------------------------------------------------------
build_time() {
    local label="$1"
    local mode="$2"
    if [[ ! -f "$TIMES_FILE" ]]; then
        echo "—"
        return
    fi
    python3 -c "
import json, sys
try:
    d = json.load(open('$TIMES_FILE'))
    s = d.get('$mode', {}).get('$label')
    if s is None:
        print('—')
    elif s >= 60:
        m = int(s // 60); r = s - m * 60
        print(f'{m}m {r:.1f}s')
    else:
        print(f'{s:.1f}s')
except Exception:
    print('—')
"
}

{
    echo ""
    echo "## ${date_str} — ${host} (macOS ${macos_ver}, ${arch})"
    echo ""
    echo "Startup samples per app: ${RUNS} (after 5 warmups). Binary column shows the"
    echo "main executable for native-style bundles, the Electron Framework for Electron,"
    echo "or the self-extracting archive for Electrobun (noted in parentheses)."
    if [[ -f "$TIMES_FILE" ]]; then
        echo ""
        echo "Build times come from \`.build-times.json\` written by \`build-all.sh\`:"
        echo "run \`./scripts/build-all.sh cold\` and \`./scripts/build-all.sh hot\` before"
        echo "\`measure-all.sh\` to populate both columns. Cold wipes each app's local"
        echo "build outputs first (not dep caches); hot leaves them in place."
    fi
    echo ""
    echo "| Framework | Version | Build (cold) | Build (hot) | Binary | Bundle | Icon | Startup (ms) | Idle (MB) |"
    echo "|---|---|---:|---:|---:|---:|---:|---:|---:|"
    for i in "${!records[@]}"; do
        rec="${records[$i]}"
        ver="${versions[$i]}"
        label=$(python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["label"])' <<< "$rec")
        bin_b=$(python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["binary_bytes"])' <<< "$rec")
        bin_note=$(python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["binary_note"])' <<< "$rec")
        bundle_b=$(python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["bundle_bytes"])' <<< "$rec")
        icon_b=$(python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["icon_bytes"])' <<< "$rec")
        startup_ms=$(python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["startup_ms"])' <<< "$rec")
        idle_mb=$(python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["idle_mb"])' <<< "$rec")

        # Annotate binary column with note when it's not a plain main binary.
        bin_str=$(fmt_size "$bin_b")
        if [[ "$bin_note" != "main" ]]; then
            bin_str="$bin_str ($bin_note)"
        fi

        cold_str=$(build_time "$label" "cold")
        hot_str=$(build_time "$label" "hot")

        printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
            "$label" "$ver" "$cold_str" "$hot_str" "$bin_str" "$(fmt_size "$bundle_b")" "$(fmt_size "$icon_b")" "$startup_ms" "$idle_mb"
    done
    echo ""
    echo "<details><summary>raw JSON</summary>"
    echo ""
    echo '```json'
    for i in "${!records[@]}"; do
        # Inject version + build times into the JSON for completeness.
        python3 -c '
import json, sys, os
rec = json.loads(sys.argv[1])
rec["framework_version"] = sys.argv[2]
times_file = sys.argv[3]
if os.path.exists(times_file):
    try:
        t = json.load(open(times_file))
        rec["build_cold_s"] = t.get("cold", {}).get(rec["label"])
        rec["build_hot_s"] = t.get("hot", {}).get(rec["label"])
    except Exception:
        pass
print(json.dumps(rec))
' "${records[$i]}" "${versions[$i]}" "$TIMES_FILE"
    done
    echo '```'
    echo ""
    echo "</details>"
} >> "$RESULTS"

echo ""
echo -e "${BOLD}${GREEN}appended results to $RESULTS${RESET}"
echo ""
tail -n $(( 10 + ${#records[@]} )) "$RESULTS"
