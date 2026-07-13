## Unified window-event dispatcher — port of native/window/callbacks.zc.
##
## Owns the per-window registries (native callbacks, on-ready, JS/backend
## subscription bitmasks, close guard) and the 3-layer `zapp_dispatch_event`
## the .m window delegate calls on resize/focus/close/etc.
##
## JS delivery itself is delegated to the UNTOUCHED window.m function
## `zapp_dispatch_event_to_js` (importc, gated on the per-window JS-subscription
## bitmask) — Nim owns the registries + the dispatch DECISIONS, not the IIFE
## synthesis. Worker (backend) fan-out is wired (Batch 4 / 87d745a), gated on the
## per-window backend-listener bitmask (set via the zjs subscribeWindowEvent host fn).
##
## Runs on the Cocoa MAIN thread (NSWindow delegate), never a worker pthread —
## normal ORC / allocation is fine here.
##
## Signatures match callbacks.zc EXACTLY so the (later-ported) router.zc /
## window.zc callers link unchanged:
##   zapp_window_set_js_listener(int,int,int)      callbacks.zc:76
##   zapp_window_set_backend_listener(int,int,int) callbacks.zc:34
##   zapp_window_set_close_guard(int,int)          callbacks.zc:49
##   zapp_window_set_event_cb(int,int,fn)          callbacks.zc:69
##   zapp_window_set_on_ready(int,void*,fn)        callbacks.zc:56
##   zapp_window_trigger_on_ready(int)             callbacks.zc:63
##   zapp_dispatch_event(int,int,int,int,int,int)->int  callbacks.zc:94

import events, coretypes, dispatch
import jslit  # jsLit — the ONE safe native->JS string-literal encoder (finding #2, P0)

type
  ## callbacks.zc's event cb is `int(*)(WindowEventData*)`. WindowEventData* is a
  ## plain struct pointer — ABI-identical to a `pointer` here. No native cbs are
  ## registered in Batch 1, so the opaque-pointer form is sufficient.
  WindowEventCb = proc(data: pointer): cint {.cdecl.}
  ReadyCb = proc(id: cint, handle: pointer) {.cdecl.}

var
  gEventCbs: array[ZAPP_MAX_WINDOW_CALLBACKS, array[ZAPP_MAX_WINDOW_EVENT_TYPES, WindowEventCb]]
  gReadyCbs: array[ZAPP_MAX_WINDOW_CALLBACKS, ReadyCb]
  gReadyHandles: array[ZAPP_MAX_WINDOW_CALLBACKS, pointer]
  gJsListeners: array[ZAPP_MAX_WINDOW_CALLBACKS, uint32]
  gBackendListeners: array[ZAPP_MAX_WINDOW_CALLBACKS, uint32]
  gCloseGuard: array[ZAPP_MAX_WINDOW_CALLBACKS, uint32]

template inBounds(id, ev: cint): bool =
  id >= 0 and id < ZAPP_MAX_WINDOW_CALLBACKS and ev >= 0 and ev < ZAPP_MAX_WINDOW_EVENT_TYPES

# --- Registration / subscription (exportc surface) -------------------------

