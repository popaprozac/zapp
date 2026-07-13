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
import std/options
import apptypes        # App, AppServiceHandler
import service         # registeredServices, invokeService
import jslit           # jsLit — the ONE safe native->JS string-literal encoder (finding #2, P0)
import jsonvalue     # JsonValue C-ABI provider (compiled into the build) + withArgsNode

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

# worker_eval_js — defined in worker.nim ({.exportc, cdecl.}); importc by C name
# so worker_service.nim can deliver a JS snippet to a specific worker without a
# circular import (worker.nim ← service.nim path that would arise from importing worker).
proc worker_eval_js(workerId, js: cstring) {.importc, cdecl.}

proc service_invoke_native*(app: pointer, methodName: cstring, args: pointer): cstring
    {.exportc, cdecl.} =
  ## Worker pthread (foreign-thread GC already set up by zapp_worker_thread_gc_init).
  ## Runs the real handler inline. args is a JsonValue* the provider built (a
  ## JsonNode behind the opaque pointer); withArgsNode borrows it (no ownership —
  ## zjs.c frees it via json_free_tree after this returns). Returns a cstring
  ## valid until the next call on this thread (zjs.c copies synchronously).
  ## Empty string = not found.
  for e in gSnap:
    if e.name == methodName:               # cstring content compare (C strcmp), no alloc
      withArgsNode(args):
        tlResult = e.handler(nil, argsNode)  # nil app — pure-only contract (spec)
      return tlResult.cstring
  return cstring""

# ---------------------------------------------------------------------------
# Async worker invoke — MAIN-THREAD entry (Task 2 zjs.c host fn calls this
# from a dispatch_async(main) block).
# ---------------------------------------------------------------------------

proc zapp_worker_invoke_on_main*(workerId: cstring, reqId: cint,
                                 methodName: cstring, argsJson: cstring)
    {.exportc, cdecl.} =
  ## MAIN thread. Real registry (gCurrentApp valid via service.nim's invokeService)
  ## for an async worker invoke. Resolves the worker-side promise via
  ## worker_eval_js → _resolveInvoke (JS side added in Task 3).
  var ok = true
  var payload: string
  try:
    let args =
      if argsJson.isNil or argsJson[0] == '\0': newJNull()
      else: parseJson($argsJson)
    let r = invokeService($methodName, args)
    if r.isSome:
      payload = r.get
    else:
      ok = false
      payload = "NOT_FOUND"
  except CatchableError as e:
    ok = false
    payload = e.msg
  let iife =
    "(function(){var b=self.__zappBridge;if(b&&b._resolveInvoke){b._resolveInvoke(" &
    $reqId.int & "," & (if ok: "true" else: "false") & "," &
    jsLit(payload) & ");}})();"
  worker_eval_js(workerId, iife.cstring)
