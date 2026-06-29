# N2a — Router Core API — Design

**Date:** 2026-06-28
**Branch:** `feat/ios-native-nav` (commit directly; UNMERGED)
**Program:** iOS Native Navigation, cycle **N2 sub-cycle A** (`docs/superpowers/specs/2026-06-27-ios-native-navigation-program-design.md`). Builds on N0 (Platform API) + N1 (native iOS toolbar), both shipped.
**Status:** Approved (design) → writing-plans → SDD.

## Goal

Ship the **cross-platform Router core**: `Window.current().router` (push / pop / forward / replace / popToRoot + `canGoBack` / `canGoForward` / `params`), `RouteOptions`, `Window.get(id)` / `Window.all()` (window-handle-by-id — enables worker-driven routing), the **`ROUTE_CHANGED`** event (webviews + workers), the native `router:*` wire + an **authoritative per-window route stack**. This is the API + state layer. The **visible desktop wiring** (kitchen-sink uses the router; toolbar back/forward bound) is **N2b**; **iOS native UINavigationController routing** is **N3**. N2a is fully unit-testable + macOS-smokeable.

## Current state (from exploration)

- **Handle pattern** (`runtime/window.ts`): `Window.current()` resolves `globalThis[Symbol.for("zapp.windowId")]`; `createWindowHandle` exposes `.sidebar`/`.inspector`/`.toolbar` handles; `createSidebarHandle` (state map + `windowAction(t:4)` for ops + `bridge.on(eventName(...))` filtered by `windowId`) is the exact template for `.router`. `windowAction(action, {windowId, …})` posts `{t:4, m:action, a:args}`. INVOKE is `bridge.invoke("__name", args)` → `{t:1}`.
- **`Window.get`/`Window.all` do not exist** — the #1 missing primitive (a worker can't get a handle to a window it only knows by id from an event payload).
- **`ROUTE_CHANGED`**: next event id is **21** (`runtime/events.ts` enum ends at `TOOLBAR_GROUP_SELECTED=20`). Native bitmask `ZAPP_MAX_WINDOW_EVENT_TYPES=12` (`native/nim/events.nim`) — but chrome events (ids 12–20) **already bypass the bitmask** via a global broadcast filtered client-side by `windowId` (how `TOOLBAR_CLICKED` works: `dispatch_event_to_all` / `worker_broadcast_eval_js`). ROUTE_CHANGED reuses that — **no bitmask change.**
- **Native dispatch** (`native/nim/router.nim`): `routeWindowAction` (t:4) has `sidebar:*`/`toolbar:*`/`window:*` arms resolving the target via `a{"windowId"}` → `darwin_window_numeric_id_for_string` (falling back to the sender). `router:*` slots in identically. INVOKE (`__name`) answered in the t:1 branch (e.g. `__window:create`). `dispatch_event_to_all` (`native/nim/dispatch.nim`) is the broadcast helper.
- **Window registry**: `darwin_window_get_by_numeric_id` (macOS) / `zapp_ios_windows` (iOS) exist for lookup-by-id; enumeration (for `Window.all()`) is a small add.
- **Worker delivery**: `worker_broadcast_eval_js` calls `b._onEvent(name, json)`; the worker's `_onEvent` (`bootstrap/worker.ts`) reverse-maps the name to handlers — ROUTE_CHANGED just needs to be a recognized name there (broadcast, no `subscribeWindowEvent` needed).

## Design

### Authoritative per-window route stack (native)

The route stack lives in **native** (authoritative), per window — makes webview-initiated and **worker-initiated** pushes symmetric and keeps `canGoBack/Forward` authoritative across webview reloads. A small Nim module (`native/nim/routerstate.nim`):

```nim
type RouteEntry = object
  url: string
  params: string        # JSON string (opaque to native; "" when none)
type RouteState = object
  entries: seq[RouteEntry]
  cur: int              # index of the current entry
# Per-window: Table[int32, RouteState]
```

