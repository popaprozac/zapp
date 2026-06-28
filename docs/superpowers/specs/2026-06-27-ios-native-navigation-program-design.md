# iOS Native Navigation — Program Design / Decision Doc

**Date:** 2026-06-27
**Branch:** the whole program runs on a dedicated branch **`feat/ios-native-nav`** (cut from `feat/nim-native`). Rationale: it's a large new feature arc, NOT a prerequisite for getting `feat/nim-native` onto main, so isolating it keeps `feat/nim-native` independently mergeable and contains N3's risk. `feat/nim-native` is not worked concurrently until this program finishes, so rebase cost is low.
**Status:** Architecture approved; governs a multi-cycle program (each sub-cycle gets its own spec → plan → SDD)
**Builds on:** toolbar placement model (#643, shipped) — the cross-platform `placement` API this program consumes.

## Vision

Give Zapp apps **real native iOS navigation chrome** — native navigation bars *and* an optional native `UINavigationController` routing stack with native back button, large titles, and interactive swipe-back. No web-shell peer (Electron / Tauri / Wails) offers true native iOS routing; they render all chrome in HTML. This is a headline differentiator. macOS stays the parity reference and must not regress.

## The conceptual model: a *surface* = `url + chrome`, presented per-platform

Both "a window" and "a route" are the same thing — **render this URL with this chrome** — differing only in **presentation + lifecycle**. They **share the options shape**; they **split on lifecycle**.

| | Window | Route |
|---|---|---|
| Lifecycle | independent, positioned, closeable, *many* | stacked, pop/back, *within* a window |
| Presentation | new OS window | push onto a nav stack |
| Platforms | macOS / Windows / iPad multi-window (future) | iOS nav stack (+ desktop in-window) |

Platform chrome shapes differ fundamentally:
- **macOS:** ONE `NSToolbar` spans sidebar+content (`trackingSeparator` marks the boundary); `placement` (leading/center/trailing) maps to one bar.
- **iOS:** NO window-spanning bar. `UISplitViewController` has a `UINavigationController` **per column**, each with its own `UINavigationItem` (leading / titleView / trailing). A paned window has up to **three** bars. `displayModeButtonItem` is the system `☰` that toggles the sidebar column. A bottom `UIToolbar` is the iPhone primary-action surface (`placement: "bottom"`, deferred).

## Two orthogonal opt-in axes (default = today)

1. **Native toolbar** — render the `placement` items in the content column's `UINavigationItem`, over **today's single content webview**. No routing required.
2. **Native routing** — a real `UINavigationController` stack where routes are native VCs. **Opt-in.** Without it: exactly today (one content webview, web SPA), optionally with the native toolbar.

Additive ladder: today → native toolbar → native toolbar + native routing. This is also the ship order.

## Foundation: base/relative URL model (already how Zapp windows work)

- `WindowOptions.url` → **dev:** Vite server (base); **prod:** `zapp://` embedded bundle (base).
- Relative (`/settings?foo=bar`) resolves against the base; absolute `https://…` loads external.
- A **route reuses this exact resolution** — a route is "a URL rendered as a surface." No new loading model, no build-pipeline change. (Wails-style.)

## Efficiency model — per-route webviews, done the Zapp way

Native routing means **each route is its own webview** (so native push/back/swipe are real). Naive cost = N web-content processes + N bundle boots. Mitigated by Zapp's existing sharing primitives:

- **Shared, cached bundle.** Every route webview loads the *same* `zapp://index.html`. WebKit resource cache + JS-engine bytecode cache amortize parse/compile across instances; same-origin + same `WKWebsiteDataStore` shares storage (and often the content process).
- **Conditional render per route.** Each webview boots the runtime once and renders **only its route** (route read from the URL fragment/query). Per-webview memory ≈ runtime + one thin view.
- **Shared state in the headless worker.** App data / sync-engine lives in the **worker** (zjs/JSC); route webviews are thin presentation layers that subscribe. Cross-route consistency is automatic (one source of truth, not N). This is the native-first tenet paying off — and *why* per-route webviews stay cheap.
- **Lazy + bounded.** Create a route's webview on first push; keep the last K alive for instant native back/swipe; evict deeper ones and restore scroll/state from a snapshot on the way back.

## API shape

- **`Window.current().router`** — consistent with the existing `.toolbar` / `.sidebar` / `.inspector` handles.
- Imperative core: `router.push(opts)` / `.pop()` / `.replace(opts)` / `.popToRoot()`.
- **`RouteOptions`** = a cousin of `WindowOptions` (the route-relevant subset: `url`, `title`, `toolbar`, optional `presentation`). Symmetric with `window.create`.
- **Cross-platform, not iOS-only:** iOS = native `UINavigationController` push; **desktop = in-window navigation driving toolbar back/forward + the content route** (logical back stack). Same call works everywhere → app navigation code doesn't fork.
- **`window.create` on iPhone:** warn + fall back to `router.push` *if* routing is opted-in (graceful degradation for shared code), rather than silently returning a route as a window handle. On iPad it becomes a real window once multi-window lands (#655).
- **Declarative route tree** (in `zapp.config.ts` / `AppConfig`): later sugar for the "sidebar drives content" pattern; not the v1 primitive. Start imperative.
- Events: `ROUTE_CHANGED` (+ push/pop) — a `WindowEvent` that fans out to webviews **and subscribed workers** (reuses the worker event-delivery machinery). Exact enum values set in the cycle that builds it.

## Cross-context access — Router from workers (the shared-state payoff)

Routing is **per-window** (each window owns a nav stack), so the handle stays `win.router`. But the *window handle must be reachable from any context*, not just `Window.current()`:
- **webview:** `Window.current().router` (the window you're in).
- **worker:** `Window.current()` has no meaning (warns) → reach a window by id via a **window-handle-by-id API**: `Window.get(id)` / `Window.all()` (single-window iPhone → `Window.all()[0]`; iPad multi-window → by id). This is broader than routing and is added as part of the program.

This makes the worker a first-class navigation participant — the "worker as the app's brain" payoff (the same worker that holds shared route state can also drive + observe navigation):
- **`win.router.on(ROUTE_CHANGED, …)`** — observe route changes from a worker (e.g. preload the new route's data before the surface renders).
- **`Window.get(id).router.push/pop`** from a worker — a worker→host-bridge op routed by window id (same path as create-window-from-worker, which already works). Real use case: a **notification tap → worker → `push("/message/42")`** deep-link, driven entirely from the headless layer.

So `Router` is window-scoped (correct) yet reachable everywhere via `Window.get` / `Window.all` — the clean reconciliation of "Router as a top-level thing."

## Route params — three tiers, by durability

The route's identity *is* its URL, so params layer by how durable they must be:
1. **URL — identity + small params** (`push("/detail?id=42")`, read via `location.search` / `hash`). **Durable:** survives back/forward AND cold state-restoration (the URL is the route's true identity). Use for anything that must restore.
2. **`params` in `RouteOptions`** — richer ephemeral serializable hand-off (`push({ url: "/detail", params: {…} })`), received as **`Window.current().router.params`** on the new surface (the framework stores it with the nav-stack entry + injects it on boot). **Ephemeral:** may NOT survive a cold restore (only the URL is durable) — document this.
3. **Real data → the worker** (the idiomatic path) — the URL carries the **key** (`/detail?id=42`), the **worker holds the payload**, the new route subscribes and pulls it. No big-object serialization through navigation; consistent across routes.

Rule: **identity/restorable → URL; small ephemeral hand-off → `params`; actual data → worker.**

## Native architecture: the `NavContext` seam (forward-compatible with tab bars)

Route operations are scoped to a **navigation context** (`ZappIOSNavContext`) — a `UINavigationController` + its per-route webviews + back-stack cache — **not** to the window directly. A window owns **one** nav context today. A future `UITabBarController` = **N** nav contexts (one per tab), purely additive: `presentation: "window" | "route"` today; `"tab"` + per-tab `router` later. **The one rule to honor now:** never hardcode "one stack per window" in native or TS plumbing — own the route stack in the nav context.

## Current state (from code exploration)

- Navigation today is a **pure web SPA**: one persistent content `WKWebView`; `contentVC` never changes; "navigation" is a `stage.innerHTML` swap; sidebar tap emits a custom `ks:nav` event the content webview listens for. The only native `pushViewController` is the iPhone "show content" column reveal — not per-section.
- The per-column `UINavigationController`s already exist but are `navigationBarHidden = YES` (sidebar.m). `displayModeButtonItem` is unused.
- `ios/toolbar.m` is six no-op stubs with macOS-matching signatures; the `toolbar:*` router plumbing is fully wired in TS — calls reach native and are discarded.
- The placement wire JSON already carries `"placement"`; iOS can read it with no TS change.
- **Three risks flagged for the routing stack:** (1) WKWebView process/boot cost per route → mitigated by the efficiency model above; (2) `contentVC` is permanently embedded in a nav controller with AutoLayout constraints sidebar.m/inspector.m installed → a real push must push a *new* unconstrained VC, not reuse `contentVC`; (3) no framework-level route/title API exists → N2 creates it.

## Decomposition (each = its own brainstorm → spec → plan → SDD)

- **N0 — Platform runtime API** (#749, small, enabler). Round out `Platform` (os / form-factor / dev-vs-prod env) as the top-level conditional-logic export. Everything downstream's opt-in conditionals depend on it. Independent, useful on its own.
- **N1 — Native toolbar (iOS content nav bar).** Implement `ios/toolbar.m`: `placement` items → the content column's `UINavigationItem`; show the bar; `toggleSidebar` → `displayModeButtonItem`; `toolbar-clicked` / `group-selected` events; chrome-metrics + webview top-constraint/safe-area fix (`--zapp-toolbar-height`, the **risk gate**). Replace the kitchen-sink HTML top-bar. **No routing.** Lowest-risk, ships the visible native bar, builds the surface routing chrome later populates.
- **N2 — Router API + desktop.** `Window.current().router` (push/pop/replace/popToRoot), `RouteOptions` (incl. `params`), `router:*` wire plumbing, **`Window.get(id)`/`Window.all()`** (window-handle-by-id — enables worker-driven routing), the **`ROUTE_CHANGED`** event (webviews + subscribed workers), **`router.params`** (ephemeral hand-off channel), **desktop in-window nav + toolbar back/forward binding**, `window.create`-on-iPhone warn+fallback. Cross-platform surface; fully macOS-testable before iOS-stack work.
- **N3 — iOS native routing (the differentiator).** Starts with a **risk-gate spike** (per-route webview push/pop onto the content nav controller, shared cached bundle + conditional render, native back + swipe, cost, worker-shared-state). Then `ZappIOSNavContext` (per-route webviews, lazy + bounded back-stack cache + state restore), per-route chrome (title+toolbar update on push/pop), wired to N2's Router. Biggest/riskiest; gated.
- **Future (not this program): native tab bars** — accommodated by the `NavContext` seam.

**Sequence:** N0 → **N1** → N2 → N3. N1+N2 are real wins on their own and de-risk N3; N3 is where the killer feature lands.

## Interactions / deferred

- **A3 (#718, iPad inspector pane↔sheet)** — deferred; interacts with the inspector column but is independent of the toolbar/routing stack.
- **iPad multi-window (#655 discovery, #719 scene manifest)** — the per-window Router/NavContext model maps to per-`UIWindowScene` cleanly; multi-window is its own future program. `window.create` on iPad becomes a real window then.
- **`placement: "bottom"`** (iPhone bottom `UIToolbar`) — additive enum value, deferred to a later cycle.
- Declarative route tree, native tab bars — future sugar/programs.

## Constraints

Branch `feat/ios-native-nav` (cut from `feat/nim-native`) — commit on it directly, UNMERGED; commit trailer EXACTLY `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; per-file `git add`; Bun; native-first parity (C/Nim primitive → router → TS runtime → docs, same PR); Nim faithful to the wire contract; NO iOS simulator interaction in-session (build-only gates + human smoke); iOS arm64 / min 15.0 / sim-functional, device compile-only; default iOS engine zjs; macOS is the parity reference — the per-pane iOS model must NOT break the shipped macOS single-`NSToolbar` API/behavior; docs updated in the same PR.
