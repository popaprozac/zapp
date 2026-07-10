## App-level event dispatcher — port of native/app/app_events.zc.
##
## Owns the app-event native-callback registry and the 3-layer
## `zapp_app_dispatch` the UNTOUCHED platform layer (.m) calls on app
## lifecycle events (theme-change / app-activate / reopen / open-url / sleep /
## wake / screen-lock / power-state / etc.).
##
##   Layer 1  native Zen-C/Nim app callbacks (registered via zapp_app_on),
##   Layer 2  broadcast to every active worker (wired Batch 4 / 87d745a),
##   Layer 3  forward to all WebViews via the UNTOUCHED webview.m
##            `darwin_webview_eval_all` (importc) with the `_onEvent` IIFE,
##            skipping STARTED(100)/SHUTDOWN(101) (no WebViews exist yet/anymore).
##
## Runs on the Cocoa MAIN thread — normal ORC / allocation is fine here.
##
## Signatures match app_events.zc EXACTLY so the (untouched) .m callers and the
## later-ported registrars link unchanged:
##   zapp_app_on(int, void(*)(int,const char*))   app_events.zc:28
##   zapp_app_dispatch(int, const char*) -> int    app_events.zc:42
##
## The Layer-3 IIFE string, the 104..116 JS-name map, and the STARTED/SHUTDOWN
## skip-list BYTE-MATCH app_events.zc — they are the wire contract. The `'%s'`
## data interpolation in the .zc is an UNESCAPED passthrough, so `$data` here
## matches it (no extra escaping the source doesn't have).

import events, dispatch  # events: aeStarted/aeShutdown skip-list; dispatch: worker_broadcast_eval_js + nativeWebviewEvalAll
import nativeabi

const
  ZAPP_APP_EVENT_BASE = 100
  ZAPP_MAX_APP_EVENT_TYPES = 16   # app_events.zc:11
  ZAPP_MAX_APP_CALLBACKS = 8      # app_events.zc:14

type AppEventCb = proc(eventId: cint, data: cstring) {.cdecl.}

# zapp_app_event_cbs[event_idx][slot] — keyed by (event_id - 100), app_events.zc:25.
var gAppCbs: array[ZAPP_MAX_APP_EVENT_TYPES, array[ZAPP_MAX_APP_CALLBACKS, AppEventCb]]

# --- Registration (exportc surface) ----------------------------------------
# app_events.zc:28 — appends into the first free slot for this event index.
proc zapp_app_on(eventId: cint, cb: AppEventCb) {.exportc, cdecl.} =
  let idx = eventId - ZAPP_APP_EVENT_BASE
  if idx < 0 or idx >= ZAPP_MAX_APP_EVENT_TYPES: return
  for i in 0 ..< ZAPP_MAX_APP_CALLBACKS:
    if gAppCbs[idx][i] == nil:
      gAppCbs[idx][i] = cb
      return

# --- JS delivery -----------------------------------------------------------
# worker_broadcast_eval_js comes from the imported dispatch module (exportc,
# Nim-visible). darwin_webview_eval_all (webview.m:1204) is importc-only there
# (not Nim-exported), so re-declare it here for the Layer-3 call by Nim name —
# both decls resolve to the same C symbol, so the link is unaffected.
proc nativeWebviewEvalAll(js: cstring) {.importc: abiPrefix & "webview_eval_all", cdecl.}

## EXACT map copied from app_events.zc:88-102 Layer-3 switch.
## Events outside this set (incl. 100/101/102/103) produce no WebView forward.
proc appEventJsName(eventId: cint): string =
  case eventId
  of 104: "app:reopen"
  of 105: "app:open-url"
  of 106: "app:active"
  of 107: "app:inactive"
  of 108: "app:theme-changed"
  of 109: "app:will-sleep"
  of 110: "app:did-wake"
  of 111: "app:screen-locked"
  of 112: "app:screen-unlocked"
  of 113: "app:before-quit"
  of 114: "app:power-state-changed"
  of 115: "app:battery-level-changed"
  of 116: "app:screens-changed"
  else: ""

# --- Unified app dispatch --------------------------------------------------
# Called by the platform layer (.m). Mirrors app_events.zc:42 exactly:
#   Layer 1  native callbacks (returns the count fired),
#   Layer 2  worker broadcast (wired Batch 4 / 87d745a),
#   Layer 3  WebView fan-out (skip STARTED/SHUTDOWN; gated on the name map).
proc zapp_app_dispatch(eventId: cint, data: cstring): cint {.exportc, cdecl.} =
  let idx = eventId - ZAPP_APP_EVENT_BASE
  if idx < 0 or idx >= ZAPP_MAX_APP_EVENT_TYPES: return 0

  # Layer 1: native Zen-C/Nim callbacks.
  var fired: cint = 0
  for i in 0 ..< ZAPP_MAX_APP_CALLBACKS:
    if gAppCbs[idx][i] != nil:
      gAppCbs[idx][i](eventId, data)
      inc fired

  # Layer 2: broadcast to every worker via _dispatchAppEvent (app_events.zc:59-64).
  block:
    let safeData = (if data.isNil: "" else: $data)
    let wjs = "(function(){var b=self.__zappBridge||globalThis.__zappBridge;" &
              "if(b&&b._dispatchAppEvent)b._dispatchAppEvent(" & $eventId &
              ",'" & safeData & "');})();"
    worker_broadcast_eval_js(wjs.cstring)

  # Layer 3: forward to all WebViews, skipping STARTED/SHUTDOWN.
  if eventId != aeStarted.cint and eventId != aeShutdown.cint:
    let name = appEventJsName(eventId)
    if name.len > 0:
      # app_events.zc:104 — safe_data defaults to "{}" for the WebView layer
      # (Layer 2 uses ""), and is interpolated UNESCAPED (passthrough).
      let safe = (if data.isNil: "{}" else: $data)
      let js = "(function(){var b=globalThis[Symbol.for('zapp.bridge')];" &
               "if(b&&b._onEvent)b._onEvent('" & name & "','" & safe & "');})();"
      nativeWebviewEvalAll(js.cstring)

  return fired
