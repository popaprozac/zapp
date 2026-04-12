#!/usr/bin/env bash
# ===========================================================================
# Build every benchmark app in release mode, with optional cold/hot timing.
#
# Usage:
#   ./scripts/build-all.sh              # default: hot build (no cache wipe)
#   ./scripts/build-all.sh hot          # same as above, explicit
#   ./scripts/build-all.sh cold         # wipe per-framework build outputs
#                                         (NOT dep caches) then build
#
# Running both `cold` and then `hot` leaves .build-times.json populated
# with both modes, so measure-all.sh can emit Build (cold/hot) columns.
#
# Skip individual frameworks:
#   SKIP_ZAPP_JSC=1   SKIP_ZAPP_TXIKI=1
#   SKIP_TAURI=1      SKIP_WAILS=1
#   SKIP_ELECTRON=1   SKIP_ELECTROBUN=1
#
# What "cold" wipes per framework (project-local build outputs only —
# dep caches like node_modules, ~/.cargo, go build cache are preserved
# so we're measuring compile time, not network speed):
#   zapp-*       .zapp/ bin/ dist/ release/
#   tauri        src-tauri/target/ dist/
#   wails        bin/ frontend/dist/ frontend/bindings/
#   electron     out/
#   electrobun   build/ artifacts/
# ===========================================================================

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APPS="$BENCH_DIR/apps"
TIMES_FILE="$BENCH_DIR/.build-times.json"

MODE="${1:-hot}"
if [[ "$MODE" != "cold" && "$MODE" != "hot" ]]; then
    echo "error: first argument must be 'cold' or 'hot' (got: $MODE)" >&2
    exit 2
fi

BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; CYAN="\033[36m"

need() {
    local cmd="$1"; local hint="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf "${RED}missing${RESET} %s — %s\n" "$cmd" "$hint" >&2
        return 1
    fi
}

fail=0
echo -e "${BOLD}== prerequisite check ==${RESET}"
need bun "install from https://bun.sh" || fail=1
need zc "install Zen-C compiler from https://zenc-lang.org" || fail=1
if [[ "${SKIP_ZAPP_TXIKI:-}" != "1" ]]; then
    need cmake "brew install cmake (needed for txiki build)" || fail=1
fi
need codesign "install Xcode Command Line Tools: xcode-select --install" || fail=1
if [[ "${SKIP_TAURI:-}" != "1" ]]; then
    need cargo "install Rust from https://rustup.rs (Tauri needs it)" || fail=1
fi
if [[ "${SKIP_WAILS:-}" != "1" ]]; then
    need go "install Go 1.22+ from https://go.dev (Wails needs it)" || fail=1
    need wails3 "go install github.com/wailsapp/wails/v3/cmd/wails3@latest" || fail=1
fi
if [[ "${SKIP_ELECTRON:-}" != "1" ]]; then
    need npm "install Node 20+ from https://nodejs.org (Electron needs it)" || fail=1
fi
need python3 "needed for timing + JSON updates" || fail=1
if [[ $fail -ne 0 ]]; then
    echo -e "\n${RED}abort:${RESET} install the missing tools above and re-run." >&2
    exit 1
fi
echo -e "${GREEN}ok${RESET}  ${DIM}(mode: ${CYAN}${MODE}${DIM})${RESET}\n"

# ---------------------------------------------------------------------------
# Timing + mode helpers
#
# `time_build` wraps a command in a high-resolution timer and captures
# elapsed seconds on success. We use python3 for the timer because GNU
# date -u +%N isn't available on macOS's date, and `time` builtin
# output is shell-specific. Python's time.monotonic_ns() is everywhere.
#
# On failure we exit the outer script — a framework that can't build
# is louder and more actionable than a silently missing row.
# ---------------------------------------------------------------------------
RESULTS_LINES=()

time_build() {
    local label="$1"; shift
    local t0 t1
    t0=$(python3 -c 'import time; print(time.monotonic_ns())')
    "$@"
    t1=$(python3 -c 'import time; print(time.monotonic_ns())')
    local elapsed_s
    elapsed_s=$(python3 -c "print(round(($t1 - $t0) / 1e9, 2))")
    RESULTS_LINES+=("${label}=${elapsed_s}")
    echo -e "${GREEN}  → done${RESET} ${DIM}(${elapsed_s}s)${RESET}"
}

