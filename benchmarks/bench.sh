#!/usr/bin/env bash
# ===========================================================================
# Zapp benchmark runner
#
# Measures one .app bundle: binary size, bundle size, cold startup, idle
# memory. Emits a single-line JSON record to stdout.
#
# Usage:
#   ./bench.sh <app-dir-or-bundle> <label> [runs]
#
# The first argument may be either:
#   - A directory containing exactly one *.app bundle (auto-detected)
#   - A path directly to a *.app bundle
#
# We launch via `open -a <bundle>` rather than exec'ing the Mach-O directly,
# because frameworks like Electron rely on the bundle context (code signing,
# framework load paths, __DATA snapshots) and crash if the stub loader is
# invoked bare. `open` is the portable way to ask macOS to launch an .app
# the way the OS itself would.
# ===========================================================================

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <app-dir-or-bundle> <label> [runs]" >&2
    exit 2
fi

APP_PATH="$1"
LABEL="$2"
RUNS="${3:-15}"
WARMUPS=5

if [[ "$(uname)" != "Darwin" ]]; then
    echo "error: only macOS is supported in this benchmark" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Locate the .app bundle
# ---------------------------------------------------------------------------
if [[ "$APP_PATH" == *.app ]]; then
    BUNDLE="$APP_PATH"
elif [[ -d "$APP_PATH" ]]; then
    found=$(find "$APP_PATH" -maxdepth 2 -name "*.app" -type d 2>/dev/null | head -1)
    if [[ -z "$found" ]]; then
        echo "error: no *.app found under $APP_PATH" >&2
        exit 1
    fi
    BUNDLE="$found"
else
    echo "error: $APP_PATH is not a directory or .app" >&2
    exit 1
fi
BUNDLE="$(cd "$(dirname "$BUNDLE")" && pwd)/$(basename "$BUNDLE")"

if [[ ! -d "$BUNDLE" ]]; then
    echo "error: bundle $BUNDLE does not exist" >&2
    exit 1
fi

BUNDLE_NAME=$(basename "$BUNDLE" .app)

# ---------------------------------------------------------------------------
# Locate the main executable — the "binary" we report the size of.
#
# For simple single-binary frameworks (Zapp, Wails, Tauri) the main
# executable IS the weight. For Electron / Electrobun the Contents/MacOS/<x>
# binary is a small stub loader and the real ~100s of MB live in
# Contents/Frameworks/<name>.framework/Versions/A/<name>. We detect that
# case and report the framework binary size instead, so the "binary" column
# is a fair comparison of the shippable executable weight, not of the stub.
# ---------------------------------------------------------------------------
# Prefer the CFBundleExecutable value from Info.plist — that's the macOS
# canonical answer for "which file in Contents/MacOS is the main binary".
# Fall back to <bundle name> matching, then to first executable if neither.
MAIN_EXEC=""
if [[ -f "$BUNDLE/Contents/Info.plist" ]]; then
    exec_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$BUNDLE/Contents/Info.plist" 2>/dev/null || true)
    if [[ -n "$exec_name" && -x "$BUNDLE/Contents/MacOS/$exec_name" ]]; then
        MAIN_EXEC="$BUNDLE/Contents/MacOS/$exec_name"
    fi
fi
if [[ -z "$MAIN_EXEC" ]] && [[ -x "$BUNDLE/Contents/MacOS/$BUNDLE_NAME" ]]; then
    MAIN_EXEC="$BUNDLE/Contents/MacOS/$BUNDLE_NAME"
fi
if [[ -z "$MAIN_EXEC" ]]; then
    MAIN_EXEC=$(find "$BUNDLE/Contents/MacOS" -type f -perm +111 2>/dev/null | head -1)
fi

BINARY_BYTES=$(stat -f%z "$MAIN_EXEC" 2>/dev/null || echo "0")
BINARY_NOTE="main"

# For Electron-style bundles the loader stub is under ~200 KB. Look for a
# larger framework binary inside Contents/Frameworks/ and use that instead.
if [[ "$BINARY_BYTES" -lt 524288 ]] && [[ -d "$BUNDLE/Contents/Frameworks" ]]; then
    fw_exec=$(find "$BUNDLE/Contents/Frameworks" -type f -perm +111 -size +1M 2>/dev/null \
        | awk '{ cmd="stat -f%z \""$0"\""; cmd | getline sz; close(cmd); print sz"\t"$0 }' \
        | sort -rn | head -1 | cut -f2)
    if [[ -n "$fw_exec" ]]; then
        fw_bytes=$(stat -f%z "$fw_exec" 2>/dev/null || echo "0")
        if [[ "$fw_bytes" -gt "$BINARY_BYTES" ]]; then
            BINARY_BYTES="$fw_bytes"
            BINARY_NOTE="framework"
        fi
    fi
