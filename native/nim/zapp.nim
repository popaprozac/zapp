## Nim build root. Compiles the untouched darwin platform layer, links the
## frameworks it needs, satisfies the cross-module C-ABI callbacks the .m files
## reach out to, and boots the app with a single window.
##
## The darwin .m files (`native/platform/darwin/*.m`) are REUSED UNTOUCHED.
## platform.m / window.m / webview.m / screen.m / panel.m reach OUT to symbols
## that live in modules not yet ported (app.zc, service.zc, toolbar/sidebar/
## inspector/popover.m, the CLI-generated build-config + embedded-assets). For
## this walking-skeleton boot we satisfy each with a Nim {.exportc, cdecl.} stub
## (NOT {.emit.} — Nim is the host language now). Each is marked TEMP with the
## task/module that makes it real (4b = assets/config/bootstrap, Task 5 = bridge).
{.passL: "-framework Cocoa -framework WebKit -framework CoreFoundation -framework JavaScriptCore -framework Security -framework IOKit -framework ServiceManagement".}
# NOTE the CALL form `{.compile(file, flags).}` — the THIRD arg is per-file
# clang flags. The TUPLE form `{.compile: (file, dest).}` treats the 2nd elem
# as the OUTPUT OBJECT NAME, so "-fobjc-arc" would (a) drop ARC and (b) make
# every .m write to the same object and clobber each other. window.m's weak
# WKWebView properties REQUIRE ARC.
{.compile("../platform/darwin/platform.m", "-fobjc-arc").}
{.compile("../platform/darwin/window.m", "-fobjc-arc").}
{.compile("../platform/darwin/webview.m", "-fobjc-arc").}
{.compile("../platform/darwin/screen.m", "-fobjc-arc").}
{.compile("../platform/darwin/panel.m", "-fobjc-arc").}

import app
import window

# ---------------------------------------------------------------------------
# platform.m callback dependencies (defined in not-yet-ported modules)
# ---------------------------------------------------------------------------

# zapp_app_dispatch — was app/app_events.zc. Fans an app event out to native
# callbacks + workers; returns the count fired. No subscribers yet, so 0.
# TEMP until the event/dispatch layer lands.
proc zapp_app_dispatch(eventId: cint, data: cstring): cint {.exportc, cdecl.} =
  discard eventId
  discard data
  0

# service_run_shutdown_all — was service/service.zc. Tears down services in
# reverse order at quit. No services yet. TEMP until service.nim.
proc service_run_shutdown_all() {.exportc, cdecl.} =
  discard

# darwin_notification_setup_delegate — defined in notification.m; platform.m
# calls it on launch to install the UN delegate. Not compiling notification.m
# yet. TEMP until the notification layer lands.
proc darwin_notification_setup_delegate() {.exportc, cdecl.} =
  discard

# ---------------------------------------------------------------------------
# window.m callback dependencies for split/toolbar/popover features. The
# skeleton never sets sidebar/inspector/toolbar URLs, so window.m's runtime
# guards keep these unreached — but they must still LINK. Real defs live in
# sidebar.m / inspector.m / toolbar.m / popover.m (not compiled here).
# TEMP until those native-chrome modules are ported.
# ---------------------------------------------------------------------------

proc zapp_sidebar_register(windowPtr, splitVC, sidebarItem: pointer,
                           hostId, sidebarSlotId: int32) {.exportc, cdecl.} =
  discard

proc zapp_sidebar_unregister(windowPtr: pointer) {.exportc, cdecl.} =
  discard

proc zapp_inspector_register(windowPtr, splitVC, inspectorItem: pointer,
                             hostId, inspectorSlotId: int32) {.exportc, cdecl.} =
  discard

proc zapp_inspector_unregister(windowPtr: pointer) {.exportc, cdecl.} =
  discard

proc darwin_toolbar_attach(windowPtr: pointer, toolbarJson: cstring,
                           windowNumericId: int32) {.exportc, cdecl.} =
  discard

proc zapp_toolbar_unregister(windowPtr: pointer) {.exportc, cdecl.} =
  discard

proc zapp_toolbar_inject_metrics(windowPtr: pointer, hostSlot: int32,
                                 addUserScript: bool) {.exportc, cdecl.} =
  discard

proc zapp_popover_unregister_window(windowPtr: pointer) {.exportc, cdecl.} =
  discard

# zapp_dispatch_event — window.m asks the event layer whether a window action
# (close/resize/move) is allowed; 0 = ALLOW. Real impl gates reversible-close
# etc. TEMP (returns ALLOW) until the event/dispatch layer lands.
proc zapp_dispatch_event(windowId, eventId, w, h, x, y: cint): cint {.exportc, cdecl.} =
  0

# ---------------------------------------------------------------------------
# webview.m callback dependencies — app config, build config, bootstrap,
# service/permissions manifests, the message bridge, and the embedded-asset
# table. All STUBBED for 4a; web content/asset loading is task 4b and the
# message bridge is Task 5. Every JSON/string getter is guarded for "" in
# webview.m, so empty values take the safe no-feature path.
# ---------------------------------------------------------------------------