Operations (browser-history semantics — drives desktop toolbar back/forward):
- **`push(url, params)`** — drop entries after `cur`, append, `cur = entries.high`.
- **`pop()`** (Back) — if `cur > 0`: `cur -= 1` (forward **preserved** so the toolbar Forward works). No-op at root.
- **`forward()`** — if `cur < entries.high`: `cur += 1`.
- **`replace(url, params)`** — overwrite `entries[cur]` in place (`cur` unchanged; back/forward preserved) — swaps the current route's identity without adding a history entry (browser `replaceState` semantics).
- **`popToRoot()`** — `entries.setLen(1)`, `cur = 0`.
- **Seed:** on window create the stack seeds `[{url: <window's initial url or "/">, params: ""}]`, `cur = 0` (so `canGoBack=false` initially); no ROUTE_CHANGED for the seed (the webview already shows root).
- **Derived:** `canGoBack = cur > 0`; `canGoForward = cur < entries.high`.

> iOS nuance (N3): `UINavigationController` has no "forward"; `forward()`/`canGoForward` are desktop-meaningful now and will be constrained/redefined for the iOS stack in N3. Documented, not implemented here.

Every mutating op emits **`ROUTE_CHANGED`** for that window after updating the stack.

### `ROUTE_CHANGED` event

- `runtime/events.ts`: `WindowEvent.ROUTE_CHANGED = 21` → name `"window:route-changed"`.
- **Delivery:** global broadcast carrying `windowId`, filtered client-side (the `TOOLBAR_CLICKED` pattern) — reuses `dispatch_event_to_all` (webviews) + `worker_broadcast_eval_js` (workers). **No bitmask/`ZAPP_MAX_WINDOW_EVENT_TYPES` change.**
- **Payload:** `{ "windowId": "win-N", "url": "...", "params": <obj|null>, "canGoBack": bool, "canGoForward": bool, "kind": "push"|"pop"|"forward"|"replace"|"popToRoot" }`.
- `bootstrap/worker.ts`: add `"window:route-changed"` to the worker `_onEvent` name table so `win.on(ROUTE_CHANGED, …)` works in a worker (broadcast — no subscribe needed).

### Runtime `.router` handle (`runtime/window.ts`)

