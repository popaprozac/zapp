# Foreign-pthread dispatch test for worker→native service invocation (#471).
# Verifies service_invoke_native works correctly when called from a raw
# pthread (not a Nim-created thread) with foreign-thread GC set up — the
# exact production path: snapshot built on main thread, dispatch on worker.
import std/posix
import std/json
import ../apptypes
import ../service
import ../worker_service

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
