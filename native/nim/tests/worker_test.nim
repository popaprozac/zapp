## Unit test for the pure bits of worker.nim — primarily zappResolveEngine
## (zjs-only build → always 7). The delivery path (dispatchToWindow /
## worker_dispatch_to_webview) is exercised at runtime against the real engine +
## window layer (human smoke, Task 2 Step 4); here we only need the engine
## resolver, which is pure (libc fprintf + a registry display-name read).
##
## worker.nim importc's the zjs engine + window + escape C symbols; none are
## CALLED by these tests, but the link needs them, so stub them as {.exportc.}
## Nim defs — the permissions_test / callbacks_test pattern. The registry C-ABI
## (set_engine/get_engine/get_display_name) is satisfied by the real
## registry.nim (transitively imported by worker.nim). zappResolveEngine is
## exported, so a plain `import` reaches it.

import ../worker

# Stub the importc'd engine + window + escape symbols worker.nim links against
# (never called by the resolver tests — only the link needs them).
proc zjs_worker_create(scriptUrl, ownerId, workerId: cstring): bool
  {.exportc, cdecl.} = false
proc zjs_worker_post_message(workerId, dataJson: cstring) {.exportc, cdecl.} = discard
proc zjs_worker_terminate(workerId: cstring) {.exportc, cdecl.} = discard
proc zjs_worker_terminate_owner(ownerId: cstring) {.exportc, cdecl.} = discard
proc zjs_worker_eval_js(workerId, js: cstring) {.exportc, cdecl.} = discard
proc darwin_window_numeric_id_for_string(wid: cstring): int32
  {.exportc, cdecl.} = -1
proc darwin_window_eval_js(numericId: int32, js: cstring) {.exportc, cdecl.} = discard
proc zapp_escape_dup(s: cstring): cstring {.exportc, cdecl.} = s

proc test() =
  # zjs-only build: every request resolves to zjs (7). 7 honored; -1 (no
  # preference, the default path) and an explicit non-7 both fall back to 7.
  doAssert zappResolveEngine(7, cstring"w-1") == 7
  doAssert zappResolveEngine(-1, cstring"w-1") == 7
  doAssert zappResolveEngine(3, cstring"w-1") == 7    # explicit bare-v8 → downgrade to zjs
  doAssert zappResolveEngine(2, cstring"w-1") == 7
  doAssert zappResolveEngine(6, cstring"w-1") == 7
  echo "worker ok"

test()