`createRouterHandle(windowId)` mirrors `createSidebarHandle`:
- **State cache** (per windowId): `{ url, params, canGoBack, canGoForward }`, updated on every `ROUTE_CHANGED` (filtered by windowId). Seeded best-effort via a `__router:state` INVOKE when the handle first wires (so a freshly-obtained `Window.get(id)` handle has current values).
- **Imperative ops** (all `windowAction(t:4)` targeting `windowId`): `push(opts: RouteOptions | string)`, `pop()`, `forward()`, `replace(opts)`, `popToRoot()`.
- **Getters:** `get canGoBack`, `get canGoForward`, `get params` (current entry's params, ephemeral), `get url`.
- **Events:** `on(handler)` convenience for ROUTE_CHANGED (or app uses `win.on(WindowEvent.ROUTE_CHANGED, …)`).
- Wired onto `createWindowHandle` as `.router` (always present, like `.toolbar`).

```ts
export interface RouteOptions {
  url: string;                       // required — the route's identity
  title?: string;                    // optional surface title
  params?: Record<string, unknown>;  // ephemeral serializable hand-off (NOT durable across cold restore)
  presentation?: WindowPresentation; // accepted; desktop ignores (iOS sheet routes = later)
}
```
`router.push("/detail?id=42")` (string shorthand) ≡ `router.push({ url: "/detail?id=42" })`.

### `Window.get(id)` / `Window.all()`

- **`Window.get(id: string): WindowHandle`** — pure JS: `createWindowHandle(id, …)`. Handle ops target by id; ops on a dead window no-op natively (router.nim resolves → nil → return). Usable from **any context** (webview or worker) — the worker-driven-routing enabler (`Window.get(evtWindowId).router.push(...)`).
- **`Window.all(): Promise<WindowHandle[]>`** — async INVOKE `__zapp:windows-list` → live numeric ids → handles. Native adds a window-registry enumeration (`darwin`/`ios` window list). On single-window iPhone, `Window.all()` ≈ `[the one window]`.

### Native `router:*` wire (`native/nim/router.nim`)

A `router:*` arm in `routeWindowAction` (t:4), resolving the target window via `a{"windowId"}` (same as toolbar/sidebar):
- `router:push` `{windowId, url, params}` → routerstate push → emit ROUTE_CHANGED.
- `router:pop` / `router:forward` / `router:popToRoot` `{windowId}` → mutate → emit.
- `router:replace` `{windowId, url, params}` → mutate → emit.
- INVOKE `__router:state` `{windowId}` → returns `{url, params, canGoBack, canGoForward}` (for handle seeding).
- INVOKE `__zapp:windows-list` → returns `{ids: ["win-1", …]}`.
- Window teardown clears its RouteState entry (parity with toolbar/sidebar unregister).

## Components

| File | Change |
|---|---|
| `native/nim/routerstate.nim` (new) | per-window `RouteState` store + push/pop/forward/replace/popToRoot + canGoBack/Forward + seed/clear; pure, unit-tested. |
| `native/nim/router.nim` | `router:*` t:4 arms + `__router:state`/`__zapp:windows-list` INVOKE; ROUTE_CHANGED emit (broadcast w/ windowId); seed stack at window create; clear at teardown. |
| `native/nim/routerstate.test.nim` (new) | Nim unit test: stack ops + canGoBack/Forward + forward-truncate-on-push + popToRoot + seed. |
| `runtime/events.ts` | `WindowEvent.ROUTE_CHANGED = 21` + `"window:route-changed"` name. |
| `runtime/window.ts` | `RouteOptions`; `createRouterHandle`; `.router` on `createWindowHandle`; `Window.get(id)`; `Window.all()`. |
| `runtime/window.test.ts` (or `router.test.ts`) | TDD: router handle ops post the right `t:4`/args; ROUTE_CHANGED updates cached getters + params; `Window.get` handle shape; `Window.all` parses the list. |
| `bootstrap/worker.ts` | recognize `"window:route-changed"` in the worker `_onEvent` name table. |
| `docs/api-reference.md` | Router section (Window.current().router, RouteOptions, Window.get/all, ROUTE_CHANGED, params durability note, desktop-vs-iOS note). |

## Decisions (confirmed)

1. **Native-authoritative per-window stack** (symmetric webview/worker initiation; authoritative canGoBack/Forward).
2. **`ROUTE_CHANGED` = global broadcast carrying `windowId`, filtered client-side** — no bitmask change.
3. **`RouteOptions` minimal** (`url`, `title?`, `params?`; `presentation?` accepted-but-desktop-ignores; per-route `toolbar` deferred).
4. **`router.params`** = current entry's params, delivered in ROUTE_CHANGED + readable as `router.params` (ephemeral; URL is durable identity).
5. **`Window.get(id)` pure-JS; `Window.all()` native windows-list INVOKE.**
6. Browser-history semantics (`pop` preserves forward) + `forward()`/`canGoForward` for the desktop toolbar; iOS forward nuance deferred to N3.

## Out of scope / deferred

- **N2b:** kitchen-sink uses the router (replace `ks:nav`/`innerHTML` with `router.push`; wire toolbar back/forward → `router.pop`/`forward` + enabled state); `window.create`-on-iPhone warn+fallback-to-`router.push`.
- **N2c:** bake `os`/`env` into worker bundles (Platform in workers).
- **N3:** iOS native `UINavigationController` per-route-webview routing (the differentiator, risk-gated).
- Per-route `toolbar` chrome; declarative route tree; native tab bars.

## Testing & gates

- **Nim unit test** (`routerstate.test.nim`, TDD) for the authoritative stack logic; **TS tests** for the handle + Window.get/all (mock bridge).
- Gates each task: `bun run check`; `bun test cli/src`; `bun test runtime/…` (the new TS tests); `bun run test:native` (incl. the new Nim test); macOS build (`cd kitchen-sink && bun run build` → `[zapp] build complete:`); iOS compile (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:` — must keep compiling; iOS routing is N3).
- **Human smoke (macOS):** in devtools, `const w = Window.current(); w.on(WindowEvent.ROUTE_CHANGED, e=>console.log(e)); w.router.push("/a"); w.router.push("/b"); w.router.pop();` → ROUTE_CHANGED fires with correct `url`/`canGoBack`/`canGoForward`/`kind`/`params`; `w.router.canGoBack/canGoForward` reflect the stack; `Window.all()` lists the window(s); `Window.get(w.id)` round-trips. (Visible nav UX is N2b.)

## Constraints

Branch `feat/ios-native-nav` (commit on it directly), UNMERGED; commit trailer EXACTLY `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; per-file `git add`; Bun; native-first parity (TS runtime → Nim wire/state → docs, same PR; Nim faithful to the wire contract); NO iOS simulator interaction in-session (build-only gates + macOS human smoke); macOS is the testable reference; iOS must keep compiling (routing = N3); docs updated in the same PR.
