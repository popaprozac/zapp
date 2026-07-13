## Worker engine dispatcher + worker→webview delivery. Port of native/worker/
## worker.zc (the engine dispatcher + zapp_resolve_engine) plus the
## worker_dispatch_to_webview / worker_dispatch_to_window path in native/app/
## app.zc:184-275.
##
## zjs-only: bare.c is NOT compiled into this build, so the bare_worker_* arms
## of the zc dispatch switch have no symbols — they are OMITTED here (the only
## live engine is zjs, id 7). zapp_resolve_engine therefore always resolves to
## 7 and logs a downgrade (to stderr) only on an EXPLICIT non-7 request, exactly
## like worker.zc:94-141.
##
## Thread discipline: zjs.c calls worker_dispatch_to_webview (zjs.c:645, from
## host_post_to_webview) possibly on a WORKER pthread → the whole delivery path
## (worker_dispatch_to_webview / dispatchToWindow) is {.gcsafe.} + libc only.
## NO Nim string / seq / GC anywhere on it. Encoding calls zapp_js_lit_dup
## (native/shared/jslit.c, finding #2 P0 fix — the ONE safe native->JS literal
## encoder; libc malloc, caller frees) DIRECTLY, not the Nim jsLit() wrapper,
## so no Nim heap/GC touches this path. The IIFE is built with libc
## snprintf/malloc; darwin_window_eval_js copies the buffer synchronously
## before queueing onto the main thread, so it is safe to call from any thread
## (window.m). The compiler enforces gcsafe under --threads:on
## (cli/src/native.ts:1212).

import registry   # registryFirstOwner (gcsafe)
import nativeabi

# --- zjs engine C-ABI (compiled in native/worker/engines/zjs.c) -------------
# Signatures match zjs.c:1802/1836/1872/1891 EXACTLY (importc by C name).
proc zjs_worker_create(scriptUrl, ownerId, workerId: cstring): bool {.importc, cdecl.}
proc zjs_worker_post_message(workerId, dataJson: cstring) {.importc, cdecl.}
proc zjs_worker_terminate(workerId: cstring) {.importc, cdecl.}
proc zjs_worker_terminate_owner(ownerId: cstring) {.importc, cdecl.}
proc zjs_worker_eval_js(workerId, js: cstring) {.importc, cdecl.}

# --- registry C-ABI (registry.nim {.exportc.} surface) ----------------------
proc zapp_worker_registry_set_engine(workerId: cstring, engine: cint) {.importc, cdecl.}
proc zapp_worker_registry_get_engine(workerId: cstring): cint {.importc, cdecl.}
proc zapp_worker_registry_get_display_name(workerId: cstring): cstring {.importc, cdecl.}

# --- safe JS literal encoding (native/shared/jslit.c) + platform window eval
# (window.m) -----------------------------------------------------------------
# zapp_js_lit_dup: libc malloc'd COMPLETE double-quoted JS string literal
# (finding #2, P0); caller free()s. Called directly (not via jslit.nim's
# jsLit wrapper) to keep this path pure libc — no Nim heap on a worker pthread.
proc zapp_js_lit_dup(s: cstring): cstring {.importc, cdecl.}
# Reverse-lookup "win-<n>" → numeric window id (window.m:475); -1 if no match.
proc nativeWindowNumericIdForString(wid: cstring): int32 {.importc: abiPrefix & "window_numeric_id_for_string", cdecl.}
# Eval JS in a window's webview (window.m); copies the buffer synchronously
# before queueing onto the main thread → safe from a worker pthread.
proc nativeWindowEvalJs(numericId: int32, js: cstring) {.importc: abiPrefix & "window_eval_js", cdecl.}

# --- libc (no Nim heap; gcsafe + worker-thread-safe) ------------------------
proc c_malloc(n: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>", cdecl.}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>", cdecl.}
proc c_snprintf(buf: ptr char, n: csize_t, fmt: cstring): cint
  {.importc: "snprintf", header: "<stdio.h>", cdecl, varargs.}
proc c_fprintf(stream: pointer, fmt: cstring): cint
  {.importc: "fprintf", header: "<stdio.h>", cdecl, varargs.}
var cStderr {.importc: "stderr", header: "<stdio.h>".}: pointer

const ZAPP_ENGINE_ZJS = 7'i32

# --- Engine resolution (port of worker.zc:zapp_resolve_engine) --------------
# zjs (7) is the only engine compiled in, so always resolve to 7. Mirror the
# zc's "warn only on an EXPLICIT request that can't be honored" rule: requested
# < 0 means "no preference" (the normal default path) and is silent; an explicit
# non-7 engine logs a downgrade to stderr. Engine-name labels mirror
# worker.zc:123. gcsafe: only libc fprintf + the registry display-name read.
proc zappResolveEngine*(requested: cint, workerId: cstring): cint {.gcsafe.} =
  if requested == ZAPP_ENGINE_ZJS: return ZAPP_ENGINE_ZJS
  if requested >= 0:
    # Only zjs is present, so an explicit non-zjs request is always a downgrade.
    let name =
      case requested
      of 2: cstring"bare-jsc"
      of 3: cstring"bare-v8"
      of 4: cstring"bare-quickjs"
      of 5: cstring"bare-mqjs"
      of 6: cstring"bare-hermes"
      of 7: cstring"zjs"
      else: cstring"?"
    # NB: the `.cstring` conversion form interprets `\n` as a real newline; the
    # `cstring"…"` prefix form would emit a literal backslash-n. Match the zc's
    # trailing newline (worker.zc:131-135).
    discard c_fprintf(cStderr,
      "[zapp/%s] requested %s but it's not compiled in — using zjs.\n".cstring,
      zapp_worker_registry_get_display_name(workerId), name)
  ZAPP_ENGINE_ZJS