# app_get_active — app.zc returned the active App* (passed to the bridge as the
# message receiver). No App* yet; NULL is fine — the bridge stub ignores it.
# TEMP until app.nim exposes the active app pointer (Task 5).
proc app_get_active(): pointer {.exportc, cdecl.} = nil

# app_get_bootstrap_* — app.zc/AppConfig accessors. Reasonable skeleton values.
# TEMP until app config is ported.
let gBootstrapName = "Zapp Nim Skeleton"
proc app_get_bootstrap_name(): cstring {.exportc, cdecl.} = gBootstrapName.cstring
proc app_get_bootstrap_web_content_inspectable(): bool {.exportc, cdecl.} = true
proc app_get_bootstrap_application_should_terminate_after_last_window_closed(): bool {.exportc, cdecl.} = true
proc app_get_bootstrap_max_workers(): cint {.exportc, cdecl.} = 0

# app_get_allowed_navigation_json — extra navigation allowlist (JSON array).
# "" => webview.m falls back to the empty allowlist. TEMP until app config.
proc app_get_allowed_navigation_json(): cstring {.exportc, cdecl.} = "".cstring

# service_get_manifest_json — service bindings manifest (JSON array). Empty set.
# TEMP until service.nim (Task 5 territory).
let gServiceManifest = "[]"
proc service_get_manifest_json(): cstring {.exportc, cdecl.} = gServiceManifest.cstring

# permissions_bootstrap_json — permissions manifest. "" => webview.m uses its
# inactive-permissions default. TEMP until the permissions layer is ported.
proc permissions_bootstrap_json(): cstring {.exportc, cdecl.} = "".cstring

# zapp_webview_bootstrap_script — the runtime bootstrap (generated from TS).
# "" => no bootstrap user script injected (blank webview is the 4a milestone).
# TEMP until 4b wires the generated bootstrap.
proc zapp_webview_bootstrap_script(): cstring {.exportc, cdecl.} = "".cstring

# zapp_handle_message_from_window — the JS->native message bridge entry point.
# TEMP no-op until the bridge lands (Task 5).
proc zapp_handle_message_from_window(app: pointer, msg: cstring,
                                     windowId: int32) {.exportc, cdecl.} =
  discard

# --- Build-time config (CLI-generated zapp_build_config in real builds) ------
# All TEMP until 4b generates them. initial_url points at the canonical asset
# entry; with use_embedded_assets=0 + empty asset table, the zapp:// scheme
# handler finds nothing and serves a graceful 404 (blank page) — exactly the
# 4a "window appears, content is next" milestone.
let gBuildInitialUrl = "zapp://index.html"
proc zapp_build_initial_url(): cstring {.exportc, cdecl.} = gBuildInitialUrl.cstring
proc zapp_build_asset_root(): cstring {.exportc, cdecl.} = "".cstring
proc zapp_build_csp(): cstring {.exportc, cdecl.} = "".cstring
proc zapp_build_custom_protocols_json(): cstring {.exportc, cdecl.} = "".cstring
proc zapp_build_use_embedded_assets(): cint {.exportc, cdecl.} = 0
proc zapp_build_is_dev(): cint {.exportc, cdecl.} = 0
proc zapp_build_webview_autoplay_without_user_gesture(): cint {.exportc, cdecl.} = 0
proc zapp_build_webview_text_interaction_enabled(): cint {.exportc, cdecl.} = 0
proc zapp_build_webview_minimum_font_size(): cint {.exportc, cdecl.} = 0
proc zapp_build_webview_back_forward_gestures(): cint {.exportc, cdecl.} = 0

# --- Embedded asset table (CLI-generated in real builds) --------------------
# webview.m's scheme handler loops `for (i = 0; i < zapp_embedded_assets_count;
# i++)`. We export an EMPTY set: count 0 + a 1-element layout-matched dummy
# array (a zero-length C array is awkward to export cleanly; count 0 means the
# array is never read). The object mirrors ZappEmbeddedAsset exactly:
#   { const char* path; uint8_t* data; int len; int uncompressed_len; int is_brotli; }
# (authoritative layout: cli/src/assets.ts / native/platform/ios/webview.m).
# TEMP until 4b emits the real table.
type ZappEmbeddedAsset {.exportc, bycopy.} = object
  path: cstring
  data: ptr uint8
  len: cint
  uncompressed_len: cint
  is_brotli: cint

var zapp_embedded_assets {.exportc.}: array[1, ZappEmbeddedAsset]
var zapp_embedded_assets_count {.exportc.}: cint = 0

# ---------------------------------------------------------------------------
# Boot: open one window, then enter the Cocoa run loop.
# ---------------------------------------------------------------------------
let a = newApp("Zapp Nim Skeleton")
let opts = newWindowOptions("Zapp v2 (Nim)")
opts.width = 900
opts.height = 650
discard createWindow(opts)
quit(a.run())
