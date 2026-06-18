## Shared app-layer types in a leaf module so service.nim / window.nim / app.nim
## can all reference `App` without an import cycle. Behavior (methods) lives in the
## feature modules; this file is types only — it imports nothing from them.
import std/json

type
  ServiceManager* = object   ## namespacing handle for app.service.* (stateless)
  WindowManager* = object    ## namespacing handle for app.window.* (stateless)
  App* = ref object
    name*: string
    terminateAfterLastWindowClosed*: bool
    service*: ServiceManager
    window*: WindowManager
  AppServiceHandler* = proc(app: App, args: JsonNode): string {.nimcall.}
    ## Service handler — mirrors zc `fn(app: App*, args: JsonValue*) -> string`.