# --- Unified dispatchers (port of worker.zc:185-236, zjs-only) --------------

# worker_create (worker.zc:185-207): resolve the engine, record it on the
# registry (so post/terminate route correctly), then dispatch to zjs. `app` is
# unused in the zjs-only build (kept for ABI parity with the zc signature).
proc worker_create*(app: pointer, scriptUrl, ownerId, workerId: cstring,
    engine: cint): bool {.exportc, cdecl, gcsafe.} =
  let eng = zappResolveEngine(engine, workerId)
  zapp_worker_registry_set_engine(workerId, eng)
  if eng == ZAPP_ENGINE_ZJS:
    return zjs_worker_create(scriptUrl, ownerId, workerId)
  false   # unreachable in the zjs-only build; bare engines aren't compiled in

# worker_post_message (worker.zc:209-215). REPLACES the zapp.nim stub. Also the
# worker→worker symbol zjs.c:116/695 links against. Dispatch via the worker's
# recorded engine.
proc worker_post_message*(workerId, dataJson: cstring) {.exportc, cdecl, gcsafe.} =
  if zapp_worker_registry_get_engine(workerId) == ZAPP_ENGINE_ZJS:
    zjs_worker_post_message(workerId, dataJson)

# worker_eval_js (port of dispatch.zc worker_eval_js → zapp_dispatch_worker_eval_js).
# sync.m's darwin_sync_dispatch_to_worker (sync.m:294-295) calls this to deliver a
# wait-result to ONE worker — possibly off the main thread, hence gcsafe. zjs-only:
# look up the worker's recorded engine and dispatch to zjs.
proc worker_eval_js*(workerId, js: cstring) {.exportc, cdecl, gcsafe.} =
  if zapp_worker_registry_get_engine(workerId) == ZAPP_ENGINE_ZJS:
    zjs_worker_eval_js(workerId, js)

# worker_terminate (worker.zc:217-223).
proc worker_terminate*(workerId: cstring) {.exportc, cdecl, gcsafe.} =
  if zapp_worker_registry_get_engine(workerId) == ZAPP_ENGINE_ZJS:
    zjs_worker_terminate(workerId)

# worker_terminate_owner (worker.zc:227-236): forward to every compiled-in
# engine's terminate_owner (zjs only here).
proc worker_terminate_owner*(ownerId: cstring) {.exportc, cdecl, gcsafe.} =
  zjs_worker_terminate_owner(ownerId)

# --- Worker → owner-window delivery (port of app.zc:184-275) ----------------

# Deliver one worker message to one owner window (port of
# app.zc:worker_dispatch_to_window, 184-243). Resolve the owner "win-<n>" id
# string → numeric, build the _onWorkerMessage IIFE (workerId + dataJson each
# encoded as a complete, safe JS string literal via zapp_js_lit_dup — finding
# #2), eval it, then free every libc buffer. gcsafe + libc: worker-thread-
# reachable. The IIFE shape mirrors app.zc:220-223 (the `'%s'` template is now
# `%s` since the literal carries its own quotes).
proc dispatchToWindow(workerId, dataJson, ownerId: cstring) {.gcsafe.} =
  let numericId = nativeWindowNumericIdForString(ownerId)
  if numericId < 0: return

  let escWid = zapp_js_lit_dup(workerId)
  if escWid == nil: return
  let escData = zapp_js_lit_dup(dataJson)
  if escData == nil:
    c_free(escWid)
    return

  const tmpl = cstring(
    "(function(){var b=globalThis[Symbol.for('zapp.bridge')];" &
    "if(b&&typeof b._onWorkerMessage==='function'){" &
    "b._onWorkerMessage(%s,%s);}})();")
  let needed = c_snprintf(nil, 0, tmpl, escWid, escData)
  if needed < 0:
    c_free(escWid); c_free(escData)
    return
  let js = cast[ptr char](c_malloc(csize_t(needed) + 1))
  if js == nil:
    c_free(escWid); c_free(escData)
    return
  discard c_snprintf(js, csize_t(needed) + 1, tmpl, escWid, escData)
  c_free(escWid)
  c_free(escData)

  nativeWindowEvalJs(numericId, cast[cstring](js))
  c_free(js)

# worker_dispatch_to_webview (app.zc:245-275). REPLACES the zapp.nim stub.
# zjs.c:645 calls this (possibly on a worker pthread) and owns + free()s both
# args after we return — so we neither free nor retain them, only copy into the
# eval JS. Dedicated workers deliver to their single owner; headless workers
# have an empty owner ("") and the guard below correctly drops the delivery.
# gcsafe + libc only.
proc worker_dispatch_to_webview*(workerId, dataJson: cstring)
    {.exportc, cdecl, gcsafe.} =
  # Dedicated worker — single owner.
  let owner = registryFirstOwner(workerId)
  if owner[0] != '\0':
    dispatchToWindow(workerId, dataJson, owner)
