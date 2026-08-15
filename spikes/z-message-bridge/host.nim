## Pressure-test adapter for Zapp's current webview ABI.
##
## Production currently enters through
## zapp_handle_message_from_window(void *, char *, int32_t). The Nim path does
## not use the first argument, so this adapter preserves that ABI while routing
## the message through an owned Z String and back into the existing Nim-router
## shape.

var observedMessage = ""
var observedWindowId: int32 = -1

proc zapp_message_bridge_runtime_initialize(config: pointer): cint {.importc, cdecl.}
proc zapp_message_bridge_runtime_shutdown(): cint {.importc, cdecl.}
proc zapp_route_message_owned(message: cstring, windowId: int32) {.importc, cdecl.}

proc zapp_route_message_from_z(message: cstring,
                               windowId: int32) {.exportc, cdecl.} =
  if message == nil:
    quit("Z forwarded a null message", 10)
  observedMessage = $message
  observedWindowId = windowId

proc zapp_handle_message_from_window(app: pointer, message: cstring,
                                     windowId: int32) {.exportc, cdecl.} =
  discard app
  if message != nil:
    zapp_route_message_owned(message, windowId)

when isMainModule:
  if zapp_message_bridge_runtime_initialize(nil) != 0:
    quit("could not initialize the embedded Z runtime", 2)

  var appSentinel: int
  let envelope = "{\"message\":\"héllo from Zapp\"}"
  zapp_handle_message_from_window(addr appSentinel, envelope.cstring, 42)

  if observedMessage != envelope or observedWindowId != 42:
    quit("the Z bridge changed the routed message", 3)

  echo "routed window=", observedWindowId, " message=", observedMessage

  if zapp_message_bridge_runtime_shutdown() != 0:
    quit("could not shut down the embedded Z runtime", 4)
