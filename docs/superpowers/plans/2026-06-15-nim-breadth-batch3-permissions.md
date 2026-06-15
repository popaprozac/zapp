# Nim Breadth Batch 3 — Permissions Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Nim build actually enforce the declarative permissions manifest on both the webview (router) and worker (zjs/bare) paths, replacing the three allow-everything stubs.

**Architecture:** New `native/nim/permissions.nim` — POD `cstring`-array storage + a `{.gcsafe.}`, alloc-free check path (worker-pthread-safe, like `worker_service.nim`), with an idiomatic `std/json` parse that runs only at main-thread eager-init. The `permission_id_for_invoke` mapping lives here too (pure, unit-testable — same pattern as `eventNameToId` in `events.nim`). `router.nim` gains the t:1 invoke checkpoint; `app.nim` eager-inits at boot; the Nim build-config codegen gains the `zapp_build_permissions_json` getter.

**Tech Stack:** Nim (`--mm:orc`, `std/json`), libc via `importc`, the CLI codegen in TypeScript (bun-tested). Nim unit tests via `nim c -r --hints:off`.

---

## Background the engineer needs

- **Branch:** `feat/nim-native`. Additive to the Nim layer; the `zc` path stays default.
- **The real correctness gap this closes:** `native/worker/engines/zjs.c:476-477` and
  `native/worker/engines/bare.c:638-639` already call `permission_id_for_invoke(method)`
  + `permissions_check(perm_id, method)` on every worker `invokeService`; `router.zc:65-80`
  does it on the webview path. The current Nim stubs (`zapp.nim`) return `""`/`true`, so the
  **Nim build bypasses permissions entirely**. This batch makes them real.
- **Source of truth:** `native/permissions/permissions.zc` (parser + verb semantics),
  `native/app/router.zc:21-36` (`permission_id_for_invoke`) + `:62-80` (the checkpoint),
  `native/tests/permissions_test.zc` (the unit test to mirror).
- **Worker-thread discipline (load-bearing):** `permissions_check` /
  `permissionsIsAllowed` / `permission_id_for_invoke` are reachable from the zjs/bare
  worker pthread → must be `{.gcsafe.}` and touch **no Nim heap** (no `seq`/`string`/
  `JsonNode`), exactly like `worker_service.nim`. The `std/json` parse runs ONLY at
  main-thread eager-init (`app.nim run()` → `permissionsEnsureInit()` before any window/
  worker exists). The check path never calls the parser (that's what keeps `{.gcsafe.}`
  sound). **Invariant:** an un-init'd check reads `gActive == false` ⇒ allow-all
  (fail-open), consistent with the no-manifest contract.
- **Permission semantics:** inactive manifest ⇒ allow-all; exact id match ⇒ allow; a bare
  `module` grant covers all `module:verb`; a `module:verb` grant is exact (no sibling/bare
  bleed); malformed JSON ⇒ fail-open (inactive).
- **Nim test pattern** (see `native/nim/tests/callbacks_test.nim`): standalone `.nim` that
  `import ../<module>`, defines `proc test()` with `doAssert`, prints `"<name> ok"`, calls
  `test()`. Run `nim c -r --hints:off <file>.nim` from `native/nim/tests/`. `nim` =
  `/opt/homebrew/bin/nim`. A module that `importc`s a CLI-generated symbol provides an
  `{.exportc.}` stub of it in the test file (like `callbacks_test.nim` stubs
  `zapp_dispatch_event_to_js`).
- **STANDING CONSTRAINT — never `git add -A`.** Stage only the explicit paths named in each
  commit step. Never stage `hello-world/`, `kitchen-sink/`, `vendor/`,
  `native/worker/engines/zjs-cross-eval-test.c`, or user-WIP.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `native/nim/permissions.nim` | Manifest parse + verb check + `permission_id_for_invoke` mapping | **Create** |
