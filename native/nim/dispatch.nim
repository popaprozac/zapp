## Bridge dispatch — native→JS broadcast helpers, ported from
## native/bridge/dispatch.zc. Leaf module (no back-imports) so callbacks.nim /
## app_events.nim use it without an import cycle.
##
## Finding #2 (P0) is now fully closed: every native->JS interpolation site,
## Nim and C alike, routes through the ONE safe encoder, zapp_js_lit_dup
## (native/shared/jslit.c) — via the jsLit wrapper on the Nim side, and
## directly on the C side (zjs.c's worker-crash payload + the Windows
## platform files: deeplink/filedrop/notification/panel/sidebar). The old
## weak libc escaper that used to live here (missed `"` and U+2028/U+2029)
## has been deleted — see task-2.5-report.md. (NB bare.c has its own separate
## bare_json_escape_dup, unrelated to any of this.)

import nativeabi
import jslit  # jsLit — the ONE safe native->JS string-literal encoder (finding #2, P0)

# Broadcast primitives from the compiled engine / platform layer.
proc zjs_broadcast_eval_js(js: cstring) {.importc, cdecl.}
proc nativeWebviewEvalAll(js: cstring) {.importc: abiPrefix & "webview_eval_all", cdecl.}

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
