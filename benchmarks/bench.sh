#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# Zapp Benchmark Suite
#
# Measures binary size, startup time, and memory for:
#   - Zapp (hello-world)
#   - Competitors (Tauri, Wails, Electrobun, Electron) if installed
#
# Usage:
#   ./benchmarks/bench.sh              # Zapp only, 10 runs
#   ./benchmarks/bench.sh 20           # 20 startup runs
#   ./benchmarks/bench.sh 10 --all     # Include competitor comparison
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELLO="$SCRIPT_DIR/hello-world"
RUNS=${1:-10}
COMPARE_ALL=${2:-""}

BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"
GREEN="\033[32m"
CYAN="\033[36m"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
measure_startup() {
    local bin="$1"
    local runs="$2"
    local times=()

    for i in $(seq 1 "$runs"); do
        local start end elapsed
        start=$(python3 -c "import time; print(int(time.monotonic_ns()))")
        "$bin" &
        local pid=$!
        # Give the app time to launch and render its first frame
        sleep 0.5
        end=$(python3 -c "import time; print(int(time.monotonic_ns()))")
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        elapsed=$(( (end - start) / 1000000 ))
        times+=("$elapsed")
    done

    # Sort and get median
    IFS=$'\n' sorted=($(sort -n <<<"${times[*]}")); unset IFS
    local median_idx=$(( runs / 2 ))
    echo "${sorted[$median_idx]}"
}

measure_memory() {
    local bin="$1"
    "$bin" &
    local pid=$!
    sleep 2

    local mem="?"
    if [[ "$(uname)" == "Darwin" ]]; then
        # Use footprint for accurate process-owned memory
        mem=$(footprint "$pid" 2>/dev/null | head -3 | grep "Footprint:" | grep -oE '[0-9]+ MB' | head -1 || echo "?")
        if [[ "$mem" == "?" ]]; then
            # Fallback to ps
            local rss
            rss=$(ps -o rss= -p "$pid" 2>/dev/null || echo "0")
            mem="$((rss / 1024)) MB (RSS)"
        fi
    else
        local rss
        rss=$(ps -o rss= -p "$pid" 2>/dev/null || echo "0")
        mem="$((rss / 1024)) MB (RSS)"
    fi

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "$mem"
}

format_size() {
    local bytes=$1
    if [[ $bytes -ge 1048576 ]]; then
        echo "$((bytes / 1048576)) MB"
    else
        echo "$((bytes / 1024)) KB"
    fi
}

# ---------------------------------------------------------------------------
# Zapp Benchmark
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}=== Zapp Benchmark Suite ===${RESET}"
echo ""

# Build hello-world
echo -e "${DIM}Building Zapp hello-world...${RESET}"
cd "$ROOT"
bun packages/cli/dist/zapp-cli.js build --root benchmarks/hello-world --brotli 2>/dev/null

ZAPP_BIN="$HELLO/bin/hello-world"
if [[ ! -f "$ZAPP_BIN" ]]; then
    echo "Build failed — binary not found"
    exit 1
fi

ZAPP_SIZE=$(stat -f%z "$ZAPP_BIN" 2>/dev/null || stat -c%s "$ZAPP_BIN" 2>/dev/null)
ZAPP_SIZE_FMT=$(format_size "$ZAPP_SIZE")

echo -e "${BOLD}Binary size:${RESET}  ${GREEN}${ZAPP_SIZE_FMT}${RESET} (${ZAPP_SIZE} bytes)"
echo ""

echo -e "${BOLD}Startup time${RESET} (${RUNS} runs, median):"
ZAPP_STARTUP=$(measure_startup "$ZAPP_BIN" "$RUNS")
echo -e "  Zapp:  ${GREEN}${ZAPP_STARTUP} ms${RESET}"
echo ""

echo -e "${BOLD}Memory${RESET} (footprint after 2s idle):"
ZAPP_MEM=$(measure_memory "$ZAPP_BIN")
echo -e "  Zapp:  ${GREEN}${ZAPP_MEM}${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Competitor Reference
# ---------------------------------------------------------------------------
echo -e "${BOLD}--- Competitor Reference ---${RESET}"
echo ""
printf "  %-14s %10s %12s %10s\n" "Framework" "Binary" "Startup" "Memory"
printf "  %-14s %10s %12s %10s\n" "---------" "------" "-------" "------"
printf "  %-14s %10s %12s %10s\n" "Zapp" "$ZAPP_SIZE_FMT" "${ZAPP_STARTUP} ms" "$ZAPP_MEM"
printf "  %-14s %10s %12s %10s\n" "Tauri v2" "5-15 MB" "<500 ms" "30-40 MB"
printf "  %-14s %10s %12s %10s\n" "Wails v3" "4-8 MB" "<200 ms" "~25 MB"
printf "  %-14s %10s %12s %10s\n" "Electrobun" "~14 MB" "<50 ms" "~30 MB"
printf "  %-14s %10s %12s %10s\n" "Electron" "100+ MB" "1-2 s" "200+ MB"
echo ""

# ---------------------------------------------------------------------------
# Live Competitor Benchmarks (if --all and apps are installed)
# ---------------------------------------------------------------------------
if [[ "$COMPARE_ALL" == "--all" ]]; then
    echo -e "${BOLD}--- Live Competitor Measurements ---${RESET}"
    echo -e "${DIM}(Requires competitor hello-world apps to be pre-built)${RESET}"
    echo ""

    # Look for competitor binaries in benchmarks/competitors/
    COMP_DIR="$SCRIPT_DIR/competitors"
    if [[ -d "$COMP_DIR" ]]; then
        for app_dir in "$COMP_DIR"/*/; do
            app_name=$(basename "$app_dir")
            # Look for a binary or .app bundle
            bin=""
            if [[ -f "$app_dir/bin" ]]; then
                bin="$app_dir/bin"
            elif [[ -d "$app_dir"/*.app ]]; then
                bin=$(find "$app_dir" -name "*.app" -maxdepth 1 | head -1)
                bin="$bin/Contents/MacOS/$(basename "$bin" .app)"
            elif [[ -f "$app_dir/build/bin/"* ]]; then
                bin=$(find "$app_dir/build/bin" -type f -perm +111 | head -1)
            fi

            if [[ -n "$bin" && -f "$bin" ]]; then
                local size
                size=$(stat -f%z "$bin" 2>/dev/null || echo "0")
                echo -e "  ${CYAN}${app_name}${RESET}: $(format_size "$size")"
                local startup
                startup=$(measure_startup "$bin" 5)
                echo "    Startup (5 runs, median): ${startup} ms"
                local mem
                mem=$(measure_memory "$bin")
                echo "    Memory: ${mem}"
            else
                echo -e "  ${DIM}${app_name}: no binary found${RESET}"
            fi
        done
    else
        echo -e "  ${DIM}No competitors/ directory. Create benchmarks/competitors/{tauri,wails,electrobun}/ with built apps.${RESET}"
    fi
    echo ""
fi

echo -e "${BOLD}=== Done ===${RESET}"
echo ""
echo "To measure bridge performance, run the app in dev mode and paste"
echo "benchmarks/bridge-bench.ts into the webview console."