| `native/nim/tests/permissions_test.nim` | Unit test (mirrors `permissions_test.zc`) | Create |
| `cli/src/build-config.ts` | `BuildConfigNimOpts` + `renderBuildConfigNim` getter | Modify |
| `cli/src/native.ts:1101` | Pass resolved `permissionsJson` to the Nim renderer | Modify |
| `cli/src/build-config-nim.test.ts` | Codegen assertions | Modify |
| `native/nim/router.nim` | Import permissions; t:1 invoke checkpoint | Modify |
| `native/nim/app.nim` | Eager `permissionsEnsureInit()` in `run()` | Modify |
| `native/nim/zapp.nim` | Remove the 3 permission stubs | Modify |
| `native/nim/worker_service.nim` / `native/worker/engines/*` / `native/platform/**` | — | **Untouched** |

---

## Task 1: CLI codegen — `zapp_build_permissions_json` Nim getter (bun-tested)

The generated `zapp_build_config.nim` has no permissions getter today (only the `.zc`
emitter does, at `build-config.ts:146`). `permissions.nim` `importc`s
`zapp_build_permissions_json`, so the Nim build needs it. Foundation task.

**Files:**
- Modify: `cli/src/build-config.ts` (`BuildConfigNimOpts` ~:175-182, `renderBuildConfigNim` ~:191-214)
- Modify: `cli/src/native.ts:1101-1108` (the caller)
- Test: `cli/src/build-config-nim.test.ts`

- [ ] **Step 1: Write the failing test**

In `cli/src/build-config-nim.test.ts`, (a) update the FIRST test's `renderBuildConfigNim({…})`
call (lines ~5-12) to include the new required field — add this line inside the object:
```ts
    permissionsJson: '{"platform":"macos","active":false,"allow":[]}',
```
and (b) append a new test:
```ts
test("renderBuildConfigNim emits zapp_build_permissions_json from the manifest", () => {
  const out = renderBuildConfigNim({
    initialUrl: "zapp://index.html",
    identifier: "com.example.app",
    assetRoot: "",
    embedAssets: true,
    devTools: 1,
    isDev: false,
    permissionsJson: '{"platform":"macos","active":true,"allow":["clipboard"]}',
  });
  expect(out).toContain('proc zapp_build_permissions_json(): cstring {.exportc, cdecl.}');
  expect(out).toContain('let zappPermissionsJson');
  expect(out).toContain('clipboard');
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp && bunx tsc --noEmit -p cli/tsconfig.json 2>&1 | grep -i permissionsJson | head` (expect a type error: `permissionsJson` not in `BuildConfigNimOpts`), then
Run: `cd /Users/zach/code/zapp && bun test cli/src/build-config-nim.test.ts 2>&1 | tail -15`
Expected: FAIL — the new test's assertions don't match (no `zapp_build_permissions_json` in output) and/or the type error.

- [ ] **Step 3: Add the field + emit the getter**

In `cli/src/build-config.ts`, add to `BuildConfigNimOpts` (after `isDev: boolean;`):
```ts
  permissionsJson: string;
```
In `renderBuildConfigNim`, add a module-level `let` (after the `let zappAssetRoot = …` line) and the getter (after the `zapp_build_asset_root` proc line). The `s()` helper already in the function produces a valid Nim string literal:
```ts
let zappPermissionsJson = ${s(o.permissionsJson)}
```
```ts
proc zapp_build_permissions_json(): cstring {.exportc, cdecl.} = zappPermissionsJson.cstring
```

- [ ] **Step 4: Wire the caller**

In `cli/src/native.ts`, just before the `const configNim = renderBuildConfigNim({` call (~line 1101), compute the manifest (mirroring the `.zc` path at `build-config.ts:74-85`):
```ts
  const { resolvePermissions } = await import("./permissions");
  const resolvedPerms = resolvePermissions(config.permissions);
  const permsObj = { platform: "macos", active: resolvedPerms.active, allow: resolvedPerms.allow };
```
and add this field inside the `renderBuildConfigNim({…})` object:
```ts
    permissionsJson: JSON.stringify(permsObj),
```

- [ ] **Step 5: Run the test + the full cli suite**