fi

# Electrobun ships a self-extracting bundle: Contents/MacOS/launcher extracts
# a .tar.zst archive in Contents/Resources/ at first launch. The real shipping
# payload is the compressed archive, so report it whenever it is larger than
# the launcher. Detection is structural rather than launcher-size based:
# Electrobun 2's launcher is already larger than the old 512 KB heuristic.
if [[ -d "$BUNDLE/Contents/Resources" ]]; then
    arch_file=$(find "$BUNDLE/Contents/Resources" -maxdepth 1 -name "*.tar.zst" -type f 2>/dev/null \
        | awk '{ cmd="stat -f%z \""$0"\""; cmd | getline sz; close(cmd); print sz"\t"$0 }' \
        | sort -rn | head -1 | cut -f2)
    if [[ -n "$arch_file" ]]; then
        arch_bytes=$(stat -f%z "$arch_file" 2>/dev/null || echo "0")
        if [[ "$arch_bytes" -gt "$BINARY_BYTES" ]]; then
            BINARY_BYTES="$arch_bytes"
            BINARY_NOTE="archive"
        fi
    fi
fi

BUNDLE_KB=$(du -sk "$BUNDLE" | awk '{print $1}')
BUNDLE_BYTES=$(( BUNDLE_KB * 1024 ))

# ---------------------------------------------------------------------------
# App icon size
#
# The shipped icon is part of the bundle weight — and for small apps it can
# dominate. Zapp's iconutil-generated multi-resolution .icns is ~2.4 MB
# (nearly as much as the entire zapp-jsc binary), while Wails ships a
# ~46 KB icon and Electron ships ~272 KB. Reporting this column lets
# readers see the icon contribution separately and understand why a small
# binary can still live in a larger bundle.
#
# We use the largest .icns in Contents/Resources/ — frameworks typically
# ship one primary app icon there.
# ---------------------------------------------------------------------------
ICON_BYTES=0
ICON_PATH=""
if [[ -d "$BUNDLE/Contents/Resources" ]]; then
    ICON_PATH=$(find "$BUNDLE/Contents/Resources" -maxdepth 2 -name "*.icns" -type f 2>/dev/null \
        | awk '{ cmd="stat -f%z \""$0"\""; cmd | getline sz; close(cmd); print sz"\t"$0 }' \
        | sort -rn | head -1 | cut -f2)
    if [[ -n "$ICON_PATH" ]]; then
        ICON_BYTES=$(stat -f%z "$ICON_PATH" 2>/dev/null || echo "0")
    fi
fi

# ---------------------------------------------------------------------------
# Launch helper — uses `open -a` so macOS handles bundle init properly.
# Returns the PID of the launched process (or empty if it couldn't be found).
# ---------------------------------------------------------------------------
launch_and_get_pid() {
    # `open -gj -a <bundle>` launches the app without bringing it forward or
    # into the launch services recent-apps list. -g keeps focus where it is.
    # -n would make a fresh instance every time but also bypasses some
    # caching; we want warm-cache behavior for consistency across runs.
    open -g -a "$BUNDLE" 2>/dev/null || return 1
    # Find the PID by bundle basename — prefer the main process, skip
    # child helpers (Electron spawns renderers named with " Helper").
    local pid=""
    for _ in 1 2 3 4 5; do
        pid=$(pgrep -n -f "$BUNDLE/Contents/MacOS/" 2>/dev/null | head -1)
        [[ -n "$pid" ]] && break
        sleep 0.05
    done
    echo "$pid"
}

kill_pid_tree() {
    local pid="$1"
    [[ -z "$pid" ]] && return 0
    # SIGTERM the launched process and every stray that references the
    # bundle path (catches multi-process frameworks: Electron helpers,
    # Electrobun's launcher + bun child, etc.). `open` makes the app a
    # child of launchd not of this shell, so `wait` can't help — instead
    # we spin briefly until pgrep reports no matching process, so the
    # next launch starts from a truly clean slate. Without this,
    # successive launches pgrep-hit the prior run's still-dying pid and
    # the idle measurement times out against a ghost process.
    kill "$pid" 2>/dev/null || true
    pkill -f "$BUNDLE" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! pgrep -f "$BUNDLE" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
}

