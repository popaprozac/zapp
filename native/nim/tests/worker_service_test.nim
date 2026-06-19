## Tests for worker_service.nim snapshot + dispatch.
## Registers real services, builds the snapshot, and exercises
## service_invoke_native on the calling thread (the cstring compare + dispatch
## are testable inline; the foreign-pthread path is covered by
## worker_service_thread_test.nim). Args are built through the real jsonvalue
## C-ABI provider and read back as a JsonNode by service_invoke_native.
import std/json
import std/strutils
import ../apptypes        # App, AppServiceHandler
import ../service         # registerService (populate the real registry)
import ../worker_service
import ../jsonvalue       # jvObject/jvString/jsonObjectSetOwned/jsonFreeTree

# Stub for worker_eval_js — defined in worker.nim in the full app build.
# worker_service.nim importc's it for zapp_worker_invoke_on_main; these tests
# don't exercise that path but the linker needs the symbol.
proc worker_eval_js(workerId, js: cstring) {.exportc, cdecl.} = discard

proc greetHandler(app: App, args: JsonNode): string = "Hello from Zapp!"
proc echoHandler(app: App, args: JsonNode): string = $args

proc testSnapshot() =
  registerService("greet", greetHandler)
  registerService("echo", echoHandler)
  buildWorkerServiceSnapshot()

  # greet — ignores args (nil → JNull), returns the real string
  doAssert $service_invoke_native(nil, cstring"greet", nil) == "Hello from Zapp!"
  # unknown method → empty string
  doAssert $service_invoke_native(nil, cstring"missing", nil) == ""
  # registerWorkerServices alias — idempotent rebuild, greet still works
  registerWorkerServices()
  doAssert $service_invoke_native(nil, cstring"greet", nil) == "Hello from Zapp!"
  echo "  worker_service snapshot ok"

proc testEchoArgs() =
  # Build {"msg":"ping"} via the real provider; service_invoke_native borrows it
  # as a JsonNode and the echo handler stringifies it.
  let obj = jvObject()
  jsonObjectSetOwned(obj, cstring"msg", jvString(cstring"ping"))
  let res = $service_invoke_native(nil, cstring"echo", obj)
  jsonFreeTree(obj)
  doAssert res.contains("msg") and res.contains("ping"), "echo round-trip: " & res
  echo "  service_invoke_native echo args round-trip ok"

testSnapshot()
testEchoArgs()
echo "worker_service ok"