Run: `cd /Users/zach/code/zapp && bun test cli/src/build-config-nim.test.ts 2>&1 | tail -8`
Expected: PASS (all tests in the file green).
Run: `cd /Users/zach/code/zapp && ulimit -n 8192 && bun test ./cli/src/*.test.ts 2>&1 | tail -8`
Expected: no new failures (pre-existing baseline unchanged).

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add cli/src/build-config.ts cli/src/native.ts cli/src/build-config-nim.test.ts
git commit -m "$(printf 'feat(nim): emit zapp_build_permissions_json in the Nim build config\n\nThe Nim build-config codegen now renders the resolved permissions manifest\ngetter the .m/permissions layer reads (the zc emitter already had it). Wires\nresolvePermissions into the Nim native build path. Bun-tested.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 2: `permissions.nim` — parser + verb check + `permission_id_for_invoke` + unit test

**Files:**
- Create: `native/nim/permissions.nim`
- Test: `native/nim/tests/permissions_test.nim`

- [ ] **Step 1: Write the failing test**

Create `native/nim/tests/permissions_test.nim` (mirrors `native/tests/permissions_test.zc`):
```nim
import ../permissions

# permissions.nim importc's zapp_build_permissions_json (the CLI-generated getter).
# Never CALLED here (every test drives permissionsResetAndLoad directly), but
# permissionsEnsureInit references it, so stub it to satisfy the link — same as
# callbacks_test.nim stubs zapp_dispatch_event_to_js.
proc zapp_build_permissions_json(): cstring {.exportc, cdecl.} =
  cstring("{\"platform\":\"macos\",\"active\":false,\"allow\":[]}")

proc test() =
  # inactive => allow all
  permissionsResetAndLoad("{\"platform\":\"macos\",\"active\":false,\"allow\":[]}")
  doAssert permissionsIsAllowed(cstring"clipboard:read")
  doAssert permissionsIsAllowed(cstring"tray")
  # active + empty => deny all
  permissionsResetAndLoad("{\"platform\":\"macos\",\"active\":true,\"allow\":[]}")
  doAssert not permissionsIsAllowed(cstring"clipboard:read")
  # bare module grants its verbs
  permissionsResetAndLoad("{\"platform\":\"macos\",\"active\":true,\"allow\":[\"clipboard\"]}")
  doAssert permissionsIsAllowed(cstring"clipboard:read")
  doAssert permissionsIsAllowed(cstring"clipboard:write")
  doAssert permissionsIsAllowed(cstring"clipboard")
  doAssert not permissionsIsAllowed(cstring"fs:read")
  # exact verb grant, no sibling/bare bleed
  permissionsResetAndLoad("{\"platform\":\"macos\",\"active\":true,\"allow\":[\"fs:read\",\"shell:open\"]}")
  doAssert permissionsIsAllowed(cstring"fs:read")
  doAssert not permissionsIsAllowed(cstring"fs:write")
  doAssert not permissionsIsAllowed(cstring"fs")
  doAssert permissionsIsAllowed(cstring"shell:open")
  doAssert not permissionsIsAllowed(cstring"shell:trash")
  # malformed => fail open (inactive)
  permissionsResetAndLoad("{not json")
  doAssert permissionsIsAllowed(cstring"clipboard")
  # permission_id_for_invoke mapping (router.zc:21-36 parity)
  doAssert $permission_id_for_invoke(cstring"__clipboard:readText") == "clipboard:read"
  doAssert $permission_id_for_invoke(cstring"__clipboard:has") == "clipboard:read"
  doAssert $permission_id_for_invoke(cstring"__clipboard:writeText") == "clipboard:write"
  doAssert $permission_id_for_invoke(cstring"__dialog:open") == "dialog"
  doAssert $permission_id_for_invoke(cstring"__notif:show") == "notifications"
  doAssert $permission_id_for_invoke(cstring"__shortcuts:register") == "shortcuts"
  doAssert $permission_id_for_invoke(cstring"__screen:list") == "screen"
  doAssert $permission_id_for_invoke(cstring"__window:create") == "window:create"
  doAssert $permission_id_for_invoke(cstring"greet") == ""
  # permissions_check delegates to isAllowed
  permissionsResetAndLoad("{\"platform\":\"macos\",\"active\":true,\"allow\":[\"clipboard\"]}")
  doAssert permissions_check(cstring"clipboard:read", cstring"Clipboard.read")
  doAssert not permissions_check(cstring"fs:read", cstring"fs")
  echo "permissions ok"
test()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off permissions_test.nim 2>&1 | tail -6`
Expected: FAIL — cannot open `../permissions` (module doesn't exist yet).

- [ ] **Step 3: Write `native/nim/permissions.nim`**

Create `native/nim/permissions.nim`:
```nim
## Native permissions — manifest parser + verb-semantics check + the
## invoke→permission-id mapping. Ported from native/permissions/permissions.zc
## and permission_id_for_invoke from native/app/router.zc.
##
## WORKER-THREAD DISCIPLINE (load-bearing): permissions_check /
## permissionsIsAllowed / permission_id_for_invoke run on the zjs/bare worker
## pthread (zjs.c / bare.c) as well as the Cocoa main thread. So the CHECK path
## is {.gcsafe.} and touches ONLY POD state (cstring arrays, ints) — no Nim heap,
## no ORC — exactly like worker_service.nim. The PARSE (std/json) runs ONLY at
## main-thread eager-init (app.nim run() calls permissionsEnsureInit before any
## window/worker exists), so it never runs on a worker thread. The check path
## never calls the parser — that is what keeps {.gcsafe.} sound.
## INVARIANT: permissions must be initialized before the first check; an
## un-init'd check reads gActive=false => allow-all (fail-open), matching the
## no-manifest contract. permission_id_for_invoke lives here (not router.nim) for
## the same reason eventNameToId lives in events.nim: pure + unit-testable.
import std/json

proc zapp_build_permissions_json(): cstring {.importc, cdecl.}

# libc (POD ops; safe on the worker check path)
proc c_strdup(s: cstring): cstring {.importc: "strdup", header: "<string.h>", cdecl.}
proc c_strcmp(a, b: cstring): cint {.importc: "strcmp", header: "<string.h>", cdecl.}
proc c_strncmp(a, b: cstring, n: csize_t): cint {.importc: "strncmp", header: "<string.h>", cdecl.}
proc c_strlen(s: cstring): csize_t {.importc: "strlen", header: "<string.h>", cdecl.}
proc c_strchr(s: cstring, ch: cint): cstring {.importc: "strchr", header: "<string.h>", cdecl.}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>", cdecl.}
proc c_fprintf(stream: pointer, fmt: cstring) {.importc: "fprintf", varargs, header: "<stdio.h>", cdecl.}
var cstderr {.importc: "stderr", header: "<stdio.h>".}: pointer

const MAXP = 64
var gLoaded = false
var gActive = false
var gAllow: array[MAXP, cstring]
var gAllowCount = 0
var gLogged: array[MAXP, cstring]
var gLoggedCount = 0

proc permissionsResetAndLoad*(json: string) =
  ## Reset state and (re)parse `json` (std/json; main-thread / test seam).
  ## Parse error or absent/false `active` => stays inactive (fail-open).
  for i in 0 ..< gAllowCount:
    c_free(gAllow[i]); gAllow[i] = nil
  gAllowCount = 0
  for i in 0 ..< gLoggedCount:
    c_free(gLogged[i]); gLogged[i] = nil
  gLoggedCount = 0
  gActive = false
  gLoaded = true
  var root: JsonNode
  try:
    root = parseJson(json)
  except CatchableError:
    return                       # unparseable => inactive (fail-open)
  if root.kind != JObject: return
  if root{"active"}.getBool(false):
    gActive = true
    let allow = root{"allow"}
    if not allow.isNil and allow.kind == JArray:
      for elem in allow:
        if elem.kind == JString and gAllowCount < MAXP:
          gAllow[gAllowCount] = c_strdup(elem.getStr().cstring)
          inc gAllowCount

proc permissionsEnsureInit*() =
  ## Lazy guard; eager-called from app.nim boot (main thread).
  if gLoaded: return
  permissionsResetAndLoad($zapp_build_permissions_json())

proc permissionsIsAllowed*(id: cstring): bool {.gcsafe.} =
  ## POD reader (worker-safe). Does NOT init — relies on eager-init.
  if not gActive: return true
  if id.isNil or id[0] == '\0': return false
  for i in 0 ..< gAllowCount:
    if c_strcmp(id, gAllow[i]) == 0: return true
  let colon = c_strchr(id, ord(':').cint)
  if not colon.isNil:
    let mlen = cast[csize_t](cast[uint](colon) - cast[uint](id))
    if mlen > 0:
      for i in 0 ..< gAllowCount:
        if c_strlen(gAllow[i]) == mlen and c_strncmp(id, gAllow[i], mlen) == 0:
          return true
  return false

proc permissions_check*(id: cstring, meth: cstring): bool {.exportc, cdecl, gcsafe.} =
  ## Gate `id` for `meth`. Allowed => true; denied => one-shot stderr log + false.
  if permissionsIsAllowed(id): return true
  var seen = false
  for i in 0 ..< gLoggedCount:
    if c_strcmp(id, gLogged[i]) == 0:
      seen = true; break
  if not seen and gLoggedCount < MAXP:
    gLogged[gLoggedCount] = c_strdup(id); inc gLoggedCount
    c_fprintf(cstderr,
      cstring("[zapp] permission denied: %s (%s) — add \"%s\" to permissions in zapp.config.ts\n"),
      id, meth, id)
  return false

proc permissions_bootstrap_json*(): cstring {.exportc, cdecl.} =
  ## Raw manifest JSON (webview.m injects it; the router __zapp:permissions route
  ## forwards it — that route is Batch 5).
  zapp_build_permissions_json()

proc permission_id_for_invoke*(meth: cstring): cstring {.exportc, cdecl, gcsafe.} =
  ## Map a t:1 invoke method to a permission id ("" = ungated). Pure cstring
  ## logic; mirrors router.zc:21-36. String literals returned as cstring are
  ## static storage (stable). zjs.c / bare.c call this via extern.
  if c_strncmp(meth, cstring"__clipboard:", 12) == 0:
    let rest = cast[cstring](cast[uint](meth) + 12)
    if c_strncmp(rest, cstring"read", 4) == 0: return cstring"clipboard:read"
    if c_strncmp(rest, cstring"has", 3) == 0: return cstring"clipboard:read"
    return cstring"clipboard:write"
  if c_strncmp(meth, cstring"__dialog:", 9) == 0: return cstring"dialog"
  if c_strncmp(meth, cstring"__notif:", 8) == 0: return cstring"notifications"
  if c_strncmp(meth, cstring"__shortcuts:", 12) == 0: return cstring"shortcuts"
  if c_strncmp(meth, cstring"__screen:", 9) == 0: return cstring"screen"
  if c_strcmp(meth, cstring"__window:create") == 0: return cstring"window:create"
  return cstring""
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/zach/code/zapp/native/nim/tests && nim c -r --hints:off permissions_test.nim 2>&1 | tail -6`
Expected: PASS — prints `permissions ok`.
(If Nim rejects a `{.gcsafe.}` proc for accessing a global, the cause is a GC-typed global on the check path — there should be none here, all globals are `cstring`/`int`/`bool`. Do NOT drop `gcsafe`; fix the offending access.)

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/permissions.nim native/nim/tests/permissions_test.nim
git commit -m "$(printf 'feat(nim): permissions.nim — manifest parse + verb check + id mapping (Batch 3)\n\nPOD cstring-array storage + gcsafe alloc-free permissions_check/isAllowed\n(worker-pthread-safe like worker_service.nim); idiomatic std/json parse at\nmain-thread eager-init. permission_id_for_invoke mapping co-located here\n(pure + unit-testable, like eventNameToId in events.nim). Mirrors\npermissions.zc + router.zc:21-36. Unit test ports permissions_test.zc.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

## Task 3: Router checkpoint + eager init + stub removal → GATE

Makes permissions live in the binary: wire the t:1 checkpoint, eager-init at boot, remove
the three `zapp.nim` stubs (which now collide with `permissions.nim`'s real `{.exportc.}`
symbols), and do the first full build.

**Files:**
- Modify: `native/nim/router.nim` (import + checkpoint)
- Modify: `native/nim/app.nim` (eager init)
- Modify: `native/nim/zapp.nim` (remove 3 stubs)

- [ ] **Step 1: Router import + t:1 checkpoint**

In `native/nim/router.nim`, add `permissions` to the import line (currently
`import bridge, service, clipboard, callbacks, events`):
```nim
import bridge, service, clipboard, callbacks, events, permissions
```
In `routeMessage`, immediately AFTER `if f.t != 1: return` and BEFORE the
`if f.m.startsWith("__clipboard:"):` block, insert (mirrors `router.zc:62-80`):
```nim
  # Permission gate (t:1). Map the method to a catalog id; ungated ("") falls
  # through. Manifest active + id not granted => reply so the JS promise rejects
  # (PERMISSION_DENIED:<id>; the runtime decorates it into PermissionDeniedError).
  let permId = permission_id_for_invoke(f.m.cstring)
  if not permId.isNil and permId[0] != '\0':
    if not permissions_check(permId, f.m.cstring):
      sendInvokeResponse(windowId, f.id, false, "PERMISSION_DENIED:" & $permId)
      return
```

- [ ] **Step 2: Eager-init in app.nim boot**

In `native/nim/app.nim`, add `permissions` to the import line (currently
`import router, service`; also `import worker_service` is on the next line):
```nim
import router, service, permissions
```
In `run()`, make `permissionsEnsureInit()` the FIRST call (before
`registerWorkerServices()`), so the manifest parses on the main thread before any window or
worker can issue a check:
```nim
proc run*(app: App): int =
  ## Init permissions (main-thread parse), register worker-path services, run
  ## startup hooks, spawn zjs headless workers, then enter the Cocoa run loop.
  permissionsEnsureInit()
  registerWorkerServices()
  runStartupAll()
  zapp_start_headless_workers()
  platformRun(app.terminateAfterLastWindowClosed)
```

- [ ] **Step 3: Remove the three `zapp.nim` stubs**

In `native/nim/zapp.nim`, delete these (match by content; line numbers approximate):

(a) the manifest stub (~:144-146):
```nim
# permissions_bootstrap_json — permissions manifest. "" => webview.m uses its
# inactive-permissions default. TEMP until the permissions layer is ported.
proc permissions_bootstrap_json(): cstring {.exportc, cdecl.} = "".cstring
```
(b) the check + id-mapping stubs (~:225-226, plus the `# Permission gates …` comment above
them at ~:222-224):
```nim
proc permissions_check(id: cstring, m: cstring): bool {.exportc, cdecl, gcsafe.} = true
proc permission_id_for_invoke(m: cstring): cstring {.exportc, cdecl, gcsafe.} = cstring""
```
Leave every other stub in `zapp.nim` untouched. `permissions.nim` is now in the build graph
(via `router.nim` + `app.nim`), so its real defs provide these symbols.

- [ ] **Step 4: Full Nim build (the build gate)**

Run: `cd /Users/zach/code/zapp/hello-world && ZAPP_NATIVE_LANG=nim bun run build 2>&1 | tail -8`
Expected: LAST line `[zapp] build complete: <path>`. If the linker reports a duplicate
`permissions_check` / `permission_id_for_invoke` / `permissions_bootstrap_json`, a
`zapp.nim` stub wasn't fully removed (Step 3). If it reports an undefined
`zapp_build_permissions_json`, Task 1's codegen didn't land / the app wasn't rebuilt.
Do NOT `git add` anything under `hello-world/`.

- [ ] **Step 5: Regression — re-run the unit tests**

Run:
```bash
cd /Users/zach/code/zapp/native/nim/tests && \
for t in permissions_test service_registry_test service_lifecycle_test service_manifest_test service_cabi_test callbacks_test router_subscribe_test; do \
  nim c -r --hints:off $t.nim 2>&1 | tail -1; done
```
Expected: each prints its `… ok` line (`permissions ok`, `service registry ok`, …).
Run: `cd /Users/zach/code/zapp && bun test cli/src/build-config-nim.test.ts 2>&1 | tail -4`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/zach/code/zapp
git add native/nim/router.nim native/nim/app.nim native/nim/zapp.nim
git commit -m "$(printf 'feat(nim): wire permissions — t:1 checkpoint + eager init; drop stubs (Batch 3)\n\nrouter.nim gates t:1 invokes (permission_id_for_invoke + permissions_check ->\nPERMISSION_DENIED:<id>); app.nim run() eager-inits permissions on the main\nthread before workers spawn; remove the 3 allow-everything zapp.nim stubs.\nThe Nim build now enforces the manifest on both the webview and worker paths.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 7: GATE — human smoke (controller pauses here)**

The controller pauses for the human. **Unit + build gate already proves the logic;** this
optional runtime smoke confirms end-to-end on the Nim build (`ZAPP_NATIVE_LANG=nim`):
1. Temporarily add a `permissions: ["notifications"]` (an active manifest that **omits**
   `clipboard`) to the hello-world `zapp.config.ts` (the user's WIP — not committed).
2. Run `cd hello-world && ZAPP_NATIVE_LANG=nim bun run dev`; trigger a clipboard read/write
   from the demo → it rejects (the JS promise throws `PermissionDeniedError` /
   `PERMISSION_DENIED:clipboard:*`), and `[zapp] permission denied: clipboard:… ` logs once
   to the terminal.
3. Remove the `permissions` block (or grant `clipboard`) → clipboard works again.

Do not proceed to the final review until the human confirms (or explicitly skips the
runtime smoke, accepting the unit+build gate).

---

## Self-Review

**1. Spec coverage:**
- `permissions.nim` Approach A (POD storage, gcsafe alloc-free check, std/json eager-init
  parse) → Task 2 Step 3. ✓
- `permissions_check` (exportc) + `permissions_bootstrap_json` (exportc) → Task 2. ✓
- `permission_id_for_invoke` (exportc) — spec said router.nim; **plan co-locates it in
  permissions.nim** (pure + unit-testable, exact `eventNameToId`-in-`events.nim` precedent;
  router.nim imports + calls it). Noted deviation, same C symbol/behavior. → Task 2 + Task 3. ✓
- t:1 invoke checkpoint in `router.nim` → Task 3 Step 1. ✓
- Eager `permissionsEnsureInit()` in `app.nim run()` → Task 3 Step 2. ✓
- Remove 3 `zapp.nim` stubs → Task 3 Step 3. ✓
- `zapp_build_permissions_json` in the Nim codegen → Task 1. ✓
- Unit test mirroring `permissions_test.zc` (5 semantic cases + mapping + check delegation)
  → Task 2 Step 1. ✓
- Deferred (`permission_id_for_action`/t:4 gate → B5; fs gates → B6) → not implemented,
  documented in plan + spec. ✓
- Gate (unit + build + optional clipboard-denied smoke) → Task 3 Steps 4-7. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases". Every code step shows complete
code. ✓

**3. Type consistency:** `permissionsResetAndLoad(json: string)`, `permissionsIsAllowed(id:
cstring): bool`, `permissions_check(id, meth: cstring): bool`, `permission_id_for_invoke(meth:
cstring): cstring`, `permissionsEnsureInit()` — used identically across Tasks 2/3 and the
test. `BuildConfigNimOpts.permissionsJson: string` matches the caller's `JSON.stringify(...)`
and the test's literal. ✓
