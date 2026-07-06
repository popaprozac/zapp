#!/usr/bin/env bash
#
# build.sh — standalone build for the CEF macOS spike (Task 0).
#
# NOT `zapp build`. This assembles spikes/cef-macos/build/cef-spike.app entirely
# on its own: it compiles the CEF C callback structs + macOS scaffolding + the
# Nim orchestrator via a single `nim c` (main.nim carries the {.compile.} /
# {.passC.} / {.passL.} surface), builds the Helper subprocess executable, and
# lays out the macOS .app bundle CEF requires (framework in Contents/Frameworks,
# five Helper .app bundles, @rpath). The production Nim build is untouched.
#
# Prereqs: `nim` on PATH, and the CEF distribution fetched (fetch-cef.sh).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CEF_ROOT="$HERE/cef_binary"
BUILD="$HERE/build"
APP_NAME="cef-spike"
APP="$BUILD/$APP_NAME.app"
FW_SRC="$CEF_ROOT/Release/Chromium Embedded Framework.framework"
FW_BIN="$FW_SRC/Chromium Embedded Framework"
BUNDLE_ID="dev.zapp.cefspike"

# --- prerequisite checks ---------------------------------------------------
if [ ! -d "$FW_SRC" ]; then
  echo "error: CEF framework not found at:" >&2
  echo "       $FW_SRC" >&2
  echo "       Run:  bash spikes/cef-macos/fetch-cef.sh   (or: ! bash ... )" >&2
  exit 1
fi
if ! command -v nim >/dev/null; then
  echo "error: 'nim' not found on PATH." >&2
  exit 1
fi

echo "[build] cleaning $BUILD"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"

# --- 1. copy the CEF framework into Contents/Frameworks --------------------
echo "[build] copying Chromium Embedded Framework.framework"
ditto "$FW_SRC" "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"

# --- 2. build the Helper subprocess executable (compiled once) -------------
echo "[build] compiling helper (mac_helper.c + scheme_handler.c)"
HELPER_BIN="$BUILD/cef-spike-helper.bin"
# scheme_handler.c is compiled in too (Task 3): mac_helper.c's minimal cef_app_t
# needs cefspike_register_zapp_scheme, since CEF requires the "zapp" custom
# scheme registered identically in EVERY process, including this Helper.
clang -std=c11 -O2 \
  "$HERE/mac_helper.c" \
  "$HERE/scheme_handler.c" \
  -I"$CEF_ROOT" \
  "$FW_BIN" \
  -Wl,-rpath,@executable_path/../../../ \
  -o "$HELPER_BIN"

# The framework's install name is @executable_path/../Frameworks/... which is
# correct for the MAIN exe (at Contents/MacOS) but wrong for a Helper exe (three
# levels deeper, at Frameworks/<name> Helper.app/Contents/MacOS). Rewrite the
# Helper's dependency to @rpath-relative so the rpath above (which resolves to
# the main app's Frameworks/) finds the framework.
install_name_tool -change \
  "@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework" \
  "@rpath/Chromium Embedded Framework.framework/Chromium Embedded Framework" \
  "$HELPER_BIN"

# --- 3. create the five Helper .app bundles --------------------------------
# name-suffix : bundle-id-suffix   (the standard CEF macOS helper variants)
HELPER_VARIANTS=(
  "::"
  " (Alerts):.alerts"
  " (GPU):.gpu"
  " (Plugin):.plugin"
  " (Renderer):.renderer"
)
for variant in "${HELPER_VARIANTS[@]}"; do
  name_suffix="${variant%%:*}"
  id_suffix="${variant##*:}"
  helper_name="$APP_NAME Helper$name_suffix"
  helper_app="$APP/Contents/Frameworks/$helper_name.app"
  echo "[build] helper bundle: $helper_name.app"
  mkdir -p "$helper_app/Contents/MacOS"
  cp "$HELPER_BIN" "$helper_app/Contents/MacOS/$helper_name"
  chmod +x "$helper_app/Contents/MacOS/$helper_name"
  cat > "$helper_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$helper_name</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.helper$id_suffix</string>
  <key>CFBundleName</key><string>$helper_name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
done
rm -f "$HELPER_BIN"

# --- 4. build the main app via nim c (main.nim owns compile/link surface) ---
echo "[build] compiling main app (nim c main.nim)"
nim c \
  --mm:orc \
  -d:release \
  --hints:off \
  --nimcache:"$BUILD/nimcache" \
  -d:cefRoot:"$CEF_ROOT" \
  --out:"$APP/Contents/MacOS/$APP_NAME" \
  "$HERE/main.nim"

# --- 5. main app Info.plist -----------------------------------------------
echo "[build] writing main Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>CEF Spike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# --- 6. diagnostics + freshness -------------------------------------------
MAIN_BIN="$APP/Contents/MacOS/$APP_NAME"
echo
echo "[build] link check (main exe framework dependency + rpaths):"
otool -L "$MAIN_BIN" | grep -i "Chromium Embedded Framework" || true
otool -l "$MAIN_BIN" | awk '/LC_RPATH/{f=1} f&&/path /{print "  rpath:",$2; f=0}'
echo
echo "[build] complete: $APP"
echo "[build] main binary mtime:"
stat -f "  %N  %Sm" -t "%Y-%m-%d %H:%M:%S" "$MAIN_BIN"
echo
echo "[build] launch with:  open \"$APP\"   (or: \"$MAIN_BIN\" for console logs)"
