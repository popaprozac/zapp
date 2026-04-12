#!/usr/bin/env bash
# ===========================================================================
# Rebuild the Wails bench app with devtools enabled, for the IPC bench only.
#
# Why this exists:
#   Wails v3 ships two sibling files on darwin —
#   webview_window_darwin_production.go (empty openDevTools stub) and
#   webview_window_darwin_dev.go (real impl) — selected at compile time
#   by Go build tags. `wails3 task darwin:package` runs with `-tags
#   production` by default, picking the stub, which makes every path
#   to devtools a compile-time no-op: DevToolsEnabled option,
#   OpenInspectorOnStartup option, win.OpenDevTools() method, context
#   menu Inspect Element — all gone. In a packaged release Wails build,
#   there is literally no user-reachable way to open the inspector.
#
#   Which is a problem, because `bridge-bench.js` is a paste-into-the-
#   devtools-console benchmark. So: for the IPC bench only, we rebuild
#   Wails with DEV=true, which drops the production tag and lets
#   main.go's win.OpenDevTools() call actually do something.
#
# Tradeoff:
#   DEV=true also sets -gcflags=all=-l, which disables Go inlining.
#   The Wails binary measured by the IPC bench is therefore very
#   slightly slower than the production build measured by the size /
#   startup / idle bench. Both numbers are honest; RESULTS.md notes
#   the distinction.
#
# Usage:
#   ./scripts/build-all.sh cold         # fair baseline: production Wails
#   ./scripts/measure-all.sh            # size / startup / idle numbers
#   ./scripts/build-wails-devtools.sh   # rebuild Wails with devtools
#   # launch bin/wails.app, paste bridge-bench.js in devtools, record
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WAILS_DIR="$BENCH_DIR/apps/wails"

BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"

if [[ ! -d "$WAILS_DIR" ]]; then
    echo -e "${RED}error:${RESET} $WAILS_DIR not found" >&2
    exit 1
fi

if ! command -v wails3 >/dev/null 2>&1; then
    echo -e "${RED}error:${RESET} wails3 CLI not on PATH" >&2
    echo "install: go install github.com/wailsapp/wails/v3/cmd/wails3@latest" >&2
    exit 1
fi

echo -e "${BOLD}== rebuild wails with devtools (DEV=true) ==${RESET}"
echo -e "${DIM}  this overwrites bin/wails.app — rerun build-all.sh hot wails${RESET}"
echo -e "${DIM}  afterward to restore the production build for size benchmarks${RESET}"
echo

(cd "$WAILS_DIR" && wails3 generate bindings >/dev/null 2>&1 && wails3 task darwin:package DEV=true)

echo
echo -e "${GREEN}${BOLD}done${RESET} ${DIM}(bin/wails.app now has devtools enabled)${RESET}"
echo
echo "next steps for IPC bench:"
echo "  1. open -a \"$WAILS_DIR/bin/wails.app\""
echo "  2. devtools window should appear automatically"
echo "  3. paste $BENCH_DIR/bridge-bench.js into the console"
echo "  4. record the json: line into RESULTS.md under Wails IPC"