# Wipe per-framework build outputs but NOT dep caches, so cold builds
# measure from-scratch compile cost, not from-scratch-dependency-install
# cost. Different stories, and the latter is dominated by network.
wipe_if_cold() {
    local label="$1"; shift
    if [[ "$MODE" != "cold" ]]; then return 0; fi
    echo -e "${DIM}  cold wipe: $*${RESET}"
    for path in "$@"; do
        rm -rf "$path"
    done
}

step() {
    local label="$1"
    echo -e "${BOLD}== build: ${label} ==${RESET}"
}

skip() { echo -e "${YELLOW}  → skipped (\$${1}=1)${RESET}"; }

# ---------------------------------------------------------------------------
# Zapp JSC  (fastest, validates zc + native/ up front)
# ---------------------------------------------------------------------------
if [[ "${SKIP_ZAPP_JSC:-}" != "1" ]]; then
    step "zapp-jsc"
    wipe_if_cold zapp-jsc \
        "$APPS/zapp-jsc/.zapp" \
        "$APPS/zapp-jsc/bin" \
        "$APPS/zapp-jsc/dist" \
        "$APPS/zapp-jsc/release"
    time_build "zapp-jsc" bash -c "cd '$APPS/zapp-jsc' && bun install --silent && bun run package"
else
    step "zapp-jsc"; skip SKIP_ZAPP_JSC
fi

# ---------------------------------------------------------------------------
# Zapp txiki
# ---------------------------------------------------------------------------
if [[ "${SKIP_ZAPP_TXIKI:-}" != "1" ]]; then
    step "zapp-txiki"
    wipe_if_cold zapp-txiki \
        "$APPS/zapp-txiki/.zapp" \
        "$APPS/zapp-txiki/bin" \
        "$APPS/zapp-txiki/dist" \
        "$APPS/zapp-txiki/release"
    time_build "zapp-txiki" bash -c "cd '$APPS/zapp-txiki' && bun install --silent && bun run package"
else
    step "zapp-txiki"; skip SKIP_ZAPP_TXIKI
fi

# ---------------------------------------------------------------------------
# Tauri v2 — the Rust release build dominates total time
# ---------------------------------------------------------------------------
if [[ "${SKIP_TAURI:-}" != "1" ]] && [[ -d "$APPS/tauri" ]]; then
    step "tauri"
    wipe_if_cold tauri \
        "$APPS/tauri/src-tauri/target" \
        "$APPS/tauri/dist"
    time_build "tauri" bash -c "cd '$APPS/tauri' && npm install --silent && npm run tauri build"
elif [[ "${SKIP_TAURI:-}" == "1" ]]; then
    step "tauri"; skip SKIP_TAURI
else
    step "tauri"; echo -e "${YELLOW}  → skipped (apps/tauri/ missing)${RESET}"
fi

# ---------------------------------------------------------------------------
# Wails v3
# ---------------------------------------------------------------------------
if [[ "${SKIP_WAILS:-}" != "1" ]] && [[ -d "$APPS/wails" ]]; then
    step "wails"
    # `wails3 task darwin:package` produces an .app bundle; plain
    # `wails3 build` only produces a raw binary (bin/wails).
    #
    # This builds Wails in PRODUCTION mode (i.e. with -tags production,
    # inlining enabled, symbols stripped) — the same configuration a
    # shipped Wails app would have. This is the fair baseline for the
    # size / startup / idle benchmarks.
    #
    # Because Wails v3 stubs openDevTools() to an empty function under
    # the production build tag, this build has NO WAY to reach devtools
    # and therefore can't run the paste-into-console IPC bench. When
    # you're ready to run bridge-bench.js against Wails, rebuild it
    # separately with:
    #
    #     ./scripts/build-wails-devtools.sh
    #
    # That rebuilds with DEV=true (no production tag, so OpenDevTools()
    # actually works) into the same bin/wails.app path. Note that DEV
    # builds disable Go inlining (-gcflags=all=-l), so the Wails binary
    # measured during the IPC bench is very slightly different from the
    # one measured for size / startup / idle. Both numbers are honest;
    # we note the distinction in RESULTS.md.
    wipe_if_cold wails \
        "$APPS/wails/bin" \
        "$APPS/wails/frontend/dist" \
        "$APPS/wails/frontend/bindings"
    time_build "wails" bash -c "cd '$APPS/wails' && wails3 task darwin:package"
elif [[ "${SKIP_WAILS:-}" == "1" ]]; then
    step "wails"; skip SKIP_WAILS
