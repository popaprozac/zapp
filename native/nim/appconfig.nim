## App config — the AppConfig value + the app_get_bootstrap_* getters webview.m
## reads at window creation. Ported from native/app/app.zc (AppConfig + the
## bootstrap accessors). Leaf module (only importc's the dev-tools flag) so it's
## unit-testable without booting the platform; app.nim sets the config at newApp.
##
## Inspectable {.pure.} is the user-facing config enum (the type-modeling
## convention's deferred item, mirroring app.zc:296 ZappInspectable) — distinct
## from the window-tag coretypes.TriState: this resolves to a bool at the getter.

type
  Inspectable* {.pure.} = enum
    Auto   ## dev-gated: on when dev-tools are enabled
    On
    Off

  AppConfig* = object
    name*: string
    terminateAfterLastWindowClosed*: bool
    inspectable*: Inspectable
    maxWorkers*: int32

# CLI-emitted dev-tools flag (1 in dev, 0 in prod) — resolves Inspectable.Auto.
proc zapp_build_dev_tools_default(): cint {.importc, cdecl.}

var gAppConfig = AppConfig(
  name: "Zapp", terminateAfterLastWindowClosed: true,
  inspectable: Inspectable.Auto, maxWorkers: 0)

proc setAppConfig*(c: AppConfig) =
  ## Called once at newApp (app.nim) before any window/worker exists.
  gAppConfig = c

# --- C-ABI getters (webview.m reads these at window creation) ----------------
var gName = "Zapp"   # module-let backing for the returned cstring (lifetime rule)

proc app_get_bootstrap_name*(): cstring {.exportc, cdecl.} =
  gName = gAppConfig.name
  gName.cstring

proc app_get_bootstrap_web_content_inspectable*(): bool {.exportc, cdecl.} =
  case gAppConfig.inspectable
  of Inspectable.On: true
  of Inspectable.Off: false
  of Inspectable.Auto: zapp_build_dev_tools_default() > 0

proc app_get_bootstrap_application_should_terminate_after_last_window_closed*(): bool
    {.exportc, cdecl.} =
  gAppConfig.terminateAfterLastWindowClosed

proc app_get_bootstrap_max_workers*(): cint {.exportc, cdecl.} =
  gAppConfig.maxWorkers.cint

proc app_get_allowed_navigation_json*(): cstring {.exportc, cdecl.} =
  ## security.zc (the nav allowlist) is not ported — "" = no extra allowlist.
  "".cstring
