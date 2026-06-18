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
{.passL: "-framework Cocoa -framework WebKit -framework CoreFoundation -framework JavaScriptCore -framework Security -framework IOKit -framework ServiceManagement -framework UserNotifications -framework Carbon".}
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
{.compile("../platform/darwin/fs.m", "-fobjc-arc").}
{.compile("../platform/darwin/dialog.m", "-fobjc-arc").}
{.compile("../platform/darwin/notification.m", "-fobjc-arc").}
{.compile("../platform/darwin/shortcuts.m", "-fobjc-arc").}
{.compile("../platform/darwin/menu.m", "-fobjc-arc").}
{.compile("../platform/darwin/tray.m", "-fobjc-arc").}
{.compile("../platform/darwin/dock.m", "-fobjc-arc").}
{.compile("../platform/darwin/sidebar.m", "-fobjc-arc").}
{.compile("../platform/darwin/inspector.m", "-fobjc-arc").}
{.compile("../platform/darwin/toolbar.m", "-fobjc-arc").}
{.compile("../platform/darwin/popover.m", "-fobjc-arc").}
{.compile("../platform/darwin/sync.m", "-fobjc-arc").}

import std/os          # parentDir for the zjs.c {.compile.}/{.passL.} paths below
import std/json        # re-exported below (`export json`) for app.nim's JsonNode service handlers
import app
import window
# service/appconfig/coretypes are imported here so `import zapp` can re-export
# the app-facing surface below (registerService/ServiceHandler/LifecycleHook,
# AppConfig/Inspectable, TriState). app.nim pulls them transitively, but an
# explicit import keeps the `export` list self-contained + the names in scope.
import service
import appconfig
import coretypes
# worker_service provides the {.exportc.} side-effect symbol service_invoke_native
# (the zjs worker→native seam zjs.c calls) and registerWorkerServices() (called
# from app.nim's run() before the workers spawn). No Nim symbol from it is
# referenced in THIS module, so silence UnusedImport.
{.push warning[UnusedImport]: off.}
import worker_service
# callbacks provides the {.exportc.} window-event dispatcher + registries
# (zapp_dispatch_event, zapp_window_set_js_listener, close guard, on-ready, …)
# the .m window delegate + router call. app_events provides the {.exportc.}
# app-event dispatcher + registry (zapp_app_dispatch, zapp_app_on) the platform
# .m layer calls. Neither references a Nim symbol here — imported only for their
# {.exportc.} side-effect symbols.
import callbacks
import app_events
# registry provides the {.exportc.} worker-registry surface (list_json, display
# name, fmt_compact_ms, the supervisor record_failure/get_window_state + the
# add/get/set/remove/owner functions zjs.c / bare.c / the router call by C name).
# POD + {.gcsafe.} (read + supervisor-written from worker pthreads). No Nim symbol
# from it is referenced here — imported only for its {.exportc.} side-effect
# symbols. Replaces the former 5 registry stubs below.
import registry
# worker provides the {.exportc.} worker engine dispatcher (worker_create /
# worker_post_message / worker_terminate / worker_terminate_owner) + the worker→
# webview delivery (worker_dispatch_to_webview). gcsafe + libc — zjs.c calls
# worker_dispatch_to_webview / worker_post_message (possibly on a worker pthread)
# by C name. No Nim symbol from it is referenced here — imported only for its
# {.exportc.} side-effect symbols. Replaces the worker_post_message +
# worker_dispatch_to_webview stubs below.
import worker
{.pop.}

# CLI-generated config + bootstrap modules. `buildNativeNim` writes these into
# the project's `.zapp/` dir and passes `--path:<.zapp>`, so they resolve by
# name. They provide the `zapp_build_*` getters + `zapp_log_init`
# (zapp_build_config) and `zapp_webview_bootstrap_script` (zapp_bootstrap) as
# {.exportc, cdecl.} — replacing the TEMP stubs that used to live here.
# Imported only for their {.exportc.} side-effect symbols (no Nim symbols are
# referenced here), so silence UnusedImport — keeps the warning channel clean
# for real unused imports as the module set grows in breadth.
{.push warning[UnusedImport]: off.}
import zapp_build_config, zapp_bootstrap
{.pop.}

# Re-export the app-facing surface so an app's `app.nim` gets everything via
# `import zapp` (newApp/run, AppConfig, WindowOptions/newWindowOptions/createWindow,
# registerService, TriState, JsonNode).
export app          # newApp, run, App, registerSkeletonServices
export window       # WindowOptions, newWindowOptions, createWindow, windowOptsApplyJson
export service      # registerService, ServiceHandler, LifecycleHook
export appconfig    # AppConfig, Inspectable
export coretypes    # TriState, etc.
export json         # JsonNode for service handlers

# ---------------------------------------------------------------------------
# platform.m callback dependencies (defined in not-yet-ported modules)
# ---------------------------------------------------------------------------

# zapp_app_dispatch + zapp_app_on now live in app_events.nim (imported above),
# ported from native/app/app_events.zc. The dispatcher fans an app event out to
# native callbacks + the webview (via webview.m's darwin_webview_eval_all);
# worker fan-out is a deferred no-op (Batch 4/7).

# ---------------------------------------------------------------------------
# window.m's split/toolbar/popover features link against sidebar.m / inspector.m
# / toolbar.m / popover.m (compiled in the {.compile.} block above), so the real
# zapp_sidebar_*/zapp_inspector_*/darwin_toolbar_attach/zapp_toolbar_*/
# zapp_popover_unregister_window defs are provided there now (the former TEMP
# stubs are gone).
# ---------------------------------------------------------------------------

