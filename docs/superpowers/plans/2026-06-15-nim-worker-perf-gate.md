# Nim Worker Host-Object Perf Gate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove a worker's `Services.invokeSync` round-trip through a **Nim** `service_invoke_native` matches the Zen-C (`zc`) baseline within 15% — the non-negotiable gate before breadth-porting.

**Architecture:** zjs's `host_invoke_service` (C, unchanged) builds a `JsonValue` tree and calls `service_invoke_native(app, method, JsonValue*)`. We make that seam Nim `{.exportc, cdecl, gcsafe.}` with an **allocation-free** dispatch (so ORC never runs on the zjs worker pthread), compile `zjs.c` into the `nim c` build, link `libzjs.dylib` + the zc-emitted `JsonValue` implementation, spawn the existing bench worker, and compare `µs/op` against the zc build on the same harness.

**Tech Stack:** Nim 2.2.10 (ORC, `--threads:on`), zjs (`vendor/zjs/build/libzjs.dylib`), the `zc` compiler (only to emit the shared `JsonValue` C object), `benchmarks/apps/zapp-host-bridge`. Spec: `docs/superpowers/specs/2026-06-15-nim-worker-perf-gate-design.md`.

---

## Working rules (read first)

- Branch `feat/nim-native`. NEVER edit `native/platform/**` or `native/worker/engines/zjs.c` (reused untouched; Nim `importc`/`exportc` across the C-ABI).
- Stage ONLY each task's files by explicit path. Never `git add -A`. Never stage user-WIP (`kitchen-sink/`, `vendor/*`, `hello-world/`, `spikes/`, `native/worker/engines/zjs-cross-eval-test.c`) or `.zapp/` artifacts.
- Commit trailer EXACTLY (last line): `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Idiomatic Nim, no `{.emit.}`.**
- **Allocation-free worker-thread rule (load-bearing):** `service_invoke_native` and the bench handlers run on the zjs worker pthread. They MUST NOT allocate Nim heap (no `$cstring`→`string`, no Nim `string` building, no Table keyed by Nim string). Compare method names by `cstring` (C `strcmp`, no alloc); return module-level/`{.global.}`-backed or constant `cstring`s. This keeps ORC off the worker thread (no `setupForeignThreadGc` needed). Mark these procs `{.gcsafe.}`.
- **Build success** = the CLI build's last line is `[zapp] build complete: <path>` + fresh binary mtime. The bench "result" = `[bench:zjs] …` lines on stderr.

## ABI reference (verbatim)

**Nim `{.exportc, cdecl.}` (called by the untouched `zjs.c`):**
```
const char* service_invoke_native(void* app, const char* method, JsonValue* args);  // REAL
void*       app_get_active(void);                                                    // sentinel (skeleton already has it)
bool        permissions_check(const char* id, const char* method);                  // stub -> true
const char* permission_id_for_invoke(const char* method);                           // stub -> ""
void        dispatch_event_to_all(const char* event_name, const char* payload);     // stub no-op
void        worker_post_message(char* worker_id, char* data_json);                  // stub no-op
int         zapp_worker_supervisor_record_failure(const char* worker_id);           // stub -> 0
int         zapp_worker_supervisor_get_window_state(const char*, int*, int*, int*); // stub -> 0
char*       zapp_workers_registry_list_json(void);                                   // stub -> "[]"
const char* zapp_worker_registry_get_display_name(const char* worker_id);           // stub -> ""
const char* zapp_fmt_compact_ms(int ms);                                            // stub -> ""
extern int  zapp_log_level;                                                          // provide = 0
// (zapp_build_use_embedded_assets / zapp_build_initial_url / zapp_embedded_assets[/count] /
//  zapp_ios_fetch_url_sync already provided by the generated config + skeleton stubs.)
```
> **Authoritative full list:** `grep -nE '^extern ' native/worker/engines/zjs.c` — Task 3 enumerates and satisfies ALL of them (real for `service_invoke_native`, sentinel/no-op/default for the rest).

**Nim `{.importc, cdecl.}` (provided by zjs.c / the zc JsonValue object):**
```
bool zjs_worker_create(const char* script_url, const char* owner_id, const char* worker_id);  // from zjs.h:19
```

**zjs link (macOS), from build-config.ts:1450-1454:**
```
cflags:  -I vendor/zjs/include
framework: Foundation
link:    vendor/zjs/build/libzjs.dylib  -Wl,-rpath,<abs vendor/zjs/build>
```
`libzjs.dylib` is present (`vendor/zjs/build/libzjs.dylib`); if missing, `make -C vendor/zjs`.

**Bench services (zc baseline, `benchmarks/apps/zapp-host-bridge/zapp/build.zc:6-21,38-39`):**
```
fn noop(_app: App*, _args: JsonValue*) -> string { return "{\"ok\":1}"; }
fn echo(_app: App*, _args: JsonValue*) -> string { return "{\"ok\":1}"; }
app.service.add("noop", noop);  app.service.add("echo", echo);
```
Both ignore args → the Nim equivalents are constant returns (trivially alloc-free). The MEDIUM case still exercises zjs.c's `JsonValue` tree-walk (C, unchanged).

---

## Task 0: Capture the zc-zjs baseline

**Files:** Create `benchmarks/nim-perf-gate/baseline.md` (the gate report; numbers recorded here).

- [ ] **Step 1: Build the bench app on the zc build**

Run:
```bash
cd /Users/zach/code/zapp/benchmarks/apps/zapp-host-bridge && bun run build 2>&1 | tail -4
```
Expected: last line `[zapp] build complete: <path>` (the default `zc` path — do NOT set `ZAPP_NATIVE_LANG`).

- [ ] **Step 2: Run it 3×, capture the zjs invokeService numbers**

Run (adapt the binary path from Step 1; the bench logs `[bench:zjs]` lines to stderr):
```bash
for i in 1 2 3; do "<bench binary path>" 2>&1 | grep '\[bench:zjs\]'; echo "--- run $i ---"; done
```
Expected: lines like `[bench:zjs] invokeService.small x10000: …, <N> us/op` and `invokeService.medium x1000: …`. If the app needs a window/interaction to start the worker, run it and let the headless worker fire on launch (it's a headless worker — starts at boot). Record all 3 runs.

- [ ] **Step 3: Record the baseline median**

Create `benchmarks/nim-perf-gate/baseline.md` with: machine, date, the 3 runs' `small`/`medium` µs/op, and the **median small µs/op** as `ZC_BASELINE_SMALL`. This is the number the Nim build must beat by ≤15%.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add benchmarks/nim-perf-gate/baseline.md
git commit -m "$(printf 'bench(nim): capture zc-zjs invokeService baseline (perf gate)\n\nbenchmarks/apps/zapp-host-bridge on the zc build, 3 runs, median us/op\nfor invokeService.small/.medium. The bar the Nim build must match within\n15%%.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 1: Link the zc-emitted `JsonValue` into the Nim build (the #1 risk)

**Goal:** zjs.c calls `JsonValue` constructors/accessors (from zc `std/json` + `json_safe`). The `nim c` build has no zc compilation, so those symbols are absent → link error. Provide them by compiling a tiny zc provider to an object and linking it. De-risk this FIRST — it's the one genuinely uncertain piece.

**Files:**
- Create: `native/nim/zjson_provider.zc`
- Modify: `cli/src/native.ts` (`buildNativeNim` — emit + link the object)

- [ ] **Step 1: Write the provider**

`native/nim/zjson_provider.zc`:
```
// Forces zc to emit the JsonValue implementation (std/json + the heap-safe
// json_safe parser) as C, so the Nim-linked zjs.c can build/read JsonValue
// trees. Reused untouched from the zc stdlib — NOT ported to Nim.
import "std/json.zc";
import "../bridge/json_safe.zc";
fn _zjson_anchor() -> int { return 0; }
```

- [ ] **Step 2: Emit it to an object + confirm the JsonValue symbols are present**

Run (try compile-only first; fall back to transpile+clang if `-c` doesn't behave):
```bash
cd /Users/zach/code/zapp
zc build -c native/nim/zjson_provider.zc -o /tmp/zjson_provider.o 2>&1 | tail -20 || \
  { zc transpile native/nim/zjson_provider.zc 2>&1 | tail -20; }
