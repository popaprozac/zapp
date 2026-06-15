# Nim Migration — Phase 2 Breadth, Batch 3: Permissions Enforcement — Design

**Status:** Design (approved 2026-06-15). **Branch:** `feat/nim-native`.
**Part of:** the Nim migration breadth phase (`docs/superpowers/specs/2026-06-15-nim-migration-design.md`).
B1 (events) + B2 (services) done. **This is Batch 3** — port the native permissions
enforcement so the Nim build actually gates module/verb access (today it bypasses
permissions entirely).

## Goal

Port `native/permissions/permissions.zc` (manifest parser + verb-semantics check) to
`native/nim/permissions.nim`, port `permission_id_for_invoke` + the t:1 invoke
permission checkpoint into the already-ported `router.nim`, wire the manifest getter
into the Nim build-config codegen, and remove the three permission stubs in
`zapp.nim`. Enforcement must hold on **both** the webview path (router) and the worker
path (the zjs/bare engines already call `permissions_check` + `permission_id_for_invoke`
via `extern`).

## Why this matters now (a real correctness gap)

`native/worker/engines/zjs.c:476-477` and `native/worker/engines/bare.c:638-639` call
`permission_id_for_invoke(method)` then `permissions_check(perm_id, method)` on every
worker-side `invokeService`. `native/app/router.zc:65-80` does the same on the webview
t:1 path. In the current Nim build those resolve to the stubs in `zapp.nim`
(`permissions_check` → `true`, `permission_id_for_invoke` → `""`,
`permissions_bootstrap_json` → `""`), so **the Nim build silently bypasses the entire
permissions system**. Batch 3 closes that.

## The crux — split the parse (main thread) from the check (worker thread)

`permissions_check` and `permission_id_for_invoke` run on the **zjs/bare worker pthread**,
not just the Cocoa main thread. Per the migration's non-negotiable, code reachable from
that thread must be **ORC-free** (no Nim heap allocation, no `setupForeignThreadGc`) and
`{.gcsafe.}` — the same constraint that keeps `worker_service.nim` alloc-free.

**Decision (Approach A — POD storage, alloc-free reads; idiomatic parse at boot):**
split the module into a non-worker parse and a worker-safe check.

- **Storage is POD.** The allow-list and the denial-log set are module-level
  `array[64, cstring]` (plain pointers) with importc `strdup`/`strcmp`/`strchr`/`strlen`/
  `fprintf`/`free`. No `seq`, no `string` in the worker-reachable state.
- **Parse is idiomatic `std/json`, and runs ONLY on the main thread.** `app.nim` eagerly
  calls `permissionsEnsureInit()` at the top of `run()` (before any window or worker
  exists), which `parseJson`s the manifest, `strdup`s the granted ids into the POD
  `gAllow[]`, then drops the `JsonNode`. Using `std/json` (vs importc-ing the zc
  `JsonValue`/`Option`/`Result` accessors) avoids fragile C-ABI struct modeling and is
  the idiomatic win — and it's *safe* precisely because eager-init pins the parse to the
  main thread. (Bonus: Nim's `parseJson` has none of the zc parser's 4 KB-token SIGABRT
  hazard — see [[reference_zenc_json_parser_bug]] — so no `json_safe` workaround is
  needed here.)
- **The check (`permissionsIsAllowed` / `permissions_check`) is `{.gcsafe.}` and touches
  only the POD arrays — it does NOT call the parser.** It relies on eager-init having
  run. This separation is what makes `{.gcsafe.}` sound: if `permissionsIsAllowed` called
  `ensureInit` (which uses `std/json`), the gcsafe analysis would (correctly) reject the
  exported `permissions_check`. So the lazy-init guard lives only on the main-thread side;
  the worker side is a pure POD reader.

Rejected **Approach B** (idiomatic `std/json` + `seq[string]` allow-list read on the
worker path): the worker read must forever `index-don't-bind` (`gAllow[i].cstring == id`,
never `for s in gAllow` which copies each `string` = ORC alloc) — too sharp an edge for
the security layer. POD cstring arrays have no such footgun.

