## Worker-path service dispatch. service_invoke_native is the C-ABI seam zjs.c
## calls ON THE WORKER PTHREAD — so it is allocation-free (no Nim heap, no ORC):
## method names compared via cstring (C strcmp), results are const-backed
## cstrings. Mirrors native/service/service.zc's linear-scan + fn-ptr dispatch so
## the measured work matches the zc baseline.
type WorkerServiceFn = proc(app: pointer, args: pointer): cstring {.cdecl, gcsafe.}
type WorkerServiceEntry = object
  name: cstring
  fn: WorkerServiceFn

var gServices: array[16, WorkerServiceEntry]
var gServiceCount = 0

const okResult = "{\"ok\":1}".cstring   # const cstring: zero GC interaction, gcsafe

proc benchNoop(app: pointer, args: pointer): cstring {.cdecl, gcsafe.} = okResult
proc benchEcho(app: pointer, args: pointer): cstring {.cdecl, gcsafe.} = okResult

proc zapp_worker_thread_gc_init*() {.exportc, cdecl.} =
  ## Called by zjs.c ONCE on each worker pthread before its message loop, so the
  ## thread can run Nim GC code (service handlers alloc on this thread's heap).
  setupForeignThreadGc()

proc registerWorkerServices*() =
  gServices[0] = WorkerServiceEntry(name: cstring"noop", fn: benchNoop)
  gServices[1] = WorkerServiceEntry(name: cstring"echo", fn: benchEcho)
  gServiceCount = 2

proc service_invoke_native*(app: pointer, methodName: cstring, args: pointer): cstring
    {.exportc, cdecl, gcsafe.} =
  ## `*` so the Nim test can call it; {.exportc.} keeps the C symbol name for zjs.c.
  ## args is JsonValue* (opaque here — bench handlers ignore it). Returns a JSON
  ## string cstring (engine copies synchronously; caller must NOT free) or "".
  for i in 0 ..< gServiceCount:
    if gServices[i].name == methodName:   # cstring content compare (strcmp) — no alloc
      return gServices[i].fn(app, args)
  return cstring""
