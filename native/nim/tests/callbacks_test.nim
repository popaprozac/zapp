import std/strutils
import ../callbacks
import ../jslit

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
  # window:event fan-out now routes both the fixed name AND the all-integer
  # payload through jsLit (finding #2) — compute the expected literal with the
  # same primitive under test so this asserts callbacks.nim's WIRING (right
  # name, right payload, right IIFE shape), not a hand-transcribed
  # re-implementation of jsLit's escaping (covered by jslit_test.nim /
  # cli/src/jslit-transport.test.ts).
  let rawPayload = "{\"windowId\":2,\"event\":3,\"w\":100,\"h\":200,\"x\":0,\"y\":0}"
  let expected = "b._onEvent(" & jsLit("window:event") & "," & jsLit(rawPayload) & ")"
  doAssert workerJs.contains(expected), "got: " & workerJs
  echo "callbacks ok"
test()