**Eager-init replaces the zc's lazy-init** (`permissions.zc` was lazy "so module-load
order is irrelevant; no global ctor"). Nim has no static-ctor-order problem and `app.nim
run()` is the deterministic single boot point, so eager-init there is the idiomatic
equivalent. **Invariant (documented in the module):** permissions must be initialized
(app.nim eager-init) before the first check; the worker/router/fs check paths assume the
loaded state. An un-initialized check reads `gActive == false` ⇒ allow-all (fail-open),
consistent with the no-manifest contract — and in practice never reached.

## Success criteria (the gate)

- **Unit test** `native/nim/tests/permissions_test.nim` (mirrors the existing
  `native/tests/permissions_test.zc`) passes: inactive→allow-all; active-empty→deny;
  bare `module` grants its `module:verb`; exact verb grant with no sibling/bare bleed;
  malformed JSON → fail-open (inactive). It drives `permissionsResetAndLoad(json)`
  directly (no build config needed), exactly as the zc test does.
- Full hello-world Nim build ends `[zapp] build complete:`; `.m` + worker engines
  untouched; no `{.emit.}`; `bun run check` + the bun codegen test clean.
- **Optional human app-smoke:** with an active manifest that omits `clipboard`, a
  `__clipboard:readText` invoke from the webview rejects `PERMISSION_DENIED:clipboard:read`
  (the runtime surfaces `PermissionDeniedError`); with `clipboard` granted (or no
  manifest) clipboard works as before. (The manifest goes in the user's hello-world
  `zapp.config.ts`, which is their WIP — not committed by this batch.)

## Scope

**In:**
- `native/nim/permissions.nim` (new) — Approach A. C names preserved for the `extern`
  callers: `permissions_check(id, method): bool` (exportc, gcsafe),
  `permissions_bootstrap_json(): cstring` (exportc); Nim-internal `permissionsIsAllowed`
  (gcsafe, POD reader), `permissionsEnsureInit` (main-thread, std/json),
  `permissionsResetAndLoad` (test seam, std/json).
- `native/nim/router.nim` — `permission_id_for_invoke(method: cstring): cstring`
  (exportc, gcsafe; the zjs/bare engines call it) as pure cstring logic, and the t:1
  invoke permission checkpoint in `routeMessage` (map method→id; if gated and
  `not permissions_check` → `sendInvokeResponse(... false, "PERMISSION_DENIED:<id>")` and
  return, before the clipboard/service dispatch).
- `native/nim/app.nim` — eager `permissionsEnsureInit()` at the top of `run()`.
- `native/nim/zapp.nim` — remove the three stubs (`permissions_bootstrap_json` ~:146,
  `permissions_check` ~:225, `permission_id_for_invoke` ~:226).
- `cli/src/build-config.ts` — add `zapp_build_permissions_json(): cstring` to the **Nim**
  emitter (it exists only in the zc emitter at line 146 today), returning the resolved
  per-platform manifest JSON (`resolvePermissions(config.permissions)`), JSON-escaped the
  same way. Covered by the existing bun codegen test.

**Out (deferred, dependency-correct):**
- `permission_id_for_action` + the **t:4 action permission gate** (`router.zc:40-55,380-384`)
  → **Batch 5**. The Nim router's t:4 surface today is only subscribe/unsubscribe/ready,
  all ungated; the gated actions (tray/dock/embed/menu/shell) don't exist in the Nim
  router yet.
- `fs.zc`'s `permissions_check("fs:*")` call sites → **Batch 6** (fs leaf service).
  `permissions.nim` provides the symbol they'll link against when fs lands.

## Architecture — what's being ported

### `native/nim/permissions.nim` (from `permissions/permissions.zc`, 198 LOC)

Module state (all POD — worker-safe):
```nim
var gLoaded = false
var gActive = false
var gAllow: array[64, cstring]      # strdup'd granted ids
var gAllowCount = 0
var gLogged: array[64, cstring]     # strdup'd denied ids (one-shot anti-spam)
var gLoggedCount = 0
```
libc importc surface:
```nim
proc c_strdup(s: cstring): cstring {.importc: "strdup", header: "<string.h>", cdecl.}
proc c_strcmp(a, b: cstring): cint {.importc: "strcmp", header: "<string.h>", cdecl.}
proc c_strlen(s: cstring): csize_t {.importc: "strlen", header: "<string.h>", cdecl.}
proc c_strchr(s: cstring, ch: cint): cstring {.importc: "strchr", header: "<string.h>", cdecl.}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>", cdecl.}
# stderr denial log: reuse the existing pattern (c_fprintf or Nim stderr.write on main
# thread). Confirm against how other nim modules log during planning.
```
- `permissionsResetAndLoad(json: string)` (std/json; test seam + main-thread init) — free
  prior `gAllow`/`gLogged`, reset counts, set `gLoaded = true`, `gActive = false`. Parse
  `json` with `parseJson` inside a `try` (parse error → stay inactive, fail-open). If
  `root{"active"}.getBool(false)`, set `gActive = true` and for each string in
  `root{"allow"}` (a `JArray`), `strdup` it into `gAllow[]` up to 64. The `JsonNode` is
  GC'd at proc end; the `gAllow` cstrings are independent `strdup` copies. Takes `string`
  (not cstring) — only ever called from Nim/main-thread.
- `permissionsEnsureInit()` (main-thread) — if `not gLoaded`,
  `permissionsResetAndLoad($zapp_build_permissions_json())`. Not gcsafe (uses std/json);
  called from app.nim boot only.
- `permissionsIsAllowed(id: cstring): bool {.gcsafe.}` — POD reader, does NOT init. If
  `not gActive` → true; empty id → false; exact `c_strcmp` match → true; for a
  `module:verb` id (`c_strchr ':'`) a bare `module` grant (length + `c_strncmp`/byte
  compare) → true; else false.
- `permissions_check(id, method: cstring): bool {.exportc, cdecl, gcsafe.}` —
  `permissionsIsAllowed(id)` → true; else strdup-dedup one-shot stderr denial log + false.
  Wire-identical message to `permissions.zc:185-187`.
- `permissions_bootstrap_json(): cstring {.exportc, cdecl.}` — returns
  `zapp_build_permissions_json()` raw (webview.m + the router `__zapp:permissions` route
  consume it; the latter is Batch 5).

`zapp_build_permissions_json(): cstring` is importc'd (provided by the generated
`zapp_build_config` Nim module after the codegen change).

### `router.nim` additions

```nim
proc permission_id_for_invoke(meth: cstring): cstring {.exportc, cdecl, gcsafe.}
```
Pure cstring logic mirroring `router.zc:21-36` (`__clipboard:` read*/has→`clipboard:read`,
else `clipboard:write`; `__dialog:`→`dialog`; `__notif:`→`notifications`;
`__shortcuts:`→`shortcuts`; `__screen:`→`screen`; `__window:create`→`window:create`; else
`""`). Returns string-literal cstrings (static storage, stable). Exported because
zjs.c/bare.c call it. (Name the Nim param `meth`, not `method` — avoid shadowing.)

The t:1 checkpoint goes in `routeMessage`, **after** `if f.t != 1: return` and **before**
the `__clipboard:`/service dispatch (mirroring `router.zc:62-80`):
```nim
let permId = permission_id_for_invoke(f.m.cstring)
if not permId.isNil and permId[0] != '\0':
  if not permissions_check(permId, f.m.cstring):
    sendInvokeResponse(windowId, f.id, false, "PERMISSION_DENIED:" & $permId)
    return