proc zapp_window_set_js_listener*(id, eventId, hasListener: cint) {.exportc, cdecl.} =
  if not inBounds(id, eventId): return
  if hasListener != 0: gJsListeners[id] = gJsListeners[id] or (1'u32 shl eventId.uint32)
  else: gJsListeners[id] = gJsListeners[id] and not (1'u32 shl eventId.uint32)

proc zapp_window_set_backend_listener*(id, eventId, hasListener: cint) {.exportc, cdecl.} =
  if not inBounds(id, eventId): return
  if hasListener != 0: gBackendListeners[id] = gBackendListeners[id] or (1'u32 shl eventId.uint32)
  else: gBackendListeners[id] = gBackendListeners[id] and not (1'u32 shl eventId.uint32)

proc zapp_window_set_close_guard(id, enabled: cint) {.exportc, cdecl.} =
  if id >= 0 and id < ZAPP_MAX_WINDOW_CALLBACKS:
    gCloseGuard[id] = (if enabled != 0: 1'u32 else: 0'u32)

proc zapp_window_set_event_cb(id, eventId: cint, cb: WindowEventCb) {.exportc, cdecl.} =
  if inBounds(id, eventId): gEventCbs[id][eventId] = cb

proc zapp_window_set_on_ready(id: cint, handle: pointer, cb: ReadyCb) {.exportc, cdecl.} =
  if id >= 0 and id < ZAPP_MAX_WINDOW_CALLBACKS:
    gReadyCbs[id] = cb
    gReadyHandles[id] = handle

proc zapp_window_trigger_on_ready(id: cint) {.exportc, cdecl.} =
  if id >= 0 and id < ZAPP_MAX_WINDOW_CALLBACKS and gReadyCbs[id] != nil:
    gReadyCbs[id](id, gReadyHandles[id])

# --- Test/diagnostic helper ------------------------------------------------

proc willDeliverToJs*(id, eventId: cint): bool =
  inBounds(id, eventId) and (gJsListeners[id] and (1'u32 shl eventId.uint32)) != 0

# --- JS delivery (delegated to the untouched window.m) ---------------------
# window.m:214 `void zapp_dispatch_event_to_js(int32_t,...)` — cint == int32.
proc zapp_dispatch_event_to_js(windowId, eventId, w, h, x, y: cint) {.importc, cdecl.}

# --- Unified dispatch ------------------------------------------------------
# Called by the platform window delegate. Mirrors callbacks.zc:94 exactly:
#   Layer 1   native callback (can CANCEL),
#   Layer 1.5 JS close guard (dispatch + CANCEL),
#   Layer 2   targeted JS bridge (gated on the JS-subscription bitmask),
#   Layer 3   backend worker fan-out (gated on the backend-listener bitmask).
proc zapp_dispatch_event*(windowId, eventId, w, h, x, y: cint): cint {.exportc, cdecl.} =
  if not inBounds(windowId, eventId): return EventResult.Allow.cint

  # Layer 1: native callback (none registered in Batch 1).
  let cb = gEventCbs[windowId][eventId]
  if cb != nil:
    let r = cb(nil)
    if r != EventResult.Allow.cint: return r   # CANCEL — stop propagation

  # Layer 1.5: JS close guard. JS decides (force-close via Window.close, or ignore).
  if eventId == weClose.cint and gCloseGuard[windowId] != 0:
    zapp_dispatch_event_to_js(windowId, eventId, 0, 0, 0, 0)
    return EventResult.Cancel.cint

  # Layer 2: targeted JS bridge — only if JS has a listener for this event.
  if (gJsListeners[windowId] and (1'u32 shl eventId.uint32)) != 0:
    zapp_dispatch_event_to_js(windowId, eventId, w, h, x, y)

  # Layer 3: backend worker fan-out — build the window:event IIFE and broadcast
  # to every worker (callbacks.zc:131-136). winPayload is all-integer (no
  # untrusted content) but still routed through jsLit — same as every other
  # native->JS site (finding #2) — so the lint guard needs no exception here.
  if (gBackendListeners[windowId] and (1'u32 shl eventId.uint32)) != 0:
    let winPayload = "{\"windowId\":" & $windowId &
                      ",\"event\":" & $eventId & ",\"w\":" & $w & ",\"h\":" & $h &
                      ",\"x\":" & $x & ",\"y\":" & $y & "}"
    let js = "(function(){var b=globalThis[Symbol.for('zapp.bridge')];" &
             "if(b&&typeof b._onEvent==='function'){" &
             "b._onEvent(" & jsLit("window:event") & "," & jsLit(winPayload) & ");}})();"
    worker_broadcast_eval_js(js.cstring)

  return EventResult.Allow.cint