# ---------------------------------------------------------------------------
# Startup — median of N runs after warmups.
#
# We measure wall-clock from `open` returning a PID to the PID existing.
# This is a coarse bound (it doesn't wait for first paint) but it's the
# same measurement applied uniformly to every framework, so comparison is
# fair. Each framework pays the same kernel-fork + dyld-load tax and the
# differences that remain are framework-internal init cost.
# ---------------------------------------------------------------------------
measure_one_startup() {
    local start end
    start=$(python3 -c "import time; print(time.monotonic_ns())")
    local pid
    pid=$(launch_and_get_pid)
    end=$(python3 -c "import time; print(time.monotonic_ns())")
    kill_pid_tree "$pid"
    echo $(( (end - start) / 1000 ))
}

# ---------------------------------------------------------------------------
# Prime launch — one untimed run with a generous settle window.
#
# Electrobun ships as a self-extracting bundle: the launcher stub unpacks
# bun + native libraries from a .tar.zst into Contents/MacOS/ on first
# launch. That unpack takes several seconds, and a fast warmup kill aborts
# it mid-way, so a run without a prime leaves every subsequent launch
# still finishing extraction.
#
# Running one prime launch with a 5-second settle gives self-extracting
# frameworks time to complete unpack and reach steady state. Every
# framework pays the same prime cost, so the subsequent warmup +
# measurement phase is comparing fully-initialized state across the board.
#
# This runs after BUNDLE_BYTES is captured, so the shipping weight reported
# in the output is still the pre-launch bundle size, not the post-extract
# weight.
# ---------------------------------------------------------------------------
prime_pid=$(launch_and_get_pid)
sleep 5
kill_pid_tree "$prime_pid"

for _ in $(seq 1 "$WARMUPS"); do
    measure_one_startup >/dev/null
done

times=()
for _ in $(seq 1 "$RUNS"); do
    times+=("$(measure_one_startup)")
done

IFS=$'\n' sorted=($(sort -n <<<"${times[*]}")); unset IFS
mid=$(( RUNS / 2 ))
STARTUP_US="${sorted[$mid]}"
STARTUP_MS=$(( STARTUP_US / 1000 ))

# ---------------------------------------------------------------------------
# Idle memory footprint (macOS `footprint` tool)
#
# Sleep long enough for every framework to finish first-paint and reach a
# steady state. 3 seconds is a comfortable upper bound across all six
# frameworks — every one is measured at the same "fully idle" moment.
#
# Multi-process frameworks (Electrobun has launcher + bun child, Electron
# has main + GPU helper + renderer helpers) need all their processes summed
# to report a fair total. pgrep against the bundle path finds every
# process whose args reference our bundle, and we sum their Footprint
# readings to get the real resident weight of the running app.
# ---------------------------------------------------------------------------
launch_and_get_pid >/dev/null
sleep 3

FOOTPRINT_MB=0
if command -v footprint >/dev/null 2>&1; then
    # Grab every process tied to this bundle and sum their footprints.
    pids=$(pgrep -f "$BUNDLE" 2>/dev/null || true)
    total_mb=0
    for p in $pids; do
        mb=$(footprint "$p" 2>/dev/null \
            | awk '/Footprint:/ { for (i=1;i<=NF;i++) if ($i=="Footprint:") { unit=$(i+2); val=$(i+1); if (unit=="KB") val=val/1024; if (unit=="GB") val=val*1024; print int(val); exit } }' \
            || true)
        if [[ -n "$mb" ]]; then
            total_mb=$(( total_mb + mb ))
        fi
    done
    FOOTPRINT_MB="$total_mb"
fi
if [[ "$FOOTPRINT_MB" == "0" ]]; then
    # Fallback: sum RSS across all bundle-tied processes.
    pids=$(pgrep -f "$BUNDLE" 2>/dev/null || true)
    total_kb=0
    for p in $pids; do
        rss_kb=$(ps -o rss= -p "$p" 2>/dev/null | tr -d ' ' || echo "0")
        total_kb=$(( total_kb + rss_kb ))
    done
    FOOTPRINT_MB=$(( total_kb / 1024 ))
fi

# Cleanup: kill every process tied to this bundle.
pkill -f "$BUNDLE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Emit JSON line
# ---------------------------------------------------------------------------
printf '{"label":"%s","bundle":"%s","binary_bytes":%d,"binary_note":"%s","bundle_bytes":%d,"icon_bytes":%d,"startup_ms":%d,"startup_us":%d,"idle_mb":%d,"runs":%d}\n' \
    "$LABEL" "$BUNDLE" "$BINARY_BYTES" "$BINARY_NOTE" "$BUNDLE_BYTES" "$ICON_BYTES" "$STARTUP_MS" "$STARTUP_US" "$FOOTPRINT_MB" "$RUNS"
