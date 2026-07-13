## Bridge dispatch — native→JS broadcast helpers, ported from
## native/bridge/dispatch.zc. Leaf module (no back-imports) so callbacks.nim /
## app_events.nim use it without an import cycle.
##
## zapp_escape_dup is the worker-safe libc escaper (zjs.c calls it AND frees
## the result, for the worker:crashed/gave-up/restarted payloads — a residual,
## not-yet-migrated native->JS surface tracked separately from finding #2; see
## task-2-report.md. NB bare.c has its own separate bare_json_escape_dup, not
## this one). It is kept here ONLY as an exported C-ABI symbol for zjs.c and
## the Windows platform C files — no Nim code in this tree calls it anymore.
## The Nim IIFE builders below run on the Cocoa main thread (event dispatch)
## and now route every interpolated value through jsLit (native/shared/jslit.c,
## finding #2 P0 fix) instead of the old hand-rolled escapeJs.

import nativeabi
import jslit  # jsLit — the ONE safe native->JS string-literal encoder (finding #2, P0)
proc c_malloc(n: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc c_strlen(s: cstring): csize_t {.importc: "strlen", header: "<string.h>".}

# Broadcast primitives from the compiled engine / platform layer.
proc zjs_broadcast_eval_js(js: cstring) {.importc, cdecl.}
proc nativeWebviewEvalAll(js: cstring) {.importc: abiPrefix & "webview_eval_all", cdecl.}

# zapp_escape_dup — escape (\ ' \n \r) + malloc(2n+1); caller frees. Consumed
# by zjs.c (worker crash/gave-up/restarted payloads) and by the Windows
# platform C files (panel/notification/sidebar/filedrop/deeplink) — NOT by any
# Nim caller anymore (Task 2 migrated the Nim-side call sites onto jsLit and
# deleted worker.nim's local importc). Kept here purely as the exported C-ABI
# symbol those non-Nim, out-of-scope callers still link against.
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

# dispatch_event_to_all — global event broadcast (dispatch.zc:138): the _onEvent
# IIFE (name + payload as safe JS string literals) to every webview + every
# worker. name/payload are opaque and RAW here (no pre-escaping) — jsLit is the
# only encoding step, applied at interpolation time.
proc dispatch_event_to_all*(eventName: cstring, payload: cstring)
    {.exportc, cdecl, gcsafe.} =
  let name = (if eventName.isNil: "" else: $eventName)
  let pl = (if payload.isNil: "" else: $payload)
  let js = "(function(){var b=globalThis[Symbol.for('zapp.bridge')];" &
           "if(b&&typeof b._onEvent==='function'){" &
           "b._onEvent(" & jsLit(name) & "," & jsLit(pl) & ");}})();"
  nativeWebviewEvalAll(js.cstring)
  worker_broadcast_eval_js(js.cstring)
