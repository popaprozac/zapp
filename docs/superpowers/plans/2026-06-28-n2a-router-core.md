# N2a — Router Core API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship the cross-platform Router core — `Window.current().router` (push/pop/forward/replace/popToRoot + canGoBack/Forward/params), `RouteOptions`, `Window.get(id)`/`Window.all()`, the `ROUTE_CHANGED` event, and a native authoritative per-window route stack.

**Architecture:** Native (`routerstate.nim`) holds the authoritative per-window stack; `router:*` t:4 actions mutate it and emit `ROUTE_CHANGED` via the existing `dispatch_event_to_all` broadcast (carrying `windowId`, filtered client-side — same path as `TOOLBAR_CLICKED`, so NO bitmask change). The runtime `.router` handle mirrors `createSidebarHandle` (state cache + `windowAction`). `Window.get` is pure JS; `Window.all` is a small native windows-list INVOKE. Spec: `docs/superpowers/specs/2026-06-28-n2a-router-core-design.md`.

**Tech Stack:** Nim (routerstate + router.nim wire), ObjC (window-list enumerator), TypeScript (runtime handle + tests), Bun.

## Global Constraints

- Branch `feat/ios-native-nav` — commit directly. NO worktree, NO `git commit --amend`, NO merge.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Per-file `git add` only — never `-A`/`.`. Pre-existing unrelated WIP stays unstaged.
- Bun, never Node.
- Native-first parity: TS runtime ↔ Nim wire ↔ native, same PR; Nim faithful to the wire contract.
- macOS is the testable reference; iOS must keep COMPILING (iOS native routing is N3 — no iOS routing behavior here). NO iOS simulator interaction in-session.
- `ROUTE_CHANGED` uses the global-broadcast path (`dispatch_event_to_all`) — do NOT touch `ZAPP_MAX_WINDOW_EVENT_TYPES` / the bitmask.

