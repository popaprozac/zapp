# Nim Breadth Batch 7a — Worker Registry (idiomatic Nim port, Approach B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Port `native/worker/registry.zc` → `native/nim/registry.nim` as a faithful **POD + `{.gcsafe.}`** translation (the worker registry is read — and its supervisor counters written — from worker pthreads), un-stubbing `Workers.list()` / worker display names / the supervisor. Approach B (idiomatic Nim port), per the user's decision (not compile-zc).

**Architecture:** A module-global `array[ZAPP_MAX_WORKERS, ZappWorkerEntry]` where `ZappWorkerEntry` is a Nim object mirroring the C struct **byte-for-byte in spirit** (`array[N, char]` fixed buffers + ints — NO Nim `string`/`seq`/`ref`, NO Nim GC). Every proc is `{.gcsafe.}` and uses libc (`strncpy`/`strcmp`/`strlen`/`snprintf`/`malloc`) via `importc`, exactly the `worker_service.nim` / `permissions.nim` discipline. This is the safe path for a lock-free static registry touched by worker threads.

**Tech Stack:** Nim (POD objects + libc importc), source of truth `native/worker/registry.zc`.

---

## Background

- **Branch:** `feat/nim-native`. macOS / Nim build. Decision doc: `docs/superpowers/specs/2026-06-16-nim-breadth-batch7-batch8-design.md` (Approach B chosen).
- **Thread discipline (load-bearing — this is why POD/gcsafe):**
  - **Worker-thread READS:** `zapp_worker_registry_get_engine`, `zapp_worker_registry_get_display_name`, `zapp_workers_registry_list_json`, `zapp_worker_supervisor_get_window_state`/`get_script_url`/`get_owner` (zjs.c/bare.c call these from worker threads — logging, crash, host-object `Workers.list`).
  - **Worker-thread WRITE (single-writer):** `zapp_worker_supervisor_record_failure` (the crashing worker's own thread increments its OWN entry's `fail_count` — no cross-entry contention).
  - **Main-thread WRITES:** `add*` (at create), `set_engine`, `remove` (at terminate), `add_owner`/`remove_owner`, `set_policy`. These happen at create/terminate, when the worker thread isn't racing its own entry.
  - **Lock-free** (mirror the zc — no mutex; the timing discipline above makes it safe). Do NOT add a Nim Lock (would force worker reads to contend + risk gcsafe issues).
