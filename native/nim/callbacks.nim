## Unified window-event dispatcher — port of native/window/callbacks.zc.
##
## Owns the per-window registries (native callbacks, on-ready, JS/backend
## subscription bitmasks, close guard) and the 3-layer `zapp_dispatch_event`
## the .m window delegate calls on resize/focus/close/etc.
##
## JS delivery itself is delegated to the UNTOUCHED window.m function
## `zapp_dispatch_event_to_js` (importc, gated on the per-window JS-subscription
## bitmask) — Nim owns the registries + the dispatch DECISIONS, not the IIFE
## synthesis. Worker (backend) fan-out is a deferred no-op (Batch 4/7).
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

import events

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

proc zapp_window_set_backend_listener(id, eventId, hasListener: cint) {.exportc, cdecl.} =
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

# Worker (backend) fan-out is deferred to Batch 4/7 — TEMP no-op stub so the
# dispatch DECISION lands now without pulling in the worker supervisor.
proc workerBroadcastEvalJs(js: cstring) = discard

# --- Unified dispatch ------------------------------------------------------
# Called by the platform window delegate. Mirrors callbacks.zc:94 exactly:
#   Layer 1   native callback (can CANCEL),
#   Layer 1.5 JS close guard (dispatch + CANCEL),
#   Layer 2   targeted JS bridge (gated on the JS-subscription bitmask),
#   Layer 3   backend worker fan-out (deferred no-op).
proc zapp_dispatch_event(windowId, eventId, w, h, x, y: cint): cint {.exportc, cdecl.} =
  if not inBounds(windowId, eventId): return EVENT_ALLOW

  # Layer 1: native callback (none registered in Batch 1).
  let cb = gEventCbs[windowId][eventId]
  if cb != nil:
    let r = cb(nil)
    if r != 0: return r          # CANCEL — stop propagation

  # Layer 1.5: JS close guard. JS decides (force-close via Window.close, or ignore).
  if eventId == weClose.cint and gCloseGuard[windowId] != 0:
    zapp_dispatch_event_to_js(windowId, eventId, 0, 0, 0, 0)
    return EVENT_CANCEL

  # Layer 2: targeted JS bridge — only if JS has a listener for this event.
  if (gJsListeners[windowId] and (1'u32 shl eventId.uint32)) != 0:
    zapp_dispatch_event_to_js(windowId, eventId, w, h, x, y)

  # Layer 3: backend worker fan-out — deferred (Batch 4/7).
  if (gBackendListeners[windowId] and (1'u32 shl eventId.uint32)) != 0:
    workerBroadcastEvalJs(cstring"")

  return EVENT_ALLOW
