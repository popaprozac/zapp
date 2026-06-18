## Worker-path service dispatch. service_invoke_native is the C-ABI seam zjs.c
## calls ON THE WORKER PTHREAD. Dispatches to the REAL Nim service registry via
## a POD snapshot (gSnap) built once on the MAIN thread at boot and read-only
## thereafter — no cross-heap Nim seq reads on the worker, no alloc in the
## lookup loop.
##
## Foreign-thread GC is set up by zapp_worker_thread_gc_init (exported here),
## called by zjs.c once per worker pthread before its message loop; without it,
## any Nim alloc on the worker would be UB under ORC.
import std/json
import apptypes        # App, AppServiceHandler
import service         # registeredServices

type SnapEntry = object
  name: cstring              # borrows the registry's Nim-string buffer (app-lifetime,
                             # append-only, never freed; worker only reads) — safe.
  handler: AppServiceHandler

var gSnap: seq[SnapEntry]    # built once on the MAIN thread at boot; read-only after

proc buildWorkerServiceSnapshot*() =
  ## MAIN thread, after app.service.add calls + runStartupAll, before workers
  ## spawn. Fills gSnap from the real registry so worker pthreads can dispatch
  ## without touching the main-heap seq.
  gSnap = @[]
  for (name, handler) in registeredServices():
    gSnap.add SnapEntry(name: name.cstring, handler: handler)

proc registerWorkerServices*() =
  ## Alias kept for any call site that predates the rename; delegates to the
  ## real snapshot builder so all paths converge.
  buildWorkerServiceSnapshot()

proc zapp_worker_thread_gc_init*() {.exportc, cdecl.} =
  ## Called by zjs.c ONCE on each worker pthread before its message loop, so the
  ## thread can run Nim GC code (service handlers alloc on this thread's heap).
  setupForeignThreadGc()

var tlResult {.threadvar.}: string   # per-worker-thread root; cstring borrows this buffer

proc service_invoke_native*(app: pointer, methodName: cstring, args: pointer): cstring
    {.exportc, cdecl.} =
  ## Worker pthread (foreign-thread GC already set up by zapp_worker_thread_gc_init).
  ## Runs the real handler inline. args is JsonValue* (opaque) — Task 4 bridges it;
  ## for now handlers that use args get JNull (greet ignores args: smoke passes).
  ## Returns a cstring valid until the next call on this thread (zjs.c copies
  ## synchronously). Empty string = not found.
  for e in gSnap:
    if e.name == methodName:               # cstring content compare (C strcmp), no alloc
      let node = newJNull()               # TODO Task 4: bridge args JsonValue* -> JsonNode
      tlResult = e.handler(nil, node)     # nil app — pure-only contract (spec)
      return tlResult.cstring
  return cstring""
