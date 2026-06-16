import std/strutils
import ../callbacks

# Standalone-link seam: the real binary resolves zapp_dispatch_event_to_js from
# the untouched window.m. This test doesn't compile window.m, so provide a no-op
# definition of that C symbol for the link. (Test-only; never in the real build.)
proc zapp_dispatch_event_to_js(windowId, eventId, w, h, x, y: cint) {.exportc, cdecl.} =
  discard

# callbacks now imports dispatch, which importc's these engine/platform symbols.
# Stub them for the standalone link; capture the worker broadcast for the
# Layer-3 window:event assertion.
var workerJs = ""
proc zjs_broadcast_eval_js(js: cstring) {.exportc, cdecl.} = workerJs = $js
proc darwin_webview_eval_all(js: cstring) {.exportc, cdecl.} = discard

proc test() =
  zapp_window_set_js_listener(2, 3, 1)
  doAssert willDeliverToJs(2, 3) == true
  doAssert willDeliverToJs(2, 4) == false
  zapp_window_set_js_listener(2, 3, 0)
  doAssert willDeliverToJs(2, 3) == false
  doAssert willDeliverToJs(-1, 3) == false
  doAssert willDeliverToJs(2, 99) == false

  zapp_window_set_backend_listener(2, 3, 1)   # window 2: worker subscribes to event 3
  workerJs = ""
  discard zapp_dispatch_event(2, 3, 100, 200, 0, 0)
  doAssert workerJs.contains("b._onEvent('window:event'")
  doAssert workerJs.contains("\"event\":3")
  doAssert workerJs.contains("\"w\":100")
  echo "callbacks ok"
test()
