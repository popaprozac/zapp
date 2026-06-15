import ../callbacks

# Standalone-link seam: the real binary resolves zapp_dispatch_event_to_js from
# the untouched window.m. This test doesn't compile window.m, so provide a no-op
# definition of that C symbol for the link. (Test-only; never in the real build.)
proc zapp_dispatch_event_to_js(windowId, eventId, w, h, x, y: cint) {.exportc, cdecl.} =
  discard

proc test() =
  zapp_window_set_js_listener(2, 3, 1)
  doAssert willDeliverToJs(2, 3) == true
  doAssert willDeliverToJs(2, 4) == false
  zapp_window_set_js_listener(2, 3, 0)
  doAssert willDeliverToJs(2, 3) == false
  doAssert willDeliverToJs(-1, 3) == false
  doAssert willDeliverToJs(2, 99) == false
  echo "callbacks ok"
test()
