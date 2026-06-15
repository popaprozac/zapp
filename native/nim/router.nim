## Message router: decode the envelope, dispatch INVOKE (t==1) to the service
## registry, and answer over the webview bridge. The non-INVOKE envelope types
## (emit / window-action / worker / sync) are framework breadth not exercised by
## the walking skeleton — they fall through silently for now.
import std/[options, json, strutils]
import bridge, service, clipboard, callbacks, events

# Bridge-ready signal: the webview posts {t:4,m:"ready"} once its bootstrap bridge
# is up (bootstrap/webview.ts). The .m window delegate defers the FIRST focus
# event (window.m:384 — window becomes key before the bridge is ready →
# pendingFocusEvent) and only flushes it when darwin_window_set_bridge_ready
# fires (window.m:550-554). So without routing "ready", window:focus is stuck
# deferred forever (every other window event dispatches unconditionally).
proc darwin_window_id_string(numericId: int32): cstring {.importc, cdecl.}
proc darwin_window_set_bridge_ready(windowId: cstring) {.importc, cdecl.}
proc zapp_window_trigger_on_ready(id: int32) {.importc, cdecl.}  # def in callbacks.nim

proc routeClipboard(m: string, a: JsonNode, windowId, id: int) =
  ## Handle a `__clipboard:*` INVOKE natively (NOT via the service registry),
  ## mirroring native/app/router.zc:router_handle_clipboard. Arg keys match the
  ## runtime (runtime/clipboard.ts) + the zc reference: writeText reads "text",
  ## writeHtml reads "html", has reads "format", writeImagePng reads "data".
  ##
  ## Payload contract (consumed by bootstrap/webview.ts:_onInvokeResult →
  ## JSON.parse): text/html reads -> a JSON STRING literal of the content (via
  ## `$ % str`, correctly escaped); readFiles -> the JSON array string verbatim;
  ## has -> JSON bool; writes/clear -> "null" (the runtime ignores it). An
  ## unhandled `__clipboard:*` method rejects with the bare token (no JSON quotes
  ## — webview.ts does `new Error(payload)`), matching the zc UNKNOWN_CLIPBOARD.
  let args = if a.isNil: newJObject() else: a
  case m
  of "__clipboard:readText":
    sendInvokeResponse(windowId, id, true, $(%clipboard.readText()))
  of "__clipboard:readHtml":
    sendInvokeResponse(windowId, id, true, $(%clipboard.readHtml()))
  of "__clipboard:readFiles":
    sendInvokeResponse(windowId, id, true, clipboard.readFiles())
  of "__clipboard:readImagePng":
    # base64 PNG as a JSON string ("" => runtime treats as null / no image).
    sendInvokeResponse(windowId, id, true, $(%clipboard.readImagePngB64()))
  of "__clipboard:writeImagePng":
    # arg key is "data" (runtime/clipboard.ts writeImage sends { data }), NOT b64.
    discard clipboard.writeImagePngB64(args{"data"}.getStr(""))
    sendInvokeResponse(windowId, id, true, "null")
  of "__clipboard:has":
    let ok = clipboard.has(args{"format"}.getStr(""))
    sendInvokeResponse(windowId, id, true, (if ok: "true" else: "false"))
  of "__clipboard:writeText":
    discard clipboard.writeText(args{"text"}.getStr(""))
    sendInvokeResponse(windowId, id, true, "null")
  of "__clipboard:writeHtml":
    discard clipboard.writeHtml(args{"html"}.getStr(""))
    sendInvokeResponse(windowId, id, true, "null")
  of "__clipboard:clear":
    clipboard.clear()
    sendInvokeResponse(windowId, id, true, "null")
  else:
    sendInvokeResponse(windowId, id, false, "UNKNOWN_CLIPBOARD")

proc routeMessage*(msg: string, windowId: int) =
  ## Entry point for a single webview->native message. Owns parse + dispatch +
  ## response so app.nim's C-ABI handler stays a thin shim.
  let parsed = parseBridge(msg)
  if parsed.isNone: return
  let f = parsed.get

  # t:4 window-action — Batch 1 handles ONLY subscribe/unsubscribe (rest of the
  # t:4 window-action surface = a later batch). The webview posts
  # {t:4,m:"subscribe",a:{event:"window:..."}} on the first JS listener for an
  # event (and "unsubscribe" when the last is removed); route it to
  # callbacks.zapp_window_set_js_listener so zapp_dispatch_event's Layer-2 JS
  # delivery is gated correctly.
  if f.t == 4 and (f.m == "subscribe" or f.m == "unsubscribe"):
    let evName = (if f.a.isNil: "" else: f.a{"event"}.getStr(""))
    let evId = eventNameToId(evName)
    if evId >= 0:
      zapp_window_set_js_listener(windowId.cint, evId.cint,
        (if f.m == "subscribe": 1.cint else: 0.cint))
    return

  # t:4 "ready" — the webview's bridge is up. Signal bridge-ready (flushes the
  # deferred first-focus event in window.m) + fire the native on_ready callback.
  # (worker_terminate_owner on refresh is worker-deferred — Batch 7.)
  if f.t == 4 and f.m == "ready":
    let wid = darwin_window_id_string(windowId.int32)
    if not wid.isNil: darwin_window_set_bridge_ready(wid)
    zapp_window_trigger_on_ready(windowId.int32)
    return

  if f.t != 1: return            # skeleton answers INVOKE only

  # `__clipboard:*` INVOKEs are handled natively (NOT via the service registry),
  # so they must be intercepted before the registry lookup below.
  if f.m.startsWith("__clipboard:"):
    routeClipboard(f.m, f.a, windowId, f.id)   # owns its own sendInvokeResponse
    return

  let res = invokeService(f.m, f.a)
  if res.isSome:
    sendInvokeResponse(windowId, f.id, true, res.get)
  else:
    # Wire-identical to the inline sub-gate-A bridge: the error payload is the
    # bare token "NOT_FOUND" (bootstrap/webview.ts builds Error(payload) from it,
    # so the message must stay unquoted, not JSON-encoded).
    sendInvokeResponse(windowId, f.id, false, "NOT_FOUND")
