# N2b — Desktop In-Window Navigation — Design

**Date:** 2026-06-28
**Branch:** `feat/ios-native-nav` (commit directly; UNMERGED)
**Program:** iOS Native Navigation, cycle N2 (Router), sub-cycle **b**. Program doc: `docs/superpowers/specs/2026-06-27-ios-native-navigation-program-design.md`. Builds on N2a router core (`docs/superpowers/specs/2026-06-28-n2a-router-core-design.md`, shipped 258456e).
**Status:** Approved (design) → writing-plans → SDD.

## Goal

Make the N2a router *visible* on desktop: turn the kitchen-sink's flat section navigation into a real per-window history stack driven by `Window.current().router`, wire the N1 native toolbar back/forward buttons to `router.pop()`/`router.forward()` with their enabled-state bound to `canGoBack`/`canGoForward`, and fix the one N2a follow-up (M-c) that becomes load-bearing the moment UI binds to the cached getters. Also wire the program-decided `window.create`-on-iPhone → `router.push` fallback. macOS is the testable/shippable reference; iOS keeps compiling but gains no native routing (that is N3).

## Why router instead of events (the program bet)

On desktop, "in-window navigation" is not a first-class platform primitive — the OS gives a window + toolbar, and back/forward-through-history is a convention you wire yourself. So on desktop the router looks like "events with bookkeeping." The payoff is portability: the **same** `router.push("/detail")` maps to a logical stack + content-swap on desktop (N2b) and to a real `UINavigationController` (per-route view controller, own WKWebView, edge swipe-back, native push animation) on iPhone (N3). Because N2a made the stack **native-authoritative** (`routerstate.nim`) and per-entry (`url` + `params`), N3 can make the native nav controller the bidirectional driver — a swipe-back pops the native stack *and* the route stack in lockstep — without touching app code. N2b proves and stabilizes the contract (`push`/`pop`/`canGoBack`, `ROUTE_CHANGED`, params-per-entry) desktop-first; N3 swaps only the renderer.

## Architecture: one window, N panes, one stack

A kitchen-sink window is one NSWindow hosting several **separate WKWebViews** (panes): sidebar, content/main, optional inspector — same JS bundle branched by `location.hash` (`#sidebar-pane` vs default). They are isolated JS realms; they cannot call each other. All panes of a window share **one** native-authoritative route stack (`routerstate.nim`, keyed by the numeric window id) and report the **same** `Window.current().id` (proven by the existing `ks:nav` windowId-match working today).

Therefore navigation is **initiate → native → broadcast → render**, never direct call:

```
ANY initiator (sidebar click | toolbar back/fwd | worker push | future deep link)
        └─► Window.current().router.push/pop/forward      (t:4 router:*)
                 └─► native stack mutates (authoritative, per-window)
                        └─► ROUTE_CHANGED broadcast {windowId,url,params,canGoBack,canGoForward,kind}
                             ├─► main pane:    show(sectionIdFromUrl(url))
                             ├─► toolbar owner: updateItem back/fwd {enabled}
                             └─► sidebar pane:  .active = matching nav-item
```

The event is the only cross-pane channel. The data flow is identical regardless of initiator — one source of truth, N panes follow.

## §1 — Routing model & data flow