```
`routeMessage` is main-thread (webview→native), so `$permId` allocation is fine. The
worker path reaches `permissions_check` directly from zjs.c/bare.c, never via
`routeMessage`.

### Idiomatic-Nim note (honest)

`permissions.nim`'s *storage + check* is deliberately POD (cstring arrays + libc), the
same justified exception as `worker_service.nim`: a worker-pthread hot path where
ORC-freedom and the absence of allocation footguns outweigh idiom. But the *parse* is
idiomatic `std/json` (main-thread eager-init), and `permission_id_for_invoke` in
`router.nim` is idiomatic pure cstring logic. The module docstring states the split and
the init invariant.

## Risks (carried into the plan)

- **`{.gcsafe.}` boundary:** `permissions_check`/`permissionsIsAllowed` must touch no
  GC'd global and must not call the std/json parser. Keep `ensureInit` off the check
  path (eager-init only). If Nim's gcsafe analysis complains, the cause is a stray
  GC-typed access on the check path — fix the access, don't drop gcsafe.
- **Manifest getter codegen:** the Nim emitter must JSON-escape the manifest string
  identically to the zc emitter (`build-config.ts:146`); assert the escaping in the bun
  test (reuse the existing test's pattern).
- **Eager-init ordering:** `permissionsEnsureInit()` must run before any window/worker
  check; top of `app.nim run()` (before `zapp_start_headless_workers()` and before the
  run loop creates windows) covers it. Note it in the code.
- **Checkpoint ordering** in `routeMessage`: gate runs before clipboard/service dispatch
  and after the t:4/ready handling, matching `router.zc`.
- **fail-open:** malformed/inactive manifest ⇒ unrestricted, preserving the
  no-permissions-block contract. The unit test asserts this.

## References

- `native/permissions/permissions.zc` (source of truth), `native/tests/permissions_test.zc`
  (the test to mirror).
- `native/app/router.zc:21-36` (`permission_id_for_invoke`), `:61-80` (the t:1 checkpoint).
- `native/worker/engines/zjs.c:476-477`, `native/worker/engines/bare.c:638-639` (worker
  callers — untouched).
- `native/platform/darwin/webview.m:891`, `ios/webview.m:757` (`permissions_bootstrap_json`
  consumer — untouched).
- `native/nim/zapp.nim:144-146,225-226` (the three stubs to remove).
- `cli/src/build-config.ts:146` (zc manifest emitter), `:185-212` (Nim getter emitter to
  extend), `cli/src/permissions.ts` (`resolvePermissions`).
