## Native service registry. The webview path (router.nim) looks methods up here
## by name and runs the registered handler, replacing the inline hardcoded greet
## of the sub-gate-A bridge. A plain `Table` of nimcall proc values is the
## idiomatic Nim shape and is fine for the webview path (inherently async);
## the zero-overhead worker host-object path does NOT use this registry.
##
## Handler contract: takes the decoded args JsonNode (may be nil when the
## envelope had no "a") and returns the response payload as a string — the same
## already-serialized JSON the zc services hand back to dispatch_invoke_response.
import std/[json, tables, options]

type ServiceHandler* = proc(args: JsonNode): string {.nimcall.}

var registry = initTable[string, ServiceHandler]()

proc addService*(name: string, h: ServiceHandler) =
  ## Register (or replace) the handler for `name`.
  registry[name] = h

proc invokeService*(name: string, args: JsonNode): Option[string] =
  ## Run the handler for `name`, returning its payload; none when no handler is
  ## registered (router.nim maps that to a NOT_FOUND rejection).
  if registry.hasKey(name): some registry[name](args)
  else: none(string)
