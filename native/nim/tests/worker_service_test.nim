## Tests for worker_service.nim snapshot + dispatch (Task 3, Phase 1).
## Registers a real service via registerService, builds the snapshot via
## buildWorkerServiceSnapshot (or the registerWorkerServices alias), then
## exercises service_invoke_native on the calling thread (no pthread needed —
## the cstring compare + dispatch are testable inline).
import std/json
import ../apptypes  # App, AppServiceHandler
import ../service   # registerService (populate the real registry)
import ../worker_service

proc greetHandler(app: App, args: JsonNode): string = "Hello from Zapp!"
proc echoHandler(app: App, args: JsonNode): string = $args

proc test() =
  registerService("greet", greetHandler)
  registerService("echo", echoHandler)
  buildWorkerServiceSnapshot()

  # greet — ignores args, returns the real string
  doAssert $service_invoke_native(nil, cstring"greet", nil) == "Hello from Zapp!"
  # unknown method → empty string
  doAssert $service_invoke_native(nil, cstring"missing", nil) == ""
  # registerWorkerServices alias — idempotent rebuild, greet still works
  registerWorkerServices()
  doAssert $service_invoke_native(nil, cstring"greet", nil) == "Hello from Zapp!"
  echo "worker_service ok"
test()