nm /tmp/zjson_provider.o 2>/dev/null | grep -iE 'JsonValue|zapp_json_parse' | head
```
Expected: an object at `/tmp/zjson_provider.o` whose symbols include the `JsonValue` constructors/accessors + `zapp_json_parse`. **Iterate** on the exact `zc` flags until you get an object with those symbols (this is the de-risk; record the working invocation). If `zc build -c` won't emit a partial object, use `zc transpile` to get the `.c`, then `clang -c <emitted.c> -I <zc include dirs> -o /tmp/zjson_provider.o`.

- [ ] **Step 3: Wire the provider object into `buildNativeNim`**

In `cli/src/native.ts` `buildNativeNim`, before the `nim c` spawn: emit the provider object into `.zapp/zjson_provider.o` (run the working command from Step 2, output into `.zapp/`), and add it to the Nim link via a `{.passL.}` the Nim root will carry (Task 3 adds the `{.passL.}` line; here just ensure the `.o` is produced at a known path, e.g. `<zappDir>/zjson_provider.o`). Log a clear line if `zc` is missing.
> Rationale to record: both the zc baseline and the Nim build now use the IDENTICAL zc-emitted JsonValue — so the only measured difference is `service_invoke_native`'s language. Whether breadth keeps this blob or ports JsonValue to Nim is a later decision (flag it; out of scope here).

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/zjson_provider.zc cli/src/native.ts
git commit -m "$(printf 'feat(nim): link zc-emitted JsonValue object into the Nim build\n\nzjs.c builds/reads JsonValue trees via the zc std/json + json_safe C-ABI;\nthe nim c build has no zc compilation, so emit those symbols from a tiny\nprovider .zc (zc -c -> .o) and link it. Both zc + nim builds now share the\nIDENTICAL JsonValue impl, isolating the measured diff to service_invoke_native.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 2: `worker_service.nim` — alloc-free `service_invoke_native`

**Files:**
- Create: `native/nim/worker_service.nim`
- Test: `native/nim/tests/worker_service_test.nim`

- [ ] **Step 1: Write a failing Nim test for alloc-free dispatch**

`native/nim/tests/worker_service_test.nim`:
```nim
import ../worker_service
# service_invoke_native takes (app, method, args). For the bench, args is opaque
# (handlers ignore it) — pass nil. noop/echo return the constant; unknown -> "".
proc test() =
  registerWorkerServices()
  doAssert $service_invoke_native(nil, cstring"noop", nil) == "{\"ok\":1}"
  doAssert $service_invoke_native(nil, cstring"echo", nil) == "{\"ok\":1}"
  doAssert $service_invoke_native(nil, cstring"missing", nil) == ""
  echo "worker_service ok"
