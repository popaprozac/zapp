## Bridge dispatch — native→JS broadcast helpers, ported from
## native/bridge/dispatch.zc. Leaf module (no back-imports) so callbacks.nim /
## app_events.nim use it without an import cycle.
##
## zapp_escape_dup is the worker-safe libc escaper (zjs.c calls it AND frees the
## result), replacing the perf-gate strdup stub. The Nim IIFE builders run on the
## Cocoa main thread (event dispatch), so escapeJs (Nim string) is fine there.

import nativeabi
proc c_malloc(n: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc c_strlen(s: cstring): csize_t {.importc: "strlen", header: "<string.h>".}

# Broadcast primitives from the compiled engine / platform layer.
proc zjs_broadcast_eval_js(js: cstring) {.importc, cdecl.}
proc nativeWebviewEvalAll(js: cstring) {.importc: abiPrefix & "webview_eval_all", cdecl.}

# zapp_escape_dup — escape (\ ' \n \r) + malloc(2n+1); caller frees. zjs.c
# consumes + frees this for worker→webview payloads. POD/libc (no Nim heap) →
# gcsafe + thread-safe. Replaces the zapp.nim strdup-only stub (a latent bug:
# payloads with quotes/newlines broke the injected JS).
proc zapp_escape_dup*(src: cstring): cstring {.exportc, cdecl, gcsafe.} =
  let n = (if src.isNil: 0 else: c_strlen(src).int)
  let dst = cast[ptr UncheckedArray[char]](c_malloc(csize_t(n * 2 + 1)))
  if dst == nil: return nil
  var j = 0
  if not src.isNil:
    let s = cast[ptr UncheckedArray[char]](src)
    for i in 0 ..< n:
      let c = s[i]
      case c
      of '\\': dst[j] = '\\'; inc j; dst[j] = '\\'; inc j
      of '\'': dst[j] = '\\'; inc j; dst[j] = '\''; inc j
      of '\n': dst[j] = '\\'; inc j; dst[j] = 'n'; inc j
      of '\r': dst[j] = '\\'; inc j; dst[j] = 'r'; inc j
      else: dst[j] = c; inc j
  dst[j] = '\0'
  cast[cstring](dst)

# worker_broadcast_eval_js — fan a JS snippet to every worker. {.exportc.} so the
# B6/B8 native-emit .m sites (shortcuts/menu/tray/sync) link against it; the Nim
# dispatch path calls it now. zjs-only build → zjs_broadcast_eval_js.
proc worker_broadcast_eval_js*(js: cstring) {.exportc, cdecl.} =
  zjs_broadcast_eval_js(js)

# escapeJs — Nim main-thread escaper for the IIFE builders (same rules as
# zapp_escape_dup; used where the source is a Nim string).
proc escapeJs*(s: string): string =
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '\'': result.add "\\'"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    else: result.add c

# dispatch_event_to_all — global event broadcast (dispatch.zc:138): the _onEvent
# IIFE (name + payload escaped) to every webview + every worker.
proc dispatch_event_to_all*(eventName: cstring, payload: cstring)
    {.exportc, cdecl, gcsafe.} =
  let name = escapeJs(if eventName.isNil: "" else: $eventName)
  let pl = escapeJs(if payload.isNil: "" else: $payload)
  let js = "(function(){var b=globalThis[Symbol.for('zapp.bridge')];" &
           "if(b&&typeof b._onEvent==='function'){" &
           "b._onEvent('" & name & "','" & pl & "');}})();"
  nativeWebviewEvalAll(js.cstring)
  worker_broadcast_eval_js(js.cstring)
