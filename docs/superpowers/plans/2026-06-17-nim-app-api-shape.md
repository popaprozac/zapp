# Nim App-Authoring API → Shape A (mirror zc) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Reshape the Nim app-authoring API to mirror zc's `app.zc` surface — managers on `App` (`app.service.add`, `app.window.create`), service handler receives `app` — and bundle the parity-audit fixes (two default-value bugs, retire `registerSkeletonServices`).

**Architecture:** `App` becomes a `ref object` carrying thin manager objects (`service`, `window`). To break the Nim import cycle (today `app.nim` defines `App` and imports `service.nim`; making the handler take `App` would make `service.nim` need `App`), introduce a **leaf module `native/nim/apptypes.nim`** holding the shared types (`App`, `ServiceManager`, `WindowManager`, the app-aware handler type). Feature modules import `apptypes` for the types and define the *methods*. The handler gets `app` via a module-global "current app" set at `newApp`, read by `invokeService` (the router's `invokeService(name, args)` signature is unchanged). Free procs (`registerService`, `createWindow`) survive as **unadvertised primitives** the managers delegate to.

**Tech Stack:** Nim (`object`/`ref object` + UFCS, not `method`), the existing C-ABI, `cli/src` (scaffold + config), bun:test.

**Out of scope (separate, tracked):** the broader manager surfaces (dock/tray/menu/dialog/notification/sync/fs/security) + remaining Window methods — that's the parity-gap backlog, ported in later cycles, each surfaced. The worker→native service dispatch (#471) is unrelated.

---

### Task 1: WindowOptions default-value parity bugs

**Files:**
- Modify: `native/nim/window.nim` (`newWindowOptions`)

- [ ] **Step 1: Fix the two flipped defaults to match zc** (`window.zc:214` `acceptFirstMouse: true`, `:252` `autoCenter: false`). In `newWindowOptions`, change `autoCenter: true` → `autoCenter: false` and `acceptFirstMouse: false` → `acceptFirstMouse: true`.
- [ ] **Step 2: Build nim kitchen-sink.** `cd kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build` → last line `[zapp] build complete:`.
- [ ] **Step 3: Commit.** `git add native/nim/window.nim` → `fix(nim): WindowOptions acceptFirstMouse/autoCenter defaults match zc`.

---

### Task 2 (RISK GATE): apptypes leaf + `app.service.add` (handler gets `app`)

This is the gate — it proves the cycle-break + handler-threading + manager shape compile and round-trip before the rest.

**Files:**
- Create: `native/nim/apptypes.nim`
- Modify: `native/nim/service.nim`, `native/nim/app.nim`, `native/nim/zapp.nim` (exports), `kitchen-sink/zapp/app.nim`, `cli/src/init.ts` (scaffold)
- Test: `native/nim/` (compile + greet round-trip via smoke)

- [ ] **Step 1: Create `apptypes.nim`** — the leaf type module (no feature imports → no cycle):
```nim
## Shared app-layer types, in a leaf module so service.nim / window.nim / app.nim
## can all reference `App` without an import cycle. Behavior (methods) lives in the
## feature modules; this file is types only.
import std/json

type
  ServiceManager* = object   ## namespacing handle for app.service.* (stateless)
  WindowManager* = object    ## namespacing handle for app.window.* (stateless)
  App* = ref object
    name*: string
    terminateAfterLastWindowClosed*: bool
    service*: ServiceManager
    window*: WindowManager
  AppServiceHandler* = proc(app: App, args: JsonNode): string {.nimcall.}
    ## Service handler — mirrors zc `fn(app: App*, args: JsonValue*) -> string`.
```
- [ ] **Step 2: Refactor `service.nim`** to the app-aware handler + the `app.service.add` method, keeping `registerService` as the primitive. Change the registry to store `AppServiceHandler`; add a module-global current-app + setter; `invokeService` passes it:
```nim
import std/[json, options]
import apptypes

var gRegistry: seq[ServiceRecord]   # ServiceRecord.handler: AppServiceHandler
var gCurrentApp: App                # set by newApp (app.nim)

proc setCurrentApp*(a: App) = gCurrentApp = a

proc registerService*(name: string, handler: AppServiceHandler,
                      startup: LifecycleHook = nil, shutdown: LifecycleHook = nil) =
  ## Low-level primitive (unadvertised). Apps use app.service.add.
  gRegistry.add ServiceRecord(name: name, handler: handler, startup: startup, shutdown: shutdown)

proc add*(sm: ServiceManager, name: string, handler: AppServiceHandler) =
  ## Advertised: app.service.add("name", handler) — mirrors zc app.service.add.
  registerService(name, handler)

proc invokeService*(name: string, args: JsonNode): Option[string] =
  for rec in gRegistry:
    if rec.name == name: return some rec.handler(gCurrentApp, args)
  none(string)
```
  (`runStartupAll`/`runShutdownAll`/`serviceManifestJson`/the `{.exportc.}` seams unchanged.)
- [ ] **Step 3: Refactor `app.nim`** — `App` now comes from `apptypes` (delete the local `type App`); `newApp` builds the ref, wires managers, sets current app; **retire `greetService` + `registerSkeletonServices`** (audit item A):
```nim
import apptypes
proc newApp*(name: string, terminateAfterLastWindowClosed = true): App =
  platformInit(name)
  setAppConfig(AppConfig(name: name, terminateAfterLastWindowClosed: terminateAfterLastWindowClosed,
                         inspectable: Inspectable.Auto, maxWorkers: 0))
  result = App(name: name, terminateAfterLastWindowClosed: terminateAfterLastWindowClosed)
  setCurrentApp(result)
# run(app: App) unchanged in body. Delete greetService + registerSkeletonServices.
```
- [ ] **Step 4: `zapp.nim` exports** — `export apptypes` (App, ServiceManager, WindowManager, AppServiceHandler) so `import zapp` surfaces them; drop `registerSkeletonServices` from the `export app` comment.
- [ ] **Step 5: Convert kitchen-sink `zapp/app.nim`** greet to the new shape:
```nim
proc greet(app: App, args: JsonNode): string = "Hello from Zapp!"
...
  let a = newApp("kitchen-sink", terminateAfterLastWindowClosed = true)
  a.service.add("greet", greet)
```
- [ ] **Step 6: Convert the `zapp init` scaffold** (`cli/src/init.ts` app.nim template) identically (`proc greet(app: App, args: JsonNode)` + `a.service.add("greet", greet)`).
- [ ] **Step 7: Build both + gate.** nim + zc kitchen-sink builds → `[zapp] build complete:`; `bun run check` clean; `cd cli && bun test src` green.
- [ ] **Step 8: GATE — human smoke.** `ZAPP_NATIVE_LANG=nim bun run dev` in kitchen-sink → Home shows `greet → Hello from Zapp!` (proves handler-gets-app round-trips through the cycle-broken registry). PAUSE for human confirmation.
- [ ] **Step 9: Commit.** `feat(nim): app.service.add + handler gets app (Shape A); apptypes leaf breaks the cycle; retire skeleton greet`.

---

### Task 3: `app.window.create` + `win.onReady`

**Files:**
- Modify: `native/nim/window.nim`, `native/nim/router.nim` (uses createWindow), `kitchen-sink/zapp/app.nim`, `cli/src/init.ts`

- [ ] **Step 1: `WindowManager.create` method** in window.nim (delegates to the existing `createWindow` primitive, which stays):
```nim
import apptypes   # WindowManager
proc create*(wm: WindowManager, o: WindowOptions): Window = createWindow(o)
```
- [x] **Step 2: Rename to `onReady`** (mirror zc `on_ready`; in Nim `onReady` ≡ `on_ready`). Keep `show*`. Update the one router/app/scaffold/doc reference.
- [ ] **Step 3: Convert kitchen-sink app.nim + scaffold:** `let win = a.window.create(opts)` + `win.onReady(onReady)`. (`createWindow`/`allocSlot` stay as primitives used by the router — unchanged.)
- [ ] **Step 4: Build nim + zc + tsc + cli tests** → all green.
- [ ] **Step 5: Commit.** `feat(nim): app.window.create + win.onReady (Shape A)`.

---

### Task 4: `newApp(AppConfig)` overload + config surface

**Files:**
- Modify: `native/nim/app.nim`, `native/nim/appconfig.nim` (if surfacing fields), `kitchen-sink/zapp/app.nim` (optional), `cli/src/init.ts`

- [ ] **Step 1: Add `newApp(config: AppConfig): App` overload** (alongside the `newApp(name, …)` shorthand) so apps can set `inspectable`/`maxWorkers` like zc's `App::new(config)`:
```nim
proc newApp*(config: AppConfig): App =
  platformInit(config.name)
  setAppConfig(config)
  result = App(name: config.name, terminateAfterLastWindowClosed: config.terminateAfterLastWindowClosed)
  setCurrentApp(result)
```
- [ ] **Step 2 (optional naming parity — confirm with user before doing):** rename WindowOptions `inspectable` → `webContentInspectable` (matches zc; update field, the `wopts_inspectable` accessor body, `inspectableAuto` assignment sites, kitchen-sink, scaffold, docs). Leave AppConfig long-name rename out unless requested.
- [ ] **Step 3: Build nim + zc + tsc + cli tests** → green.
- [ ] **Step 4: Commit.** `feat(nim): newApp(AppConfig) overload`.

---

### Task 5: Docs + final gate

**Files:**
- Modify: `docs/api-reference.md` ("Authoring an app in Nim")

- [ ] **Step 1: Update the api-reference Nim section** to the Shape-A surface: `newApp`, `a.service.add(proc(app, args) …)`, `a.window.create(opts)`, `win.onReady` / `win.show`, the AppConfig overload. Note managers mirror zc and more (dock/tray/…) arrive as they're ported.
- [ ] **Step 2: Full gate.** nim + zc kitchen-sink builds; `bun run check`; `cd cli && bun test src`; record binary sizes.
- [ ] **Step 3: Final cross-impl review** (subagent) — confirm no Nim-only divergence remains beyond the documented backlog; the app-facing Nim surface reads as a faithful `app.zc` analog.
- [ ] **Step 4: Commit + finish branch** via superpowers:finishing-a-development-branch.

---

## Self-review notes
- **Cycle-break correctness:** `apptypes` imports only `std/json` (+ maybe coretypes) → leaf. `service.nim`/`window.nim`/`app.nim` import `apptypes` for types; methods live in the feature modules. No module imports another that imports it back through types.
- **`App` value→ref:** changing `App` to `ref object` — verify `run(app: App)`, `zapp_handle_message_from_window`, and any `App(...)` construction still compile (ref construction is the same literal).
- **Handler `{.nimcall.}` vs current app:** handlers stay `{.nimcall.}` (no capture); the app is threaded by `invokeService` from `gCurrentApp`, not captured — so no closure/gcsafe change.
- **Primitives preserved:** `registerService`, `createWindow`, `allocSlot` remain for the router + power users; only the *advertised* surface changes.
- **Type-consistency:** `ServiceManager.add` / `WindowManager.create` are UFCS methods (procs with the manager as first param), called `a.service.add` / `a.window.create`. Confirm overload resolution (`create(WindowManager,…)` vs any other `create`) is unambiguous by receiver type.
