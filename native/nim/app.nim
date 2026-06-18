## App value + lifecycle. Mirrors the old Zen-C `App` (app.zc): construct it,
## which boots the platform, then `run` enters the Cocoa run loop. Also owns the
## webview->native message entry point (zapp_handle_message_from_window),
## delegating dispatch to router.nim.
import platform
import apptypes
import router, service, permissions, appconfig
import worker_service          # buildWorkerServiceSnapshot — worker→native service seam
# zapp_headless is CLI-generated into the project's .zapp/ dir (--path:<.zapp>),
# providing zapp_start_headless_workers() which spawns the configured zjs workers.
import zapp_headless

proc newApp*(config: AppConfig): App =
  ## Mirrors App::new(config) — init the platform, store the config, wire the
  ## managers, set the current app. The AppConfig form surfaces inspectable /
  ## maxWorkers (like zc's App::new(config)).
  platformInit(config.name)
  setAppConfig(config)
  result = App(name: config.name,
               terminateAfterLastWindowClosed: config.terminateAfterLastWindowClosed,
               service: ServiceManager(), window: WindowManager())
  setCurrentApp(result)

proc newApp*(name: string, terminateAfterLastWindowClosed = true): App =
  ## Convenience shorthand — sensible AppConfig defaults (inspectable Auto, no
  ## worker cap). Delegates to newApp(AppConfig).
  newApp(AppConfig(name: name, terminateAfterLastWindowClosed: terminateAfterLastWindowClosed,
                   inspectable: Inspectable.Auto, maxWorkers: 0))

proc run*(app: App): int =
  ## Init permissions (main-thread parse), build the worker service snapshot,
  ## run startup hooks, spawn zjs headless workers, then enter the Cocoa run
  ## loop (blocks). permissionsEnsureInit() runs FIRST so the manifest is
  ## parsed on the main thread before any window or worker can issue a
  ## permission check. buildWorkerServiceSnapshot() MUST run AFTER services
  ## are registered (app.service.add) and BEFORE workers spawn so the worker
  ## pthreads see a complete snapshot; runStartupAll() runs before the spawn
  ## so services are started before any worker can invoke them.
  permissionsEnsureInit()
  buildWorkerServiceSnapshot()
  runStartupAll()
  zapp_start_headless_workers()
  platformRun(app.terminateAfterLastWindowClosed)

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