test()
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd /Users/zach/code/zapp/native/nim && nim c --mm:orc --threads:on -r tests/worker_service_test.nim 2>&1 | tail -10`
Expected: FAIL — `worker_service` / `service_invoke_native` not defined.

- [ ] **Step 3: Implement `worker_service.nim` (mirrors zc's linear-scan + fn-ptr dispatch, alloc-free)**

```nim
## Worker-path service dispatch. service_invoke_native is the C-ABI seam zjs.c
## calls on the WORKER PTHREAD — so it is allocation-free (no Nim heap, no ORC):
## method names compared via cstring (C strcmp), results are module-level-backed
## cstrings. Mirrors native/service/service.zc's linear-scan + fn-ptr dispatch so
## the measured work matches the zc baseline.
type WorkerServiceFn = proc(app: pointer, args: pointer): cstring {.cdecl, gcsafe.}
type WorkerServiceEntry = object
  name: cstring
  fn: WorkerServiceFn

var gServices: array[16, WorkerServiceEntry]
var gServiceCount = 0

let okResult = "{\"ok\":1}"   # module-level: stable backing for the returned cstring

proc benchNoop(app: pointer, args: pointer): cstring {.cdecl, gcsafe.} = okResult.cstring
proc benchEcho(app: pointer, args: pointer): cstring {.cdecl, gcsafe.} = okResult.cstring

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
```

- [ ] **Step 4: Run it, verify it passes**

Run: `cd /Users/zach/code/zapp/native/nim && nim c --mm:orc --threads:on -r tests/worker_service_test.nim 2>&1 | tail -5`
Expected: PASS — prints `worker_service ok`.

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/worker_service.nim native/nim/tests/worker_service_test.nim
git commit -m "$(printf 'feat(nim): worker_service.nim — alloc-free service_invoke_native\n\nThe C-ABI seam zjs.c calls on the worker pthread: linear-scan + fn-ptr\ndispatch mirroring service.zc, but allocation-free (cstring strcmp compare,\nmodule-level-backed result) so ORC never runs on the worker thread. noop/echo\nbench handlers return constant {\"ok\":1}. Nim-tested.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 3: Compile `zjs.c` into the Nim build + satisfy its extern surface

**Files:**
- Modify: `native/nim/zapp.nim` (add the zjs `{.compile.}`/`{.passL.}` + the extern stubs + import worker_service)

- [ ] **Step 1: Enumerate zjs.c's extern orchestration surface**

Run: `grep -nE '^extern ' native/worker/engines/zjs.c`
Record every symbol. `service_invoke_native` (worker_service.nim) and `app_get_active` (skeleton sentinel) are REAL; the rest get Nim `{.exportc, cdecl.}` stubs (no-op/default per the ABI reference table). Anything already provided by the skeleton/generated config (asset getters, `zapp_build_*`) must NOT be re-defined (dedup).

- [ ] **Step 2: Add zjs compile + link + stubs to `native/nim/zapp.nim`**

Append the zjs wiring (call-form `{.compile.}`; absolute rpath):
```nim
import worker_service   # provides service_invoke_native (exportc)

