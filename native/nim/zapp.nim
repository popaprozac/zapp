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

import std/json
import app
import window

# CLI-generated config + bootstrap modules. `buildNativeNim` writes these into
# the project's `.zapp/` dir and passes `--path:<.zapp>`, so they resolve by
# name. They provide the `zapp_build_*` getters + `zapp_log_init`
# (zapp_build_config) and `zapp_webview_bootstrap_script` (zapp_bootstrap) as
# {.exportc, cdecl.} — replacing the TEMP stubs that used to live here.
import zapp_build_config, zapp_bootstrap

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
# message receiver). webview.m's didReceiveScriptMessage GATES the bridge on
# `app_get_active() != NULL` (webview.m:376-378): a NULL here means EVERY JS->
# native message (including invokes) is silently dropped before reaching
# zapp_handle_message_from_window. The pointer is opaque to webview.m — it is
# only forwarded straight back to the handler, never dereferenced (verified:
# the only use site is webview.m:376). So a stable non-NULL sentinel is enough
# to open the bridge. Our handler ignores the value.
# TEMP until app.nim exposes a real active App* (Task 5).
var gActiveAppSentinel: int
proc app_get_active(): pointer {.exportc, cdecl.} = addr gActiveAppSentinel

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

# zapp_webview_bootstrap_script is now provided by the generated zapp_bootstrap
# module (imported above) — the real minified webview bridge JS.

# darwin_window_eval_js — defined in the (compiled) window.m. Evaluates a JS
# snippet in the given window's WKWebView on the main thread; it copies `js`
# synchronously, so the caller may free immediately after the call.
proc darwin_window_eval_js(windowId: int32, js: cstring) {.importc, cdecl.}

# Escape a string as the CONTENTS of a JS single-quoted literal. Mirrors
# bridge/dispatch.zc's zapp_escape_dup usage: the payload is interpolated into
#   b._onInvokeResult(<id>,<ok>,'<payload>')
# so backslash, single-quote, and the line terminators must be escaped.
proc escapeJsSingleQuoted(s: string): string =
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '\\': result.add("\\\\")
    of '\'': result.add("\\'")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    else: result.add(c)

# Send an invoke result back to the webview's bridge. Matches the wire shape
# emitted by bridge/dispatch.zc:dispatch_invoke_response so the bootstrap's
# `_onInvokeResult(id, ok, payload)` resolves/rejects the pending promise.
proc dispatchInvokeResponse(windowId: int32, requestId: int, ok: bool,
                            payload: string) =
  let okLit = if ok: "true" else: "false"
  let js = "(function(){var b=globalThis[Symbol.for('zapp.bridge')];" &
           "if(b&&typeof b._onInvokeResult==='function'){" &
           "b._onInvokeResult(" & $requestId & "," & okLit & ",'" &
           escapeJsSingleQuoted(payload) & "');}})();"
  darwin_window_eval_js(windowId, js.cstring)

# zapp_handle_message_from_window — the JS->native message bridge entry point.
# The bootstrap bridge posts JSON envelopes `{t, id, m, a}` (protocol in
# native/bridge/protocol.zc). For sub-gate A we implement the minimum needed
# to RENDER the hello-world UI: the entry module top-level-awaits
# `greet({name:"World"})` (an invoke, t==1) BEFORE it mounts `#app`, so a dead
# bridge => the await never resolves => blank webview. We answer `t==1` invokes
# (the `greet` demo service mirrors native/build.zc's greet_service) and ignore
# every other envelope type. Full routing (emit/window-action/worker/sync, the
# real service registry) is Task 5.
proc zapp_handle_message_from_window(app: pointer, msg: cstring,
                                     windowId: int32) {.exportc, cdecl.} =
  discard app
  if msg == nil: return
  var env: JsonNode
  try:
    env = parseJson($msg)
  except CatchableError:
    return
  if env.kind != JObject: return
  let t = env{"t"}
  if t == nil or t.kind != JInt: return
  if t.getInt() != 1: return            # only invokes need answering for render

  let idNode = env{"id"}
  let mNode = env{"m"}
  if idNode == nil or idNode.kind != JInt: return
  if mNode == nil or mNode.kind != JString: return
  let requestId = idNode.getInt()
  let methodName = mNode.getStr()

  if methodName == "greet":
    # Static result mirrors native/build.zc:greet_service (the zc reference).
    dispatchInvokeResponse(windowId, requestId, true,
                           "{\"greeting\":\"hello from native\"}")
  else:
    dispatchInvokeResponse(windowId, requestId, false, "NOT_FOUND")

# --- Build-time config ------------------------------------------------------
# The `zapp_build_*` getters (initial_url, asset_root, use_embedded_assets,
# is_dev, csp, custom_protocols_json, the webview_* prefs) + `zapp_log_init`
# are now provided by the generated zapp_build_config module (imported above).
# For sub-gate A it emits: initial_url=zapp://index.html, use_embedded_assets=0,
# asset_root=<built web dist> — so webview.m's zapp:// scheme handler serves the
# real hello-world UI off the filesystem.

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
