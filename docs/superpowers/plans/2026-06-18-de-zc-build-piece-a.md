# De-zc the Nim build (piece A) — JsonNode provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the per-build `zc transpile` of the JsonValue provider from the Nim build by reimplementing the JsonValue C-ABI as a Nim module whose values *are* `std/json` `JsonNode`s.

**Architecture:** The C-ABI seam between `zjs.c` (C) and the service layer is unchanged. The nine write-side symbols `zjs.c` externs (`JsonValue__{null,bool,number,string,array,object}_ptr`, `json_object_set_owned`, `json_array_push_owned`, `json_free_tree`) become `{.exportc, cdecl.}` Nim procs that build/mutate a `JsonNode` and return it as the opaque `pointer` `zjs.c` already treats it as. `service_invoke_native` casts that pointer straight back to `JsonNode` — no walk, no second tree. `zjs.c` is write-only on the value and never dereferences the pointer, so this is parity-safe by construction (the zc build keeps resolving the same symbols to zc's `std/json`).

**Tech Stack:** Nim (`--mm:orc --threads:on`), `std/json`, GC_ref/GC_unref FFI ownership, Bun/TypeScript CLI.

**Spec:** `docs/superpowers/specs/2026-06-18-de-zc-build-design.md` (piece A; piece B deferred).

**Closes:** #502 (`{.emit.}` JsonValue mirror), #503 (hardcoded `$HOME` provider `.o` passL — present in **two** test files).

---

## File Structure

- **Create** `native/nim/jsonvalue.nim` — the JsonValue C-ABI provider (Nim). Owns the nine `{.exportc.}` symbols + the `withArgsNode` borrow helper. One responsibility: bridge the C write-side API to `JsonNode`.
- **Create** `native/nim/tests/jsonvalue_test.nim` — standalone unit test for the provider (build via C-ABI → read as `JsonNode` → free; leak/double-free stress).
- **Modify** `native/nim/worker_service.nim` — delete the `{.emit.}` mirror + `JsonType` consts + opaque types + Vec/Map accessor imports + `jsonValueToNode`; `service_invoke_native` borrows the incoming pointer as a `JsonNode`; `import jsonvalue`.
- **Modify** `native/nim/tests/worker_service_test.nim` — drop the `$HOME` passL + the `{.emit.}` bypass machinery + the walker/guard tests; keep the snapshot test; add an echo args round-trip built with the real `jsonvalue` builders.
- **Modify** `native/nim/tests/worker_service_thread_test.nim` — drop the `$HOME` passL line (nil-args test needs nothing from the provider once `worker_service.nim` stops importc-ing accessors).
- **Modify** `cli/src/native.ts` — delete the provider `zc transpile → clang -c → .o` block and the `--passL:${providerO}` flag.
- **Delete** `native/nim/zjson_provider.zc`.
- **Modify** `native/nim/zapp.nim` — update the now-stale comment block describing the provider `.o` (the JsonValue C-ABI is now `native/nim/jsonvalue.nim`, compiled in via the module graph; no external `.o`/passL).
- **Modify** `docs/nim-migration-roadmap.md` — mark gap #2 piece A done, piece B deferred.

---

### Task 1: JsonValue provider in Nim + unit test (TDD, additive)

This task is pure-additive — it creates two new files and changes no build wiring, so it cannot break the existing build (the new test binary does **not** link the old `zjson_provider.o`; there is no symbol clash because nothing compiles `jsonvalue.nim` into the app yet).

**Files:**
- Create: `native/nim/jsonvalue.nim`
- Test: `native/nim/tests/jsonvalue_test.nim`

- [ ] **Step 1: Write the failing test.** Create `native/nim/tests/jsonvalue_test.nim`:

```nim
# Unit test for the Nim JsonValue C-ABI provider (jsonvalue.nim).
# Builds JSON trees through the SAME C-ABI symbols zjs.c calls, reads them back
# by casting the opaque pointer to a std/json JsonNode (the production read
# path), and frees them via json_free_tree. Also stresses build+free to surface
# leaks / double-frees under ORC.
import ../jsonvalue
import std/json

proc test() =
  # free(nil) is a no-op
  jsonFreeTree(nil)

  # --- scalars round-trip ---
  block:
    let p = jvNull()
    doAssert (cast[JsonNode](p)).kind == JNull
    jsonFreeTree(p)
  block:
    let p = jvBool(true)
    doAssert cast[JsonNode](p) == newJBool(true)
    jsonFreeTree(p)
  block:
    # integral double → JInt (matches the old jsonValueToNode coercion)
    let p = jvNumber(42.0)
    let n = cast[JsonNode](p)
    doAssert n.kind == JInt and n.getInt == 42
    jsonFreeTree(p)
  block:
    let p = jvNumber(3.5)
    doAssert (cast[JsonNode](p)).kind == JFloat
    jsonFreeTree(p)
  block:
    let p = jvString(cstring"hi")
    doAssert cast[JsonNode](p) == newJString("hi")
    jsonFreeTree(p)
  block:
    # nil cstring → empty string, not a crash
    let p = jvString(nil)
    doAssert cast[JsonNode](p) == newJString("")
    jsonFreeTree(p)

  # --- nested object {"s":"y","n":7,"ok":true,"xs":[1,2],"sub":{"a":1}} ---
  block:
    let obj = jvObject()
    jsonObjectSetOwned(obj, cstring"s", jvString(cstring"y"))
    jsonObjectSetOwned(obj, cstring"n", jvNumber(7.0))
    jsonObjectSetOwned(obj, cstring"ok", jvBool(true))
    let xs = jvArray()
    jsonArrayPushOwned(xs, jvNumber(1.0))
    jsonArrayPushOwned(xs, jvNumber(2.0))
    jsonObjectSetOwned(obj, cstring"xs", xs)
    let sub = jvObject()
    jsonObjectSetOwned(sub, cstring"a", jvNumber(1.0))
    jsonObjectSetOwned(obj, cstring"sub", sub)

    let node {.cursor.} = cast[JsonNode](obj)
    doAssert node.kind == JObject
    doAssert node["s"] == newJString("y")
    doAssert node["n"].getInt == 7
    doAssert node["ok"] == newJBool(true)
    doAssert node["xs"].kind == JArray and node["xs"].len == 2
    doAssert node["xs"][0].getInt == 1 and node["xs"][1].getInt == 2
    doAssert node["sub"]["a"].getInt == 1
    jsonFreeTree(obj)   # single GC_unref on root → ORC cascades the free

  # --- build+free stress: net-zero refcount per iteration, no growth ---
  for i in 0 ..< 2000:
    let o = jvObject()
    jsonObjectSetOwned(o, cstring"k", jvString(cstring"v"))
    let a = jvArray()
    jsonArrayPushOwned(a, jvNumber(float(i)))
    jsonObjectSetOwned(o, cstring"xs", a)
    jsonFreeTree(o)

  echo "jsonvalue ok"

test()
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --mm:orc --threads:on -o:/tmp/jv tests/jsonvalue_test.nim`
Expected: FAIL — `cannot open file: ../jsonvalue` (module does not exist yet).

- [ ] **Step 3: Write the provider.** Create `native/nim/jsonvalue.nim`:

```nim
## JsonValue C-ABI provider (Nim) — replaces the zc-transpiled
## .zapp/zjson_provider.o.
##
## zjs.c (C) builds JSON argument trees on the worker pthread via the
## JsonValue__* / json_*_owned / json_free_tree symbols below, hands the opaque
## pointer to service_invoke_native, which casts it straight back to a std/json
## JsonNode (no walk). zjs.c is WRITE-ONLY on the value and never dereferences
## the pointer, so the opaque token can be a Nim JsonNode masquerading as the
## `JsonValue*` zjs.c externs. The zc build keeps resolving these symbols to
## zc's std/json — the seam signature is identical in both builds.
##
## Memory model (mirrors the manual-C ownership zjs.c relies on):
##   - Constructors: newX() (refcount 1), GC_ref (2); the owning local's
##     scope-exit decref (→1) leaves net refcount 1 = the "C pin" zjs.c holds.
##   - _owned setters: absorb the child into the parent container (which increfs
##     it), then GC_unref the child's construction pin → the container is sole
##     owner. Casts bind to {.cursor.} locals so ORC inserts no stray decref.
##   - json_free_tree: one GC_unref on the root; ORC cascades the free.
##
## Everything here runs on the worker pthread, where foreign-thread GC is
## already initialised (zapp_worker_thread_gc_init) before any symbol is
## reachable, so ORC alloc/free is safe.
import std/json

# JS numbers are all doubles; represent an integral double as JInt so handlers
# see ints (matches the coercion the old jsonValueToNode walker did).
proc numberNode(n: float): JsonNode =
  if n == float(int64(n)) and n >= float(low(int64)) and n <= float(high(int64)):
    newJInt(int64(n))
  else:
    newJFloat(n)

proc jvNull*(): pointer {.exportc: "JsonValue__null_ptr", cdecl.} =
  let n = newJNull(); GC_ref(n); cast[pointer](n)

proc jvBool*(b: bool): pointer {.exportc: "JsonValue__bool_ptr", cdecl.} =
  let n = newJBool(b); GC_ref(n); cast[pointer](n)

proc jvNumber*(n: cdouble): pointer {.exportc: "JsonValue__number_ptr", cdecl.} =
  let node = numberNode(n.float); GC_ref(node); cast[pointer](node)

proc jvString*(s: cstring): pointer {.exportc: "JsonValue__string_ptr", cdecl.} =
  # Copies s — zjs.c passes a transient buffer.
  let n = newJString(if s.isNil: "" else: $s); GC_ref(n); cast[pointer](n)

proc jvArray*(): pointer {.exportc: "JsonValue__array_ptr", cdecl.} =
  let n = newJArray(); GC_ref(n); cast[pointer](n)

proc jvObject*(): pointer {.exportc: "JsonValue__object_ptr", cdecl.} =
  let n = newJObject(); GC_ref(n); cast[pointer](n)

proc jsonObjectSetOwned*(obj: pointer, key: cstring, val: pointer)
    {.exportc: "json_object_set_owned", cdecl.} =
  if obj.isNil or val.isNil: return
  let o {.cursor.} = cast[JsonNode](obj)
  let v {.cursor.} = cast[JsonNode](val)
  o[if key.isNil: "" else: $key] = v   # JObject slot increfs v; copies the key
  GC_unref(v)                          # release the child's construction pin

proc jsonArrayPushOwned*(arr: pointer, val: pointer)
    {.exportc: "json_array_push_owned", cdecl.} =
  if arr.isNil or val.isNil: return
  let a {.cursor.} = cast[JsonNode](arr)
  let v {.cursor.} = cast[JsonNode](val)
  a.add v               # JArray seq increfs v
  GC_unref(v)           # release the child's construction pin

proc jsonFreeTree*(v: pointer) {.exportc: "json_free_tree", cdecl.} =
  if v.isNil: return
  let n {.cursor.} = cast[JsonNode](v)
  GC_unref(n)           # ORC cascades the free through the graph

template withArgsNode*(p: pointer, body: untyped) =
  ## Borrow a C-owned JsonNode for the duration of `body` WITHOUT taking
  ## ownership (handlers are pure-only on the worker invoke path; C still owns
  ## and frees via json_free_tree). nil → a fresh JNull (the "no args" case).
  ## Injects `argsNode: JsonNode` into `body`.
  if p == nil:
    let argsNode {.inject.} = newJNull()
    body
  else:
    let argsNode {.inject, cursor.} = cast[JsonNode](p)
    body
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `cd /Users/zach/code/zapp/native/nim && nim c -r --hints:off --mm:orc --threads:on -o:/tmp/jv tests/jsonvalue_test.nim`
Expected: PASS — prints `jsonvalue ok`, exit 0. (If it crashes/double-frees, the ownership model is wrong — re-check the GC_ref/GC_unref accounting against the module doc-comment.)

- [ ] **Step 5: Commit.**

```bash
cd /Users/zach/code/zapp
git add native/nim/jsonvalue.nim native/nim/tests/jsonvalue_test.nim
git commit -m "feat(nim): JsonValue C-ABI provider as a JsonNode-backed Nim module

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Atomic cutover — wire jsonvalue.nim in, delete the zc provider

This task must land as one commit: it removes the `zjson_provider.o` (and its `zc transpile`) AND switches every consumer to `jsonvalue.nim` in the same step, so the build never has two definitions of the nine symbols at once.

**Files:**
- Modify: `native/nim/worker_service.nim`
- Modify: `native/nim/tests/worker_service_test.nim`
- Modify: `native/nim/tests/worker_service_thread_test.nim`
- Modify: `cli/src/native.ts`
- Modify: `native/nim/zapp.nim`
- Delete: `native/nim/zjson_provider.zc`

- [ ] **Step 1: Rewrite the read path in `worker_service.nim`.** Delete the entire JsonValue mirror region — from the comment block starting `# JsonValue C-ABI mirror (Task 4: ...` (the line above the first `# ---` header at ~line 16) through the end of `jsonValueToNode` and its trailing `# ---` separator (~line 155). Concretely, remove: the explanatory comments, the `{.emit: """ ... """.}` block, the `JSON_KIND_*` `const` block, the `CJsonValue`/`CVecJVPtr`/`CMapJVPtr`/`CJsonValueS` type block, the `vecJVLen`/`vecJVGet`/`mapJVCap`/`mapJVOccupied`/`mapJVKeyAt`/`mapJVValAt` importc procs, and the whole `proc jsonValueToNode(...)`.

Then add the `jsonvalue` import next to the other imports at the top (after `import bridge`):

```nim
import jsonvalue     # JsonValue C-ABI provider (compiled into the build) + withArgsNode
```

And replace the body of `service_invoke_native` so it borrows the args pointer as a JsonNode instead of walking it:

```nim
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
```

Leave the async main-thread path (`zapp_worker_invoke_on_main`, which uses `parseJson`) untouched.

- [ ] **Step 2: Rewrite `worker_service_test.nim`.** Replace the whole file with the slimmed version (no `$HOME` passL, no `{.emit.}` bypass, no walker/guard tests; snapshot test kept; echo round-trip rebuilt on the real `jsonvalue` builders):

```nim
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
```

- [ ] **Step 3: Fix `worker_service_thread_test.nim`.** Remove the two lines (the NOTE comment + the passL):

```nim
# NOTE: hardcoded provider .o path — tracked follow-up (portability).
{.passL: "/Users/zach/code/zapp/kitchen-sink/.zapp/zjson_provider.o".}
```

No other change — the test only calls `service_invoke_native(nil, "greet", nil)` / a missing method with nil args, and `worker_service.nim` now pulls in `jsonvalue.nim` (pure Nim) for its symbols, so no external object needs linking.

- [ ] **Step 4: Run the three Nim tests to verify they pass.**

```bash
cd /Users/zach/code/zapp/native/nim
nim c -r --hints:off --mm:orc --threads:on -o:/tmp/jv  tests/jsonvalue_test.nim
nim c -r --hints:off --mm:orc --threads:on -o:/tmp/ws  tests/worker_service_test.nim
nim c -r --hints:off --mm:orc --threads:on -o:/tmp/wst tests/worker_service_thread_test.nim
```
Expected: all three print their `ok` line and exit 0.

- [ ] **Step 5: Strip the provider block from `cli/src/native.ts`.** Delete the entire JsonValue-provider emit block — from the comment `// Emit the JsonValue C-ABI object for the Nim build to link against.` through the closing brace of the `clangCode !== 0` error check (the `const providerZc/providerC/providerO`, the `zc transpile` spawn, and the `clang -c` spawn). Replace it with a single comment:

```ts
  // JsonValue C-ABI: provided by native/nim/jsonvalue.nim (compiled into the Nim
  // build via the module graph — worker_service.nim imports it). No zc transpile,
  // no external .o. zjs.c links the nine JsonValue__*/json_*_owned/json_free_tree
  // symbols straight from the Nim binary.
```

Then remove the provider passL: in the comment above the `nim c` args (the block beginning `// Link the JsonValue C-ABI provider object emitted just above.`), delete those provider-specific lines but keep the `// --threads:on — zjs spawns a pthread per worker; ORC must be thread-safe.` line. And in the args array, remove the `` `--passL:${providerO}`, `` element:

```ts
  const args = ["c", "--cc:clang", "--mm:orc", "--threads:on", "-d:release", "--opt:size",
                `--path:${zappDir}`, `--path:${nimFrameworkDir}`,
                `-o:${output}`, ...(verbose ? [] : ["--hints:off"]), nimRoot];
```

- [ ] **Step 6: Update the stale comment in `native/nim/zapp.nim`.** In the `# zjs worker engine` comment block (~lines 175–186), replace the sentences describing the provider `.o` / `--passL:<...>/zjson_provider.o` with: the JsonValue C-ABI is provided by `native/nim/jsonvalue.nim` (in the module graph via `worker_service`), so there is no external provider object and no provider passL. Keep the `libzjs.dylib` linking lines (191–198) exactly as-is.

- [ ] **Step 7: Delete the zc provider.**

```bash
cd /Users/zach/code/zapp
git rm native/nim/zjson_provider.zc
```

- [ ] **Step 8: Build the kitchen-sink app on the Nim path (full end-to-end).**

Run: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build`
Expected: the build completes and the LAST line is `[zapp] build complete: ...` (per the verify-native-build rule — Vite's `✓ built` is NOT sufficient). The produced binary is fresh. If the link fails with an undefined `JsonValue__*` symbol, the `{.exportc.}` procs were dead-code-eliminated → add `{.used.}` to each provider proc in `jsonvalue.nim` and rebuild.

- [ ] **Step 9: Run the CLI + TS gates.**

```bash
cd /Users/zach/code/zapp
bun test cli/src
bunx tsc --noEmit
```
Expected: `bun test` green (no native.ts test regressed); `tsc` shows only the pre-existing baseline errors (no new ones from the native.ts edit).

- [ ] **Step 10: Commit.**

```bash
cd /Users/zach/code/zapp
git add native/nim/worker_service.nim native/nim/tests/worker_service_test.nim \
        native/nim/tests/worker_service_thread_test.nim cli/src/native.ts native/nim/zapp.nim
git commit -m "refactor(nim): drop the zc JsonValue provider; service_invoke_native borrows JsonNode

zjs.c now links the JsonValue C-ABI straight from native/nim/jsonvalue.nim
(JsonNode-backed). Removes the per-build 'zc transpile' + clang -c + --passL of
zjson_provider.o, the {.emit.} struct mirror + walker (#502), and the hardcoded
\$HOME provider .o passL in both worker_service tests (#503).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Docs + definitive zc-free proof

**Files:**
- Modify: `docs/nim-migration-roadmap.md`
- (Check) any other doc that names `zjson_provider` / the provider `.o`

- [ ] **Step 1: Sweep docs for stale provider references.**

Run: `cd /Users/zach/code/zapp && grep -rn "zjson_provider\|JsonValue provider\|provider\.o" docs/ --include='*.md'`
Expected: a short list. Update each prose mention to reflect that the JsonValue C-ABI is now `native/nim/jsonvalue.nim` (no zc transpile). Do NOT touch the spec/plan files under `docs/superpowers/` (they are historical records).

- [ ] **Step 2: Update `docs/nim-migration-roadmap.md`.** Mark gap #2 as: **piece A done** (per-build `zc transpile` of the JsonValue provider removed; JsonValue C-ABI is now `native/nim/jsonvalue.nim`, JsonNode-backed; closes #502/#503), **piece B deferred** (zjs already links a prebuilt `libzjs.dylib` without zc per build; committing a vendored artifact is deferred until a zc-less machine needs it — see the spec's "Piece B — deferred"). Match the file's existing gap-checklist format.

- [ ] **Step 3: Definitive proof — the Nim build no longer invokes zc.**

First, the deterministic check (no zc spawn remains in the Nim build path):
Run: `cd /Users/zach/code/zapp && grep -n '"zc"' cli/src/native.ts`
Expected: no match inside `buildNativeNim` (the only `zc` references, if any, are in the zc/default path — confirm none are in the Nim branch).

Then the end-to-end proof (zc off `PATH`, prebuilt `libzjs.dylib` already present):
```bash
cd /Users/zach/code/zapp/kitchen-sink
ZC_DIR=$(dirname "$(command -v zc)")
env PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vx "$ZC_DIR" | paste -sd: -)" \
    ZAPP_NATIVE_LANG=nim bun run build
```
Expected: build completes with a final `[zapp] build complete: ...` line **even though `zc` is not on `PATH`** — proving piece A removed the per-build zc dependency. (If `bun`/`nim`/`clang` happen to share `ZC_DIR`, fall back to the deterministic grep proof + a normal build and note it.)

- [ ] **Step 4: Commit.**

```bash
cd /Users/zach/code/zapp
git add docs/
git commit -m "docs: de-zc gap #2 piece A shipped (JsonNode provider); pieceB deferred

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## After all tasks

- **Human GUI smoke (parked gate):** launch the kitchen-sink Nim build and exercise a worker→service sync invoke (the "greet/echo from worker" path) to confirm args still arrive intact through the JsonNode borrow. Build-level gates above prove compilation + unit behavior; this confirms the live path.
- **Final cross-implementation review** (subagent, per subagent-driven-development): confirm `jsonvalue.nim`'s `{.exportc.}` signatures match `zjs.c`'s `extern` declarations exactly (names, param types, return types), that the seam signature is identical across the zc and Nim builds, and that the GC ownership model has no leak/double-free path.

## Self-Review notes (author)

- **Spec coverage:** piece A's three spec components — provider→Nim/JsonNode (Task 1+2), consumer borrow + mirror deletion (Task 2 Step 1), build-wiring removal (Task 2 Steps 5–7) — each map to tasks. Testing (jsonvalue unit + worker_service + thread test + kitchen-sink + zc-off-PATH) is covered. #502/#503 closed in Task 2. Piece B is explicitly out of scope.
- **Type consistency:** provider proc names (`jvNull/jvBool/jvNumber/jvString/jvArray/jvObject/jsonObjectSetOwned/jsonArrayPushOwned/jsonFreeTree`) + the `withArgsNode` template are used identically in the tests and `worker_service.nim`. The C-ABI names in `{.exportc.}` (`JsonValue__*_ptr`, `json_*_owned`, `json_free_tree`) match `zjs.c`'s externs verbatim.
- **Ownership model** is stated once in the module doc-comment and relied on consistently (construct = GC_ref; transfer = GC_unref child; free = GC_unref root; borrow = `{.cursor.}`).
