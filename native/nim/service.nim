## Native service registry — the single source-of-truth for service identity,
## lifecycle, and the JS bindings manifest. The webview INVOKE path (router.nim)
## looks methods up here by name and runs the registered handler. The zero-overhead
## worker host-object path does NOT use this registry — it stays in the alloc-free
## worker_service.nim projection (populated per-service in a later batch).
##
## Ported from native/service/service.zc. Idiomatic-Nim wins over the zc original:
## an ordered seq[ServiceRecord] + linear scan replaces g_services[64] + strcmp;
## std/json builds the manifest instead of a static char[4096] snprintf buffer;
## Option[string] replaces the Result/sentinel miss. Per-service mutex + stateful
## register(service_ptr) + the worker JSON-string invoke_sync are deferred (no
## consumer until the worker-subsystem / leaf-service batches).
import std/[json, options]

type
  ServiceHandler* = proc(args: JsonNode): string {.nimcall.}
  LifecycleHook*  = proc() {.nimcall.}
  ServiceRecord = object
    name: string
    handler: ServiceHandler
    startup, shutdown: LifecycleHook

var gRegistry: seq[ServiceRecord]

proc registerService*(name: string, handler: ServiceHandler,
                      startup: LifecycleHook = nil,
                      shutdown: LifecycleHook = nil) =
  ## Register a service (registration order preserved for lifecycle). Mirrors
  ## ServiceManager.add — stateless handler; optional startup/shutdown hooks.
  gRegistry.add ServiceRecord(name: name, handler: handler,
                              startup: startup, shutdown: shutdown)

proc invokeService*(name: string, args: JsonNode): Option[string] =
  ## Run the handler for `name`; none when unregistered (router maps that to a
  ## NOT_FOUND rejection). Linear scan — service counts are tiny, matching zc.
  for rec in gRegistry:
    if rec.name == name: return some rec.handler(args)
  none(string)

proc runStartupAll*() =
  ## Fire startup() for every service that has one, in registration order
  ## (service.zc:service_run_startup_all).
  for rec in gRegistry:
    if rec.startup != nil: rec.startup()

proc runShutdownAll*() =
  ## Fire shutdown() in REVERSE registration order
  ## (service.zc:service_run_shutdown_all).
  for i in countdown(gRegistry.len - 1, 0):
    if gRegistry[i].shutdown != nil: gRegistry[i].shutdown()

proc serviceManifestJson*(): string =
  ## The JS bindings manifest webview.m injects as zapp.bindingsManifest. Shape
  ## matches service.zc:service_get_manifest_json exactly: {"v":1,"services":[…]}.
  ## std/json (compact `$`) replaces the zc static char[4096] snprintf builder.
  var services = newJArray()
  for rec in gRegistry:
    services.add(%*{"name": rec.name})
  $(%*{"v": 1, "services": services})

# --- C-ABI seam (the .m / platform layer calls these) -----------------------

# service_get_manifest_json — consumed by webview.m (zapp.bindingsManifest). The
# built JSON is cached in a module-level var so the returned cstring outlives the
# call (webview.m copies it synchronously).
var gManifestCache: string
proc service_get_manifest_json*(): cstring {.exportc, cdecl.} =
  gManifestCache = serviceManifestJson()
  gManifestCache.cstring

# service_run_shutdown_all — called by platform.m / platform.c / ios platform.m
# at teardown. service_run_startup_all needs no C-ABI export: its only caller was
# app.zc, and in the Nim build app.nim calls runStartupAll() directly.
proc service_run_shutdown_all*() {.exportc, cdecl.} =
  runShutdownAll()