Per-task gates: `bun run check`; `bun test cli/src`; `bun run test:native`; macOS build (`cd kitchen-sink && bun run build` → `[zapp] build complete:`); iOS compile (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`). TS-test tasks also run `bun test runtime/<file>`.

## Reference map (from exploration — read before implementing)

- **`windowAction(action, args)`** (`runtime/window.ts:1180`): posts `{t:4, m:action, a:args}`. Fire-and-forget. `.router` ops use it.
- **`createSidebarHandle`** (`runtime/window.ts:1202-1250`): the exact template — module `Map` for per-window state, a `Wired` `Set` to avoid duplicate `bridge.on` subscriptions, getters reading the state map, ops calling `windowAction`. `.router` mirrors this.
- **`createWindowHandle(windowId, sidebarOpts?, inspectorOpts?)`** (`runtime/window.ts:1293`): returns the handle with `.sidebar`/`.inspector`/`.toolbar`. Add `.router` here.
- **`Window`** object (`runtime/window.ts:1446`): `current()`/`create()`/`isSidebar()`/`isInspector()`. Add `get(id)` + `all()`. `Window.create` worker branch uses `globalThis.__zappBridge.createWindow` (sync); webview branch uses `bridge.invoke("__window:create", …)`.
- **`runtime/events.ts`**: `WindowEvent` enum (next free id **21**), `WINDOW_EVENT_NAMES` map, `eventName(e)` helper. `TOOLBAR_CLICKED=15` → `"window:toolbar-clicked"` is the broadcast-event precedent.
- **`native/nim/router.nim`**: `routeMessage` dispatches t:1 INVOKE (answered via `sendInvokeResponse(windowId, id, ok, payloadStr)`), t:4 `routeWindowAction(action, a, windowId, payload)`. Window resolve: `darwin_window_numeric_id_for_string(widArg.cstring)` (from `a{"windowId"}`), fallback to the sender. `darwin_window_get_by_numeric_id(id)`. The `toolbar:*` arm is the structural template for `router:*`.
- **`dispatch_event_to_all*(eventName: cstring, payload: cstring)`** (`native/nim/dispatch.nim:58`): broadcasts `b._onEvent(name, payload)` to all webviews + all workers. Reuse for ROUTE_CHANGED (payload carries `windowId`; handlers filter). Workers already receive such broadcasts by name (the toolbar-clicked precedent) — **no `bootstrap/worker.ts` change expected** (verify in T3).
- **Window registry**: `native/platform/darwin/window.m` `static NSString* zapp_window_ids[ZAPP_MAX_WINDOW_CALLBACKS]` (the `"win-…"` id strings); `darwin_window_get_by_numeric_id` (:596), `darwin_window_numeric_id_for_string` (:564). iOS: `native/platform/ios/window.m` `zapp_ios_windows` + `darwin_window_get_by_numeric_id`. Enumeration for `Window.all()` is a small add on both.
- **Nim unit tests** run via `bun run test:native` (`cli/src/test-native.ts`). Follow an existing `*.test.nim` pattern (e.g. `native/nim/permissions` tests referenced in prior cycles) — a `when isMainModule` / `doAssert` style module compiled + run by the harness. The implementer confirms the exact harness convention by reading `cli/src/test-native.ts` + an existing native test.

---

## Task 1: Native route-state store + unit test (`routerstate.nim`)

**Files:**
- Create: `native/nim/routerstate.nim`
- Create: `native/nim/routerstate.test.nim` (or the harness's test location/convention — confirm via `cli/src/test-native.ts`)

**Interfaces:**
- Produces (consumed by Task 2): a per-window route store with `routerPush/routerPop/routerForward/routerReplace/routerPopToRoot/routerSeed/routerClear` + readers `routerCurrentUrl/routerCurrentParams/routerCanGoBack/routerCanGoForward` keyed by `int32` window id.

- [ ] **Step 1: Confirm the native-test convention** — read `cli/src/test-native.ts` and one existing `native/nim/*` unit test to match the file location, imports, and assert style (`doAssert`/`unittest`). Use that convention for `routerstate.test.nim`.

- [ ] **Step 2: Write the failing test** (`routerstate.test.nim`) covering the stack semantics:
  - seed → `canGoBack=false`, `canGoForward=false`, currentUrl = seed url.
  - push "/a", push "/b" → currentUrl "/b", canGoBack=true, canGoForward=false.
  - pop → currentUrl "/a", canGoBack=false, canGoForward=true (forward preserved).
  - forward → currentUrl "/b", canGoForward=false.
  - pop, then push "/c" → forward truncated: currentUrl "/c", canGoForward=false, canGoBack=true.
  - replace "/z" → currentUrl "/z", canGoBack unchanged, canGoForward unchanged (in-place).
  - popToRoot → currentUrl = seed url, canGoBack=false, canGoForward=false.
  - params round-trip: push("/d", "{\"id\":42}") → currentParams == "{\"id\":42}".
  - pop at root / forward at head → no-op (no crash).
  - clear → subsequent readers safe (treat as empty/seed-absent: currentUrl "" or sentinel).

- [ ] **Step 3: Run it, verify failure** — `bun run test:native` (or the harness's single-file invocation) → FAIL (module/procs absent).

- [ ] **Step 4: Implement `routerstate.nim`:**

```nim
## Authoritative per-window route stack (N2a). Pure logic; the wire layer
## (router.nim) mutates it and emits ROUTE_CHANGED. Browser-history semantics:
## pop preserves forward; push truncates forward.
import std/tables

type
  RouteEntry = object
    url: string
    params: string          # JSON string; "" when none
  RouteState = object
    entries: seq[RouteEntry]
    cur: int

var gRoutes: Table[int32, RouteState]

proc routerSeed*(win: int32, url: string) =
  ## Establish the root entry (called once at window create). No-op if present.
  if not gRoutes.hasKey(win):
    gRoutes[win] = RouteState(entries: @[RouteEntry(url: url, params: "")], cur: 0)

proc routerClear*(win: int32) =
  gRoutes.del(win)

proc routerPush*(win: int32, url, params: string) =
  if not gRoutes.hasKey(win): routerSeed(win, "/")
  var s = gRoutes[win]
  s.entries.setLen(s.cur + 1)               # truncate forward
  s.entries.add RouteEntry(url: url, params: params)
  s.cur = s.entries.high
  gRoutes[win] = s

proc routerReplace*(win: int32, url, params: string) =
  if not gRoutes.hasKey(win): routerSeed(win, "/")
  var s = gRoutes[win]
  s.entries[s.cur] = RouteEntry(url: url, params: params)   # in place; forward preserved
  gRoutes[win] = s

proc routerPop*(win: int32): bool =
  if not gRoutes.hasKey(win): return false
  var s = gRoutes[win]
  if s.cur <= 0: return false
  s.cur.dec
  gRoutes[win] = s
  return true

proc routerForward*(win: int32): bool =
  if not gRoutes.hasKey(win): return false
  var s = gRoutes[win]
  if s.cur >= s.entries.high: return false
  s.cur.inc
  gRoutes[win] = s
  return true

proc routerPopToRoot*(win: int32): bool =
  if not gRoutes.hasKey(win): return false
  var s = gRoutes[win]
  if s.entries.len <= 1 and s.cur == 0: return false
  s.entries.setLen(1)
  s.cur = 0
  gRoutes[win] = s
  return true

proc routerCurrentUrl*(win: int32): string =
  if gRoutes.hasKey(win): (let s = gRoutes[win]; (if s.entries.len > 0: s.entries[s.cur].url else: "")) else: ""
proc routerCurrentParams*(win: int32): string =
  if gRoutes.hasKey(win): (let s = gRoutes[win]; (if s.entries.len > 0: s.entries[s.cur].params else: "")) else: ""
proc routerCanGoBack*(win: int32): bool =
  gRoutes.hasKey(win) and gRoutes[win].cur > 0
proc routerCanGoForward*(win: int32): bool =
  gRoutes.hasKey(win) and gRoutes[win].cur < gRoutes[win].entries.high
```

(Adjust the one-line getters to plain `if/else` blocks if the terse form trips Nim parsing — keep behavior identical.)

- [ ] **Step 5: Run the test, verify pass** — `bun run test:native` → routerstate test PASS.

- [ ] **Step 6: Gates** — `bun run check`; `bun test cli/src`; `bun run test:native`. (No app build needed — pure module + test.)

- [ ] **Step 7: Commit** — `git add native/nim/routerstate.nim native/nim/routerstate.test.nim` (+ the harness registration file if `test-native.ts` needs the new test listed — stage it too); trailer.

---

## Task 2: Native router wire — `router:*` arms + INVOKEs + emit + window-list

**Files:**
- Modify: `native/nim/router.nim`
- Modify: `native/platform/darwin/window.m` + `native/platform/ios/window.m` (window-list enumerator)
- Modify: the window-create path (seed) + teardown (clear) — likely `native/nim/window.nim` and/or `router.nim`’s `__window:create` (confirm where windows are created/destroyed in the Nim layer).

**Interfaces:**
- Consumes: Task 1’s `routerstate` procs; `dispatch_event_to_all`; `darwin_window_numeric_id_for_string` / `darwin_window_get_by_numeric_id`.
- Produces (consumed by Task 3): wire actions `router:push|pop|forward|replace|popToRoot` (t:4) and INVOKEs `__router:state` + `__zapp:windows-list`; emits `window:route-changed`.

- [ ] **Step 1: Window-list enumerator (native).** Add `const char* darwin_windows_list_json(void)` to `native/platform/darwin/window.m` — iterate `zapp_window_ids[]`, collect non-empty ids into a JSON array string `["win-..",…]` (heap-dup, caller frees; match the existing heap-return convention used elsewhere). Add the **same-signature** function to `native/platform/ios/window.m` over `zapp_ios_windows` so iOS compiles + works. Declare `proc darwin_windows_list_json(): cstring {.importc, cdecl.}` in `router.nim`.

- [ ] **Step 2: ROUTE_CHANGED emit helper (router.nim).** Add a helper that builds the payload `{"windowId":"win-<N>","url":<json>,"params":<paramsObjOrNull>,"canGoBack":<bool>,"canGoForward":<bool>,"kind":"<kind>"}` and calls `dispatch_event_to_all("window:route-changed".cstring, payload.cstring)`. Use `std/json` to encode url (string) + params (parse the stored params JSON string into a node, or `null` when ""); booleans from `routerCanGoBack/Forward`. The window-id string is `"win-" & $win`.

- [ ] **Step 3: `router:*` t:4 arms (router.nim).** In `routeWindowAction`, add an `if action.startsWith("router:"):` block mirroring the `toolbar:*` arm — resolve `target` from `a{"windowId"}` (→ `darwin_window_numeric_id_for_string`, fallback to the sender’s resolved id). Then:
  - `router:push` → `routerPush(target, a{"url"}.getStr(""), (if a.hasKey("params"): $a["params"] else: ""))`; emit ROUTE_CHANGED kind `"push"`.
  - `router:pop` → if `routerPop(target)`: emit kind `"pop"`.
  - `router:forward` → if `routerForward(target)`: emit kind `"forward"`.
  - `router:replace` → `routerReplace(target, url, params)`; emit kind `"replace"`.
  - `router:popToRoot` → if `routerPopToRoot(target)`: emit kind `"popToRoot"`.
  `import` the `routerstate` module at the top of router.nim.

- [ ] **Step 4: INVOKEs (router.nim, t:1 branch).** In the INVOKE dispatch (where `__window:create` etc. are answered):
  - `__router:state` `{windowId}` → resolve target → `sendInvokeResponse(windowId, id, true, <{"url":..,"params":..,"canGoBack":..,"canGoForward":..} json>)`.
  - `__zapp:windows-list` → `sendInvokeResponse(windowId, id, true, <{"ids": <darwin_windows_list_json result>}>` or return the array directly — match what Task 3’s `Window.all()` parses; keep it `{"ids":[...]}`).

- [ ] **Step 5: Seed + clear.** At window creation (the Nim `createWindow` / `__window:create` path — confirm the exact site), call `routerSeed(newWinId, <initial url or "/">)`. At window destroy/teardown (where toolbar/sidebar unregister), call `routerClear(winId)`. (If the initial url isn’t readily available at the seed site, seed `"/"` — the app replaces it on first route.)

- [ ] **Step 6: Build gates** — macOS build + iOS compile (both `[zapp] build complete:`); `bun run check`; `bun test cli/src`; `bun run test:native`.

- [ ] **Step 7: Commit** — `git add native/nim/router.nim native/platform/darwin/window.m native/platform/ios/window.m` (+ the seed/clear file if separate); trailer.

---

## Task 3: Runtime `.router` handle + `Window.get`/`all` + events + tests + docs

**Files:**
- Modify: `runtime/events.ts` (ROUTE_CHANGED)
- Modify: `runtime/window.ts` (RouteOptions, createRouterHandle, `.router`, `Window.get`, `Window.all`)
- Modify: `bootstrap/worker.ts` (only if verification shows a change is needed)
- Test: `runtime/router.test.ts` (new)
- Modify: `docs/api-reference.md` (Router section)

**Interfaces:**
- Consumes: Task 2’s wire (`router:*`, `__router:state`, `__zapp:windows-list`, `window:route-changed`).

- [ ] **Step 1: events.ts** — add `ROUTE_CHANGED = 21` to `WindowEvent` (with a doc comment: payload `{windowId,url,params,canGoBack,canGoForward,kind}`) and `[WindowEvent.ROUTE_CHANGED]: "window:route-changed"` to `WINDOW_EVENT_NAMES`.

- [ ] **Step 2: Write failing TS tests** (`runtime/router.test.ts`) with a mocked bridge (follow the mock pattern in existing runtime tests):
  - `createWindowHandle(id).router.push("/a")` posts `{t:4, m:"router:push", a:{windowId:id, url:"/a"}}` (assert via the mock’s captured `post`).
  - `.push({url:"/d", params:{id:42}})` includes `params:{id:42}`.
  - `.pop()/.forward()/.replace(..)/.popToRoot()` post the right `m`.
  - A `ROUTE_CHANGED` event (`window:route-changed` with the handle’s windowId) updates `router.canGoBack/canGoForward/url/params`; an event for a DIFFERENT windowId does not.
  - `Window.get("win-9")` returns a handle whose `.router.push` targets `win-9`.

- [ ] **Step 3: Run, verify fail** — `bun test runtime/router.test.ts`.

- [ ] **Step 4: Implement in `runtime/window.ts`** (mirror `createSidebarHandle`):
  - `export interface RouteOptions { url: string; title?: string; params?: Record<string, unknown>; presentation?: WindowPresentation; }` (reuse the existing presentation type name from WindowOptions).
  - `routerState` `Map<string, {url:string; params:any; canGoBack:boolean; canGoForward:boolean}>` + `routerWired` `Set<string>`.
  - `createRouterHandle(windowId)`: on first creation seed the state record (defaults: url "", params null, canGoBack/Forward false) + (best-effort) `getBridge().invoke("__router:state", {windowId})` to populate it; if not `routerWired`, `bridge.on(eventName(WindowEvent.ROUTE_CHANGED), p => { if (p?.windowId===windowId) { record.url=p.url; record.params=p.params; record.canGoBack=p.canGoBack; record.canGoForward=p.canGoForward; } })`. Returns:
    - `push(opts: RouteOptions | string)` → normalize string→`{url}`; `windowAction("router:push", {windowId, url, ...(params?{params}:{})})`. (title accepted, passed through.)
    - `pop()` → `windowAction("router:pop", {windowId})`; `forward()` → `"router:forward"`; `replace(opts)` → `"router:replace"` with url/params; `popToRoot()` → `"router:popToRoot"`.
    - getters `get canGoBack`, `get canGoForward`, `get url`, `get params` from the state record.
    - `on(handler)` → `bridge.on(eventName(WindowEvent.ROUTE_CHANGED), p => { if (p?.windowId===windowId) handler(p); })`.
  - In `createWindowHandle`, add `router: createRouterHandle(windowId),` (always present).
  - `Window.get(id: string): WindowHandle` → `createWindowHandle(id)` (no sidebar/inspector opts — those are current-window-only; router/toolbar/base ops work by id).
  - `Window.all(): Promise<WindowHandle[]>` → `const r = await getBridge().invoke("__zapp:windows-list", {}) as {ids:string[]}; return (r.ids ?? []).map(id => createWindowHandle(id));`. In a worker, `getBridge().invoke` must work (it does for `__window:create`); if the worker bridge lacks `invoke`, gate `Window.all` to return `[]` with a one-time warn (confirm worker bridge capability).
  - Add `router` to the `WindowHandle` interface type + `RouteOptions` to exports (`runtime/index.ts` if window types are re-exported there — confirm).

- [ ] **Step 5: Run TS tests, verify pass** — `bun test runtime/router.test.ts`.

- [ ] **Step 6: Verify worker ROUTE_CHANGED delivery** — confirm (by reading `bootstrap/worker.ts` `_onEvent` + the toolbar-clicked precedent) that a worker doing `Window.get(id).on(handler)` / `bridge.on("window:route-changed", …)` receives the broadcast WITHOUT a `windowEventIds` entry. If (and only if) the reverse-map requires it, add `"window:route-changed"` minimally. Note the finding in the report.

- [ ] **Step 7: Docs** — `docs/api-reference.md`: add a **Router** section: `Window.current().router` (push/pop/forward/replace/popToRoot, canGoBack/canGoForward, url, params), `RouteOptions`, `Window.get(id)` / `Window.all()`, the `ROUTE_CHANGED` event + payload, the params-durability note (URL = durable identity; `params` ephemeral), and the desktop-vs-iOS note (desktop = logical stack driving toolbar back/forward this cycle (N2b wires the demo); iOS native routing = later). Match surrounding doc style.

- [ ] **Step 8: Full gates** — `bun run check`; `bun test cli/src`; `bun test runtime/router.test.ts`; `bun run test:native`; macOS build; iOS compile.

- [ ] **Step 9: Commit** — `git add runtime/events.ts runtime/window.ts runtime/router.test.ts docs/api-reference.md` (+ `runtime/index.ts` / `bootstrap/worker.ts` if changed); trailer.

- [ ] **Step 10: HUMAN SMOKE GATE (macOS)** — STOP for the controller/user. In the running kitchen-sink devtools console:
  ```js
  const w = Window.current();
  w.on(WindowEvent.ROUTE_CHANGED, e => console.log("route", e));
  w.router.push("/a"); w.router.push({url:"/b", params:{id:42}});
  console.log(w.router.canGoBack, w.router.canGoForward, w.router.url, w.router.params);
  w.router.pop();  console.log(w.router.canGoBack, w.router.canGoForward); // back=false, forward=true
  w.router.forward(); w.router.replace("/z"); w.router.popToRoot();
  await Window.all();           // lists the window(s)
  Window.get(w.id).router.push("/x");  // round-trips
  ```
  Expect: ROUTE_CHANGED fires each mutation with correct `url`/`params`/`canGoBack`/`canGoForward`/`kind`; getters track the stack; `Window.all()` returns the window; `Window.get` works. (No visible nav UX — that’s N2b.) macOS build + iOS compile both green.

## Self-Review

**Spec coverage:** routerstate authoritative stack + tests (T1); router:* wire + INVOKEs + emit + windows-list + seed/clear (T2); events ROUTE_CHANGED, .router handle, Window.get/all, RouteOptions, params, tests, docs, smoke (T3). All spec sections covered. window.create-iPhone-fallback + kitchen-sink wiring + worker Platform are explicitly N2b/N2c (not here).

**Placeholder scan:** routerstate.nim is concrete; router.nim arms + native enumerator are port-style with exact signatures + the toolbar arm as the named template; the TS handle mirrors the quoted createSidebarHandle with concrete ops. The few "confirm the exact site" notes (native-test convention, seed/clear site, worker bridge invoke capability, index.ts re-export) are decidable lookups, not placeholders.

**Type/name consistency:** wire action names (`router:push|pop|forward|replace|popToRoot`), INVOKE names (`__router:state`, `__zapp:windows-list`), event name (`window:route-changed`) + id (21), payload keys (windowId/url/params/canGoBack/canGoForward/kind), and the routerstate proc names are identical across T1→T2→T3.
