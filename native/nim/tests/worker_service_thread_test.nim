# Foreign-pthread dispatch test for worker→native service invocation (#471).
# Verifies service_invoke_native works correctly when called from a raw
# pthread (not a Nim-created thread) with foreign-thread GC set up — the
# exact production path: snapshot built on main thread, dispatch on worker.
# NOTE: hardcoded provider .o path — tracked follow-up (portability).
{.passL: "/Users/zach/code/zapp/kitchen-sink/.zapp/zjson_provider.o".}
import std/posix
import std/json
import ../apptypes
import ../service
import ../worker_service

# Stub for worker_eval_js — defined in worker.nim in the full app build.
# worker_service.nim importc's it for zapp_worker_invoke_on_main (Task 2);
# this test doesn't exercise that path but the linker needs the symbol.
proc worker_eval_js(workerId, js: cstring) {.exportc, cdecl.} = discard

proc greetHandler(app: App, args: JsonNode): string = "Hello from Zapp!"

var tlResult {.threadvar.}: string  # per-thread root so cstring stays alive

proc workerBody(arg: pointer): pointer {.noconv.} =
  setupForeignThreadGc()
  # service_invoke_native on a foreign pthread — the cross-thread + foreign-GC path.
  let res = service_invoke_native(nil, cstring"greet", nil)
  doAssert $res == "Hello from Zapp!", "greet handler returned: " & $res
  let missing = service_invoke_native(nil, cstring"no_such_method", nil)
  doAssert $missing == "", "expected empty for missing method, got: " & $missing
  tearDownForeignThreadGc()
  result = nil

# Build the snapshot on the MAIN thread, before spawning — mirrors production.
registerService("greet", greetHandler)
buildWorkerServiceSnapshot()

var tid: Pthread
doAssert pthread_create(addr tid, nil, workerBody, nil) == 0
doAssert pthread_join(tid, nil) == 0
echo "worker_service_thread ok"