- **`ZappWorkerEntry`** (registry.zc:26-46): `worker_id[64]`, `name[64]`, `script_url[256]`, `owners[16][64]`, `owner_count:int`, `shared:int`, `active:int`, `engine:int`, `restart_max:int`, `restart_window_ms:int`, `fail_count:int`, `fail_window_start_ms:int64`, `gave_up:int`. `ZAPP_MAX_WORKERS=64`, `ZAPP_MAX_OWNERS_PER_WORKER=16`. Engine ids: BARE_JSC=2, BARE_V8=3, BARE_QUICKJS=4, BARE_MQJS=5, BARE_HERMES=6, ZJS=7.
- **Current Nim-build state (verified via `nm`):** the registry add/get/set/remove/owner symbols are NOT defined or referenced yet (zjs.c does NOT register workers itself; the router worker path isn't ported). Only **5 registry-adjacent stubs** in zapp.nim are referenced by zjs.c's host-object/log/crash paths and must be REPLACED by the real ones: `zapp_workers_registry_list_json` (→"[]"), `zapp_worker_registry_get_display_name` (→""), `zapp_fmt_compact_ms` (→""), `zapp_worker_supervisor_record_failure` (→0), `zapp_worker_supervisor_get_window_state` (→0). The other add/get/set/owner/find/set_policy/get_script_url/get_owner functions are NEW exports (become live when B7b's routeWorker + headless registration call them). (The 2 NON-registry stubs `worker_post_message` / `worker_dispatch_to_webview` are the dispatcher's → B7b; leave them.)
- **C-ABI surface to export** (`{.exportc, cdecl, gcsafe.}`, names EXACT — engines/router/headless call them by C name; add `*` so the unit test can call them): `zapp_worker_registry_add`, `zapp_worker_registry_add_full_with_engine`, `zapp_worker_registry_add_full` (engine=-1 wrapper), `zapp_worker_registry_add_full_with_engine_and_name`, `zapp_worker_registry_add_full_with_name` (wrapper), `zapp_worker_registry_get_engine`, `zapp_worker_registry_set_engine`, `zapp_worker_registry_remove`, `zapp_worker_registry_is_shared`, `zapp_worker_registry_remove_owner`, `zapp_worker_registry_get_display_name`, `zapp_fmt_compact_ms`, `zapp_workers_registry_list_json`, `zapp_worker_supervisor_set_policy`, `zapp_worker_supervisor_record_failure`, `zapp_worker_supervisor_get_script_url`, `zapp_worker_supervisor_get_owner`, `zapp_worker_supervisor_get_window_state`. (The `static` helpers in registry.zc — `add`, `owner`, `find_shared`, `add_owner` — port as private Nim procs; `find_shared`/`add_owner` are used by B7b's router path so make them `*`-exported Nim procs even if not exportc'd as C — confirm during B7b.)
- **`list_json`** returns a heap `char*` the caller frees (libc `malloc` + `snprintf` building `[{"id":..,"name":..,"engine":..,"shared":..,"owners":[..]}, …]`). Port faithfully (read registry.zc:345-448 for the exact JSON shape). gcsafe (libc malloc, no Nim GC).
- **Supervisor time source:** read registry.zc's `record_failure` (lines 469-490) for how it gets current ms (`fail_window_start_ms`) — mirror its clock (libc `importc` — likely `gettimeofday`/`clock_gettime`; match exactly).
- **STANDING CONSTRAINTS — never `git add -A`.** Stage only `native/nim/registry.nim native/nim/tests/registry_test.nim native/nim/zapp.nim`. Never `hello-world/` etc. No `{.emit.}`. Do NOT edit `native/worker/**` or `native/platform/**`. Build ends `[zapp] build complete:`. Always Bun. Commit trailer last line EXACTLY `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/registry.nim` | POD `{.gcsafe.}` worker registry — the full C-ABI surface | Create |
| `native/nim/tests/registry_test.nim` | unit test (add/get/remove/owners/is_shared/list_json shape/supervisor counting) | Create |
| `native/nim/zapp.nim` | `import registry` (side-effect exportc) + delete the 5 registry stubs | Modify |

---

## Task 1: registry.nim (faithful POD/gcsafe port) + unit test + stub removal

**Files:** Create `native/nim/registry.nim`, `native/nim/tests/registry_test.nim`; modify `native/nim/zapp.nim`.

- [ ] **Step 1: Read the source of truth**

Read `native/worker/registry.zc` IN FULL (it is ~520 lines). It is the authoritative spec — port each function 1:1. Note the static-array model, the strncpy 63/255 truncation lengths, the `active` flag, the owner array, the list_json JSON shape (registry.zc:345-448), and the supervisor sliding-window logic (registry.zc:449-517) incl. its ms clock source.

- [ ] **Step 2: Write the failing unit test**

Create `native/nim/tests/registry_test.nim` testing the **pure** registry logic (the functions that don't need worker engines): `add_full_with_engine_and_name` → `get_engine`/`get_display_name`/`is_shared`; duplicate-id refresh-in-place; `remove` (clears active); owner add (via the shared path) + `remove_owner` returning the remaining count; `list_json` shape (parse the returned JSON, assert the entries); `supervisor_set_policy` + `record_failure` returning 0/1/2 across the window + `get_window_state`. Use the `permissions_test.nim`/`fs_test.nim` pattern (stub any importc the module pulls in that the test can't link — e.g. if `list_json`/`record_failure` reference a clock, the libc clock links fine; no stub needed for libc). Example shape:
```nim
import ../registry
proc test() =
  # add + read back
  discard zapp_worker_registry_add_full_with_engine_and_name(cstring"w-1", cstring"win-1", 0,
    cstring"/x.mjs", 7, cstring"Greeter")
  doAssert zapp_worker_registry_get_engine(cstring"w-1") == 7
  doAssert $zapp_worker_registry_get_display_name(cstring"w-1") == "Greeter"
  doAssert zapp_worker_registry_is_shared(cstring"w-1") == 0
  # display name falls back to id when unset
  discard zapp_worker_registry_add_full_with_engine(cstring"w-2", cstring"win-1", 0, cstring"/y.mjs", 7)
  doAssert $zapp_worker_registry_get_display_name(cstring"w-2") == "w-2"
  # list_json contains both (parse + assert)
  let j = $zapp_workers_registry_list_json()
  doAssert j.contains("w-1") and j.contains("Greeter") and j.contains("w-2")
  # remove
  zapp_worker_registry_remove(cstring"w-1")
  doAssert zapp_worker_registry_get_engine(cstring"w-1") == -1
  # supervisor: max=2 → 1st/2nd failure restart (1), 3rd gives up (2)
  zapp_worker_supervisor_set_policy(cstring"w-2", 2, 60000)
  doAssert zapp_worker_supervisor_record_failure(cstring"w-2") == 1
  doAssert zapp_worker_supervisor_record_failure(cstring"w-2") == 1
  doAssert zapp_worker_supervisor_record_failure(cstring"w-2") == 2
  echo "registry ok"
test()
```
(Adjust the supervisor assertions to match registry.zc's EXACT semantics after reading it — the 0/1/2 return contract + the window reset behavior are the source of truth.)

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off registry_test.nim 2>&1 | tail -5`
Expected: FAIL — `cannot open file: ../registry`.

- [ ] **Step 4: Create `native/nim/registry.nim`**

Port registry.zc faithfully. Structure:
```nim
## Worker registry — port of native/worker/registry.zc. POD + {.gcsafe.}: read
## (and supervisor counters written) from worker pthreads, so NO Nim GC — fixed
## array[N,char] buffers + libc string ops, the worker_service.nim/permissions.nim
## discipline. Lock-free (mirror the zc; main-thread add/remove, worker-thread
## single-writer supervisor counters).
const
  ZAPP_MAX_WORKERS = 64
  ZAPP_MAX_OWNERS_PER_WORKER = 16

type
  ZappWorkerEntry = object
    workerId: array[64, char]
    name: array[64, char]
    scriptUrl: array[256, char]
    owners: array[ZAPP_MAX_OWNERS_PER_WORKER, array[64, char]]
    ownerCount: cint
    shared: cint
    active: cint
    engine: cint
    restartMax: cint
    restartWindowMs: cint
    failCount: cint
    failWindowStartMs: int64
    gaveUp: cint

var gReg {.global.}: array[ZAPP_MAX_WORKERS, ZappWorkerEntry]

# libc (gcsafe, no Nim GC)
proc c_strncpy(dst: ptr char, src: cstring, n: csize_t): ptr char {.importc: "strncpy", cdecl, discardable.}
proc c_strcmp(a, b: cstring): cint {.importc: "strcmp", cdecl.}
proc c_strlen(s: cstring): csize_t {.importc: "strlen", cdecl.}
proc c_snprintf(buf: ptr char, n: csize_t, fmt: cstring): cint {.importc: "snprintf", cdecl, varargs.}
proc c_malloc(n: csize_t): pointer {.importc: "malloc", cdecl.}
# … + the ms clock registry.zc uses (match it) …
```
Then port each function as a `{.exportc, cdecl, gcsafe.}` proc with `*` (so the test can call by Nim name; the C symbol is the exportc name). Use `addr entry.workerId[0]` for the `ptr char` buffer base + `cast[cstring](addr entry.workerId[0])` to read. Mirror the zc's strncpy lengths (63/255), the active-flag scan, the idempotent refresh-in-place, the owner array, the list_json malloc+snprintf JSON build, and the supervisor window logic EXACTLY.
(The verbose POD style is intentional — it is the safe, faithful translation. Do NOT use Nim `string`/`seq` for entry fields or on any worker-reachable path.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off registry_test.nim 2>&1 | tail -5`
Expected: last line `registry ok`. Fix until green. (gcsafe violations → a Nim GC type leaked onto a proc; convert to POD/libc.)

- [ ] **Step 6: Wire registry.nim into the build + delete the 5 stubs**

In `native/nim/zapp.nim`: add `import registry` to the `{.push warning[UnusedImport]: off.}` import group (it's imported only for its `{.exportc.}` side-effect symbols). DELETE the 5 registry stubs: `zapp_workers_registry_list_json`, `zapp_worker_registry_get_display_name`, `zapp_fmt_compact_ms`, `zapp_worker_supervisor_record_failure`, `zapp_worker_supervisor_get_window_state` (registry.nim now provides the real ones). LEAVE `worker_post_message` / `worker_dispatch_to_webview` (those are B7b's dispatcher stubs).

- [ ] **Step 7: Full Nim build**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -5`
Expected: last line `[zapp] build complete: <path>`. (A `duplicate symbol _zapp_workers_registry_list_json` etc. → a stub wasn't deleted. Undefined → an exportc name typo vs zjs.c's extern.) Do NOT `git add` hello-world/.

- [ ] **Step 8: Regression — all Nim unit tests**

Run: `cd /Users/zach/code/zapp/native/nim/tests && for t in registry_test dialog_test fs_test permissions_test router_subscribe_test callbacks_test dispatch_test appconfig_test service_cabi_test worker_service_test; do [ -f $t.nim ] && nim c -r --hints:off $t.nim 2>&1 | tail -1; done`
Expected: each prints its `… ok` line (incl. `registry ok`).

- [ ] **Step 9: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/registry.nim native/nim/tests/registry_test.nim native/nim/zapp.nim
git commit -m "$(printf 'feat(nim): registry.nim — worker registry (POD/gcsafe port, Batch 7a)\n\nFaithful POD + gcsafe port of native/worker/registry.zc (fixed array[N,char]\nbuffers + libc, no Nim GC — read + supervisor-written from worker pthreads;\nlock-free, main-thread add/remove). Provides the full C-ABI registry surface\n(add/get/set/remove/owners/is_shared/find_shared/list_json/display_name/\nsupervisor/fmt_compact_ms) + replaces the 5 zapp.nim registry stubs. Approach B\n(idiomatic Nim port). Unit-tested. Becomes live when B7b wires routeWorker.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Self-Review

**1. Spec coverage:** registry.nim faithful POD/gcsafe port → Steps 1,4; the full exportc surface → Step 4; 5 stubs replaced → Step 6; unit-tested pure logic → Steps 2,5; build+regression → Steps 7,8. ✓
**2. Placeholder scan:** No TBD/TODO. The "read registry.zc + match exactly" directives are the source-of-truth instruction (the zc is 520 LOC — faithful translation, not a guessed re-spec), with the POD/gcsafe discipline + the exact struct + surface + thread rules pinned. The unit-test supervisor assertions are explicitly "adjust to registry.zc's exact semantics."
**3. Type consistency:** `ZappWorkerEntry` mirrors the C struct (array[N,char] + cint + int64); the exportc names match zjs.c's externs (verified surface list); `{.gcsafe.}` enforced (the worker-read path is POD/libc); `list_json` returns a libc-malloc'd cstring the caller frees (matches the zc); no Nim string/seq on any entry field or worker-reachable proc. ✓