# zapp_dispatch_event + the window-event registries (set_js_listener, close
# guard, on-ready, etc.) now live in callbacks.nim (imported above), ported from
# native/window/callbacks.zc. JS delivery delegates to window.m's
# zapp_dispatch_event_to_js; worker fan-out is a deferred no-op (Batch 4/7).

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
# to open the bridge. The Nim handler (app.nim) ignores the value, so the
# sentinel stays — a real active App* would only matter once the App value is
# threaded through the bridge (not needed by the router/service skeleton).
var gActiveAppSentinel: int
proc app_get_active(): pointer {.exportc, cdecl.} = addr gActiveAppSentinel

# app_get_bootstrap_* + app_get_allowed_navigation_json now live in
# appconfig.nim (imported transitively via app.nim), reading the real AppConfig
# stored at newApp. The former skeleton stubs are gone.

# zapp_webview_bootstrap_script is now provided by the generated zapp_bootstrap
# module (imported above) — the real minified webview bridge JS.

# The JS<->native message bridge now lives in dedicated modules:
#   bridge.nim  — envelope parse + wire-identical sendInvokeResponse
#   service.nim — the Table-backed service registry
#   router.nim  — INVOKE dispatch (with the Task 6 clipboard seam)
#   app.nim     — registers greet + owns zapp_handle_message_from_window
# zapp.nim no longer defines the handler (one definition only, in app.nim).

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
# zjs worker engine (native/worker/engines/zjs.c — REUSED UNTOUCHED).
#
# Compiled into the Nim build to benchmark the worker→native fast path. zjs.c
# builds/reads JsonValue trees via the JsonValue C-ABI provided by
# .zapp/zjson_provider.o (linked through `--passL:<...>/zjson_provider.o`, which
# buildNativeNim appends to the `nim c` args — the path is the USER project's
# .zapp dir, unknown at framework-compile time, so it can't be a {.passL.}
# literal here). zjs's runtime is libzjs.dylib (vendor/zjs/build).
#
# CALL-form {.compile.} (third arg = per-file clang flags). zjs.c needs zjs's
# own header (vendor/zjs/include/zjs.h) — passed both as a {.passC.} (so other
# Nim-emitted C sees it if needed) and inline in the compile flags.
# ---------------------------------------------------------------------------
# currentSourcePath().parentDir resolves the framework's native/nim dir at
# compile time (parentDir comes from `import std/os` above); vendor/zjs is two
# levels up. Matches the path style of the platform-.m pragmas at the top.
{.passC: "-I" & currentSourcePath().parentDir & "/../../vendor/zjs/include".}
{.compile("../worker/engines/zjs.c",
          "-I" & currentSourcePath().parentDir & "/../../vendor/zjs/include").}
{.passL: "-framework Foundation".}
{.passL: "-lcompression".}  # zjs.c:1208 compression_decode_buffer (embedded-asset decode)
{.passL: currentSourcePath().parentDir & "/../../vendor/zjs/build/libzjs.dylib".}
{.passL: "-Wl,-rpath," & currentSourcePath().parentDir & "/../../vendor/zjs/build".}

# zjs.c extern surface NOT satisfied by the provider .o / worker_service /
# skeleton. Real impls live in not-yet-ported modules (permissions, the
# event/dispatch layer, the worker supervisor + registry, bridge/dispatch.zc).
# TEMP no-op/default stubs for the perf gate — breadth replaces. Signatures
# match zjs.c's `extern` decls EXACTLY (see native/worker/engines/zjs.c:102-142,
# 1304). app_get_active + service_invoke_native + the JsonValue/build-config
# symbols are provided elsewhere (skeleton sentinel / worker_service / provider.o
# / generated zapp_build_config) and are deliberately NOT redefined here.
#
# zapp_log_level: framework log level (0=default,1=verbose,2=debug). zjs.c gates
# its verbose worker-lifecycle lines on `>= 1`; 0 keeps the default-quiet path.
var zapp_log_level {.exportc.}: cint = 0

# dispatch_event_to_all + zapp_escape_dup now live in dispatch.nim (the real
# escaping broadcast helpers), imported transitively via callbacks/app_events.

# worker_post_message (worker→worker dispatch) + worker_dispatch_to_webview
# (worker→webview delivery) now live in worker.nim (imported above) — the
# faithful gcsafe/libc port of worker.zc's dispatcher + app.zc's
# worker_dispatch_to_webview/window. The former 2 no-op stubs are gone.

# Worker-context bootstrap JS (the worker-side bridge: invokeSync, postMessage,
# console) is now provided by the generated zapp_bootstrap module (imported
# above) as zapp_worker_bootstrap_script — the real minified bridge JS bundled
# from bootstrap/worker.ts. zjs.c evals it after installing the native
# __zappBridge, so the bench worker's invokeService resolves.

# Worker supervisor (restart policy + window state) + worker registry
# (Workers.list() JSON, per-worker log labels, fmt_compact_ms) are now provided
# by registry.nim (imported above) — the faithful POD/gcsafe port of
# native/worker/registry.zc. The former 5 stubs (list_json→"[]", display_name→"",
# fmt_compact_ms→"", record_failure→0, get_window_state→0) are gone.

# No boot here. An app's own `zapp/app.nim` is the REQUIRED Nim entry — the CLI
# compiles it as the build root (and errors if it's absent). zapp.nim is purely
# the importable framework umbrella (the exports above). This mirrors the zc
# build, where `app.zc` is likewise required (no skeleton fallback).
