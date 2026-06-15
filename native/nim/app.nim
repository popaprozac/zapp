## App value + lifecycle. Mirrors the old Zen-C `App` (app.zc): construct it,
## which boots the platform, then `run` enters the Cocoa run loop. Also owns the
## skeleton's service registration and the webview->native message entry point
## (zapp_handle_message_from_window), delegating dispatch to router.nim.
import std/json
import platform
import router, service

type App* = object
  name*: string
  terminateAfterLastWindowClosed*: bool

proc newApp*(name: string, terminateAfterLastWindowClosed = true): App =
  ## Mirrors App::new — init the platform, return the app value.
  platformInit(name)
  App(name: name, terminateAfterLastWindowClosed: terminateAfterLastWindowClosed)

proc run*(app: App): int =
  ## Enters the Cocoa run loop (blocks). Services/workers wired later.
  platformRun(app.terminateAfterLastWindowClosed)

# --- Services ---------------------------------------------------------------

proc greetService(args: JsonNode): string =
  ## Demo service. Static result mirrors native/build.zc:greet_service (the zc
  ## reference) and the inline sub-gate-A bridge. The hello-world entry module
  ## top-level-awaits greet() before mounting #app, so this resolving is what
  ## makes the UI render.
  discard args
  """{"greeting":"hello from native"}"""

proc registerSkeletonServices*() =
  ## Register the walking-skeleton's services. Called from zapp.nim before run().
  addService("greet", greetService)

# --- Message bridge entry point ---------------------------------------------

# zapp_handle_message_from_window — the JS->native message bridge entry point,
# called by webview.m's didReceiveScriptMessage (gated on app_get_active()!=NULL).
# The bootstrap bridge posts JSON envelopes `{t, id, m, a}`; we hand the raw
# string to router.nim which parses + dispatches + answers. Thin C-ABI shim by
# design — all logic lives in router/service/bridge.
proc zapp_handle_message_from_window(app: pointer, msg: cstring,
                                     windowId: int32) {.exportc, cdecl.} =
  discard app
  if msg != nil: routeMessage($msg, windowId.int)