{.passC: "-I " & currentSourcePath().parentDir & "/../worker/engines".}
{.passC: "-I " & currentSourcePath().parentDir & "/../../vendor/zjs/include".}
{.compile("../worker/engines/zjs.c", "-I../../vendor/zjs/include").}
{.passL: "-framework Foundation".}
{.passL: currentSourcePath().parentDir & "/../../vendor/zjs/build/libzjs.dylib".}
{.passL: "-Wl,-rpath," & currentSourcePath().parentDir & "/../../vendor/zjs/build".}
{.passL: currentSourcePath().parentDir & "/../../.zapp/zjson_provider.o".}  # Task 1 object

# zjs.c callback stubs (real ones live elsewhere): no-op/default. TEMP for the
# perf gate — breadth replaces with real ports. (Enumerate from Step 1; example:)
var zapp_log_level {.exportc.}: cint = 0
proc permissions_check(id: cstring, m: cstring): bool {.exportc, cdecl, gcsafe.} = true
proc permission_id_for_invoke(m: cstring): cstring {.exportc, cdecl, gcsafe.} = cstring""
proc dispatch_event_to_all(ev: cstring, payload: cstring) {.exportc, cdecl, gcsafe.} = discard
proc worker_post_message(wid: cstring, data: cstring) {.exportc, cdecl, gcsafe.} = discard
proc zapp_worker_supervisor_record_failure(wid: cstring): cint {.exportc, cdecl, gcsafe.} = 0
proc zapp_worker_supervisor_get_window_state(wid: cstring, c, cap, ms: ptr cint): cint {.exportc, cdecl, gcsafe.} = 0
proc zapp_workers_registry_list_json(): cstring {.exportc, cdecl, gcsafe.} = cstring"[]"
proc zapp_worker_registry_get_display_name(wid: cstring): cstring {.exportc, cdecl, gcsafe.} = cstring""
proc zapp_fmt_compact_ms(ms: cint): cstring {.exportc, cdecl, gcsafe.} = cstring""
# ...plus any others Step 1 surfaced not already provided. Reconcile vs existing
# skeleton stubs / generated config (no duplicate symbols).
```
> The `{.compile.}` must use the CALL form (3rd arg = per-file flags) — the tuple form drops flags. Build with `--threads:on` (Task 4 adds it to the CLI invocation) so zjs's pthreads + Nim coexist.

- [ ] **Step 3: Build the bench app on the Nim build; confirm it LINKS**

Run:
```bash
cd /Users/zach/code/zapp/benchmarks/apps/zapp-host-bridge && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -20
```
Expected: `[zapp] build complete:` (links clean). If undefined symbols: add the missing stub from Step 1 (or dedup a double-defined one). If `zjson_provider.o` symbols are missing, revisit Task 1. The worker won't spawn yet (Task 4) — linking is this task's gate.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/zapp.nim
git commit -m "$(printf 'feat(nim): compile zjs.c into the Nim build + stub its extern surface\n\n{.compile.} zjs.c + link libzjs.dylib + the zjson_provider.o; service_invoke_native\nis real (worker_service), the rest of zjs.c\\047s orchestration callbacks are Nim\nexportc no-op/default stubs (TEMP, breadth replaces). Build links.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 4: Spawn the bench worker (generated headless + CLI `--threads:on`)

**Files:**
- Modify: `cli/src/native.ts` (`buildNativeNim`: add `--threads:on`; generate `.zapp/zapp_headless.nim`)
- Modify: `cli/src/build-config.ts` (add `renderHeadlessNim` — zjs entries only)
- Modify: `native/nim/app.nim` (call `registerWorkerServices()` + `zapp_start_headless_workers()` in `run()`)

- [ ] **Step 1: `renderHeadlessNim` (zjs-only) in build-config.ts**

```ts
// Emits the Nim equivalent of generateHeadlessWorkers, zjs entries only.
export function renderHeadlessNim(headless: Record<string, {script?: string; engine?: string} | string>): string {
  const lines: string[] = [];
  for (const [id, v] of Object.entries(headless ?? {})) {
    const engine = typeof v === "string" ? undefined : v.engine;
    if (engine !== "zjs") continue;  // gate: zjs only for the perf gate
    const url = `/_workers/_headless_${id}.mjs`;
    lines.push(`  discard zjs_worker_create(cstring"${url}", cstring"", cstring"h-${id}")`);
  }
  return `## AUTO-GENERATED (Nim). zjs headless workers for the perf gate.
proc zjs_worker_create(scriptUrl, ownerId, workerId: cstring): bool {.importc, cdecl.}
proc zapp_start_headless_workers*() =
${lines.length ? lines.join("\n") : "  discard"}
`;
}
```
Add a `renderHeadlessNim` test in `cli/src/build-config-nim.test.ts` asserting a zjs entry emits a `zjs_worker_create(... "h-<id>" ...)` line and a non-zjs entry does not. Run `bun test ./cli/src/build-config-nim.test.ts` → pass.

- [ ] **Step 2: Wire it into `buildNativeNim`**

In `cli/src/native.ts` `buildNativeNim`: write `renderHeadlessNim(config.headless)` to `.zapp/zapp_headless.nim`, and add `--threads:on` to the `nim c` args. (The `.zapp` dir is already on `--path`.)

- [ ] **Step 3: Call the spawn from `app.nim`**

In `native/nim/app.nim`, import the generated module + worker_service, and in `run()` (before `platformRun`):
```nim
import worker_service
{.push warning[UnusedImport]: off.}
import zapp_headless   # generated into .zapp/, resolved via --path
{.pop.}
# inside run(), before platformRun:
registerWorkerServices()
zapp_start_headless_workers()
```

- [ ] **Step 4: Build + confirm the worker spawns and runs the bench**

Run:
```bash
cd /Users/zach/code/zapp/benchmarks/apps/zapp-host-bridge && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -4
"<bench binary path>" 2>&1 | grep -E '\[bench:zjs\]|\[zapp' | head -20
```
Expected: `[zapp] build complete:` then, on launch, `[bench:zjs] invokeService.small …` lines — proving the zjs worker spawned, ran bench-worker.ts, hammered `invokeService` → `service_invoke_native` (Nim) → returned. If no bench lines: confirm the worker spawned (zjs_worker_create returned true), the script URL matches the app's generated headless worker file, and service_invoke_native is being hit (lldb breakpoint if needed).

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/native.ts cli/src/build-config.ts cli/src/build-config-nim.test.ts native/nim/app.nim
git commit -m "$(printf 'feat(nim): spawn the zjs bench worker (generated headless + threads:on)\n\nrenderHeadlessNim emits zjs zapp_start_headless_workers (importc\nzjs_worker_create); buildNativeNim writes .zapp/zapp_headless.nim + adds\n--threads:on; app.nim registers services + spawns at run(). The bench worker\nnow round-trips invokeService -> Nim service_invoke_native.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 5: Run the gate + verdict

**Files:** Modify `benchmarks/nim-perf-gate/baseline.md` → rename/extend to the full report, or create `benchmarks/nim-perf-gate/report.md`.

- [ ] **Step 1: Run the Nim build 3×, capture numbers**

Run:
```bash
for i in 1 2 3; do "<nim bench binary path>" 2>&1 | grep '\[bench:zjs\]'; echo "--- run $i ---"; done
```
Record all 3 runs' `small`/`medium` µs/op.

- [ ] **Step 2: Compare + verdict**

Compute `NIM_MEDIAN_SMALL` (median of the 3 small runs). Compare to `ZC_BASELINE_SMALL` (Task 0):
- **PASS** if `NIM_MEDIAN_SMALL <= 1.15 * ZC_BASELINE_SMALL`.
- **FAIL** otherwise — do NOT proceed to breadth; root-cause (lldb the hot path for an unexpected alloc / ORC call / indirection; check the handlers stayed alloc-free; check `--threads:on` didn't add per-call overhead).

- [ ] **Step 3: Write the gate report**

`benchmarks/nim-perf-gate/report.md`: machine/date, the zc + nim tables (3 runs each, medians, small + medium), the ratio, the **PASS/FAIL verdict**, and (if PASS) a one-line greenlight for breadth; (if FAIL) the suspected cause + next step. Also note: both builds linked the identical zc-emitted JsonValue, so the diff is purely `service_invoke_native`'s language.

- [ ] **Step 4: Commit**

```bash
cd /Users/zach/code/zapp
git add benchmarks/nim-perf-gate/report.md
git commit -m "$(printf 'bench(nim): worker host-object perf gate result + verdict\n\nNim-zjs vs zc-zjs invokeService medians (same harness/machine). Verdict\nvs the <=1.15x bar; greenlight-or-root-cause for breadth.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Self-review notes (for the executor)

- **Task 1 is the real risk** (emitting the zc JsonValue as a linkable object). It's first + standalone; iterate on the `zc` flags and record what worked. If `zc` can't emit a usable object at all, escalate — the whole gate depends on the JsonValue C-ABI being present.
- **Alloc-free is non-negotiable on the worker thread** — any Nim heap alloc in `service_invoke_native`/handlers risks ORC on a foreign thread (crash or skew). Keep cstring-compare + module-backed returns. If a future need forces allocation, that's `setupForeignThreadGc` — out of scope.
- **`{.compile.}` CALL form**, not tuple (drops flags). **`--threads:on`** required (zjs spawns pthreads).
- **Dedup the exportc surface** — several zjs.c externs may already be provided by the skeleton/generated config; defining twice = duplicate-symbol link error. Grep before adding.
- **Apples-to-apples:** identical harness, identical JsonValue impl, same machine, back-to-back, medians. The only variable is `service_invoke_native`'s language.
- Scope is **through the gate verdict only** — zjs, two bench cases, no retry/restart/registry/multi-worker/other host objects.