else
    step "wails"; echo -e "${YELLOW}  → skipped (apps/wails/ missing)${RESET}"
fi

# ---------------------------------------------------------------------------
# Electron
# ---------------------------------------------------------------------------
if [[ "${SKIP_ELECTRON:-}" != "1" ]] && [[ -d "$APPS/electron" ]]; then
    step "electron"
    # `npm run package` emits just the .app bundle (via
    # electron-forge package). We intentionally do NOT run `npm run
    # make`, which wraps package + installer makers: our
    # forge.config.js has an empty `makers: []` array because the
    # bench only needs a launchable .app, not a .dmg / .zip / squirrel
    # installer, and `make` with zero makers errors out.
    #
    # Note: electron-forge always rebuilds the bundle in out/, so a
    # "hot" electron build is effectively a cold one — there's no
    # incremental caching at the forge level. The hot/cold distinction
    # is mostly meaningful for the other frameworks.
    wipe_if_cold electron "$APPS/electron/out"
    time_build "electron" bash -c "cd '$APPS/electron' && npm install --silent && npm run package"
elif [[ "${SKIP_ELECTRON:-}" == "1" ]]; then
    step "electron"; skip SKIP_ELECTRON
else
    step "electron"; echo -e "${YELLOW}  → skipped (apps/electron/ missing)${RESET}"
fi

# ---------------------------------------------------------------------------
# Electrobun
# ---------------------------------------------------------------------------
if [[ "${SKIP_ELECTROBUN:-}" != "1" ]] && [[ -d "$APPS/electrobun" ]]; then
    step "electrobun"
    # `build:stable` runs `electrobun build --env=stable`, producing
    # build/stable-macos-arm64/<app>.app. `build:dev` / `build:canary`
    # exist too but the startup/idle benchmarks want a stable profile
    # to match every other framework's release build.
    wipe_if_cold electrobun \
        "$APPS/electrobun/build" \
        "$APPS/electrobun/artifacts"
    time_build "electrobun" bash -c "cd '$APPS/electrobun' && bun install --silent && bun run build:stable"
elif [[ "${SKIP_ELECTROBUN:-}" == "1" ]]; then
    step "electrobun"; skip SKIP_ELECTROBUN
else
    step "electrobun"; echo -e "${YELLOW}  → skipped (apps/electrobun/ missing)${RESET}"
fi

# ---------------------------------------------------------------------------
# Persist timing results to .build-times.json
#
# Structure: { cold: { <label>: seconds }, hot: { <label>: seconds } }
#
# We read the existing file (if any) and merge into the MODE key, so
# running `build-all.sh cold` followed by `build-all.sh hot` leaves both
# sets available for measure-all.sh to emit. Missing frameworks (skipped
# or failed) simply don't appear in this run's map.
#
# RESULTS_LINES is dumped to a temp file rather than expanded into the
# python heredoc so that empty arrays don't trip `set -u`, and so that
# labels containing shell metacharacters can't cause grief later.
# ---------------------------------------------------------------------------
tmp_times=$(mktemp)
trap 'rm -f "$tmp_times"' EXIT
if [[ ${#RESULTS_LINES[@]} -gt 0 ]]; then
    printf '%s\n' "${RESULTS_LINES[@]}" > "$tmp_times"
fi

python3 - "$TIMES_FILE" "$MODE" "$tmp_times" <<'PY'
import json, os, sys, datetime

times_file, mode, tmp_path = sys.argv[1], sys.argv[2], sys.argv[3]

this_run = {}
if os.path.exists(tmp_path):
    for line in open(tmp_path):
        line = line.strip()
        if not line or "=" not in line:
            continue
        label, _, seconds = line.partition("=")
        this_run[label] = float(seconds)

data = {}
if os.path.exists(times_file):
    try:
        data = json.load(open(times_file))
    except Exception:
        data = {}

# Overwrite just this mode's slice; the other mode's last run is preserved.
data[mode] = this_run
data[mode + "_at"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
json.dump(data, open(times_file, "w"), indent=2)

print()
print(f"  build times ({mode}) written to {os.path.relpath(times_file)}")
for label, seconds in this_run.items():
    print(f"    {label:<14} {seconds:>7.2f}s")
PY

echo -e "\n${BOLD}${GREEN}all builds complete${RESET} ${DIM}(${MODE})${RESET}"