- **Route = section id.** Home (the N2a-seeded root) is `"/"`; every other registry section is `"/<id>"` (e.g. `/toolbar`, `/sidebar`, `/workers`). The native stack is already seeded with `/` at window-create, so Home needs no push at launch — it *is* the root.
- **URL ⇄ section mapping** — pure helpers in a new shared module `kitchen-sink/src/shell/route-map.ts` (both sidebar-pane and main-pane import it; it must NOT live in `main-pane.ts`, whose import has toolbar-attach side effects): `routeForSection(id) = id === "home" ? "/" : "/" + id`; `sectionForRoute(url) = url === "/" || url === "" ? "home" : url.replace(/^\//, "")`.
- **Sidebar (initiator):** clicking a nav-item calls `Window.current().router.push(routeForSection(id))` instead of `Events.emit("ks:nav", …)`. Uniform `push` (browser-style: every click is a history entry, including re-clicking Home → `push("/")`).
- **Main pane (renderer):** drops the `ks:nav` listener; subscribes to `ROUTE_CHANGED` (the handle's `router.on(...)`, already windowId-filtered) → `show(sectionForRoute(e.url))`. First render reads `Window.current().router.url` (falls back to `"home"` when `""`/`"/"`) so a reload/restore lands on the right section.
- **Toolbar owner (main pane):** the main pane owns the toolbar (`setItems(shellToolbar())`). On `ROUTE_CHANGED` it calls `Window.current().toolbar.updateItem("back", { enabled: e.canGoBack })` and `updateItem("fwd", { enabled: e.canGoForward })`. It also applies the initial enabled-state once after attach (reading `router.canGoBack/canGoForward`).
- **Sidebar highlight:** the sidebar pane subscribes to `ROUTE_CHANGED` → toggles `.active` on the nav-item whose id equals `sectionForRoute(e.url)` (so back/forward move the highlight — addresses #666 for this path).
- **Toolbar buttons (initiators):** the existing `back`/`fwd` chevron actions call `Window.current().router.pop()` / `.forward()` instead of emitting dead `ks:toolbar` events. To be addressable by `updateItem` they move from the center `nav` **group** to **top-level leading items** (`placement` leading; group sub-items aren't in `buttonsById`, so `updateItem` can't reach them). `back` starts `enabled: false`; `fwd` starts `enabled: false` (corrected from the current static `fwd`-enabled demo).

## §2 — M-c fix (seed vs ROUTE_CHANGED race) + fold M-a

`createRouterHandle` (`runtime/window.ts`) caches `{url,params,canGoBack,canGoForward}` from two sources: the synchronous `ROUTE_CHANGED` subscription and an async best-effort `__router:state` seed (`invoke`) fired at handle creation. Race: a `push` landing between handle creation and the seed resolving lets the event update the cache, then the stale seed snapshot clobbers it. Invisible in N2a (nothing read the cache); load-bearing in N2b (toolbar enabled-state binds to the getters).

**Fix:** give each window's cache record a monotonic `version: number`. Every `ROUTE_CHANGED` write increments `version`. The seed's `.then()` captures `version` at fire-time and **writes only if the record's version is unchanged** (no event arrived meanwhile). **Fold M-a (#757):** gate the seed `invoke` behind the existing `routerWired`-style guard so it fires once per window, not on every `createWindowHandle`/`Window.get`. Net: cache is always last-writer-correct; repeated `Window.get` is cheap.

## §3 — `window.create`-on-iPhone fallback

`Window.create(opts)` on iOS without `asSheetOf` currently warns and returns the current window. Refine the **non-sheet** branch:

- `opts.url` present → `Window.current().router.push({ url: opts.url, title: opts.title, presentation: opts.presentation })`, then return the current window handle. The warn message says it became an in-window route. (`WindowOptions` already carries `url?`, `title?`, `presentation?`; `params` has no `WindowOptions` source so it is omitted on this path.)
- `opts.url` absent → unchanged (warn + return current).
- macOS/desktop multi-window create is untouched.

Logical push on a single iPhone webview works today (stack + `ROUTE_CHANGED` + content-swap are cross-platform; only the native UINavigationController is N3). Validated by **unit test + iOS-compile**, not an in-session iPhone smoke. No kitchen-sink iPhone demo here (waits for N3).

## §4 — Scope, components, testing, decomposition

**No native/Nim change.** Entirely runtime + kitchen-sink + docs. Toolbar enabled-binding reuses the existing `updateItem({enabled})` path (top-level action items, AppKit auto-validation source-of-truth). iOS still compiles (shared runtime); no native routing added.

**Files touched:**
- `runtime/window.ts` — `createRouterHandle` (version-stamp + once-per-window seed); `Window.create` iOS non-sheet branch (url→router.push fallback).
- `runtime/router.test.ts` — new cases (below).
- `kitchen-sink/src/shell/toolbar-def.ts` — back/fwd → top-level leading items wired to `router.pop/forward`; remove dead `ks:toolbar` nav emits.
- `kitchen-sink/src/shell/sidebar-pane.ts` — push on click + `.active` on `ROUTE_CHANGED`.
- `kitchen-sink/src/shell/route-map.ts` — NEW shared module: pure `routeForSection`/`sectionForRoute` helpers, imported by both panes.
- `kitchen-sink/src/shell/main-pane.ts` — render on `ROUTE_CHANGED` (drop `ks:nav`); toolbar enabled-sync; first render from `router.url`.
- `docs/api-reference.md` — desktop in-window nav section (router drives content + toolbar back/forward pattern) + the iPhone-create-fallback note.

**Testing:**
- **T1 (TDD, `runtime/router.test.ts`):** (a) seed `__router:state` does NOT clobber a `ROUTE_CHANGED` that arrived first (version guard); (b) seed `invoke` fires once per window across repeated `createWindowHandle`/`Window.get` (routerWired gate); (c) on mocked iOS (bootstrapConfig os=ios/formFactor=phone), `Window.create({url:"/d", title:"D"})` posts `{t:4, m:"router:push", a:{windowId, url:"/d"}}` and returns the current window; with no `url` it does not push.
- **T2:** macOS HUMAN SMOKE — navigate sections (sidebar clicks) → content swaps + history accrues; toolbar **back/forward** traverse the history and **disable at the ends**; sidebar `.active` highlight follows back/forward; reload restores the current route. iOS compile stays green.
- Gates each task: `bun run check`; `bun test cli/src`; `bun run test:native`; `bun test runtime/router.test.ts` (T1); macOS build (`cd kitchen-sink && bun run build` → `[zapp] build complete:`); iOS compile (`… build --platform ios` → `[zapp] build complete:`).

**Decomposition (each = SDD task, independently testable):**
- **T1 — framework (runtime, TDD):** M-c version-stamp + fold M-a; `window.create`-iPhone url→push fallback; router.test cases. No native change.
- **T2 — kitchen-sink conversion + docs + macOS smoke:** toolbar-def back/fwd top-level + router-wired; sidebar push + highlight; main-pane render-on-ROUTE_CHANGED + enabled-sync + first-render-from-url; drop `ks:nav`; docs; macOS human smoke.

## Decisions (confirmed)

1. **Full conversion** (Option A): the whole kitchen-sink becomes router-driven; no separate throwaway demo section.
2. **Route = section id**, Home = `/`, uniform `push` (browser-style history, duplicate-root allowed).
3. **back/fwd are top-level leading items** (not a center group) so `updateItem({enabled})` can reach them. No native change to support sub-item updates in this cycle.
4. **Sidebar highlight follows the route** (addresses #666 for this path).
5. **iPhone `create` fallback** = url→`router.push`; code + unit test + iOS-compile only (no in-session iPhone smoke, no demo).
6. **No native/Nim change**; macOS-shippable.

## Out of scope / deferred

- iOS native routing (N3 — UINavigationController per-route VCs + swipe-back); per-route webviews.
- M-b map-pruning (#758) — stays a follow-up.
- Extending `updateItem` to address group sub-items (not needed once back/fwd are top-level).
- Worker `Platform` os/env (N2c).
- A dedicated "Navigation" demo section; an iPhone create-fallback demo.

## Risks

1. **back/fwd as group sub-items can't be `updateItem`-toggled** → mitigated by moving them to top-level leading items (§1, decision 3). Verified in the T2 smoke (buttons disable at the ends).
2. **M-c race** silently desyncs the toolbar enabled-state → fixed in T1 (version-stamp) with a unit test that reproduces the clobber.
3. **First-render route restore** must read `router.url` (not assume Home) so reload lands correctly — covered by §1 + the T2 smoke (reload restores route).

## Constraints

Branch `feat/ios-native-nav` (commit directly), UNMERGED; commit trailer EXACTLY `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; per-file `git add`; Bun; native-first parity (here the wire already exists from N2a — N2b is the TS/app consumer + docs); macOS is the testable reference; iOS must keep compiling; NO iOS simulator interaction in-session; NO git worktree, NO `git commit --amend`, NO merge. Gates: `bun run check`, `bun test cli/src`, `bun run test:native`, macOS build, iOS compile.
