## App value + lifecycle. Mirrors the old Zen-C `App` (app.zc): construct it,
## which boots the platform, then `run` enters the Cocoa run loop. Also owns the
## skeleton's service registration and the webview->native message entry point
## (zapp_handle_message_from_window), delegating dispatch to router.nim.
import std/json
import platform
import router, service
import worker_service          # registerWorkerServices — worker→native service seam
# zapp_headless is CLI-generated into the project's .zapp/ dir (--path:<.zapp>),
# providing zapp_start_headless_workers() which spawns the configured zjs workers.
import zapp_headless

type App* = object
  name*: string
  terminateAfterLastWindowClosed*: bool

proc newApp*(name: string, terminateAfterLastWindowClosed = true): App =
  ## Mirrors App::new — init the platform, return the app value.
  platformInit(name)
  App(name: name, terminateAfterLastWindowClosed: terminateAfterLastWindowClosed)

proc run*(app: App): int =
  ## Register worker-path services, run service startup hooks, spawn the
  ## configured zjs headless workers, then enter the Cocoa run loop (blocks).
  ## registerWorkerServices() MUST run before the spawn so service_invoke_native
  ## has the bench handlers when the worker's first invokeService round-trips
  ## back into native; runStartupAll() runs before the spawn so services are
  ## started before any worker can invoke them.
  registerWorkerServices()
  runStartupAll()
  zapp_start_headless_workers()
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
  registerService("greet", greetService)

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
