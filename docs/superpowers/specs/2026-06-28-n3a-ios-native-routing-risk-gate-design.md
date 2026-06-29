# N3a — iOS Native Routing RISK GATE — Design

**Date:** 2026-06-28
**Branch:** `feat/ios-native-nav` (commit directly; UNMERGED)
**Program:** iOS Native Navigation, cycle **N3** (iOS native routing — the differentiator), sub-cycle **a** (the RISK GATE). Program doc: `docs/superpowers/specs/2026-06-27-ios-native-navigation-program-design.md` (§"Efficiency model", §N3). N0/N1/N2 (N2a router core + N2b desktop nav + N2c worker Platform) all SHIPPED.
**Status:** Approved (design) → writing-plans → SDD.

## Goal

Prove the **core iOS native-routing mechanism** on the simulator, end-to-end but minimal: `Window.current().router.push("/detail")` on an opted-in iPhone window materializes a **new unconstrained view controller hosting its own WKWebView**, pushed onto the existing `contentNav` (native slide-in); the **native back button AND edge swipe-back** pop it and stay in lockstep with the native-authoritative `routerstate.nim` stack; `ROUTE_CHANGED` stays coherent; the headless worker keeps running (shared state across routes); webview boot cost is measured. This is the program's #1 risk. If it holds, N3b (durable `ZappIOSNavContext` + cache/restore) and N3c (per-route chrome) productionize it.

## Why a risk gate (the unknowns being proven)

1. **WKWebView push/boot per route** is viable + the cost is acceptable (mitigated long-term by the worker-shared-state model; measured here).
2. **A real push needs a new unconstrained VC** — `contentVC` is permanently AutoLayout-constrained by sidebar.m/inspector.m (program risk #2); pushing a fresh VC must work.
3. **Bidirectional sync without a feedback loop** — programmatic push/pop and user swipe/back must converge on one source of truth (`routerstate`).
4. **Two iOS gotchas:** swipe-back is disabled when `navigationBarHidden=YES`; per-route webview teardown must not crash (brk-1).

## Architecture: reconcile-to-match, `routerstate` is the single source of truth

```
router.push("/detail")  (TS → t:4 → Nim)
  └─ routerstate push + emitRouteChanged (ROUTE_CHANGED broadcast)   [today, N2a]
      └─ when defined(zappIos): zapp_ios_router_sync(windowId)        [NEW]
           └─ reconcile contentNav VC stack to routerstate depth:
              native short by 1 → mint route WKWebView + new plain VC
                                  (zapp.route=/detail, host windowId)
                                  contentNav.pushViewController:animated:
              native long  by 1 → contentNav.popViewControllerAnimated: + teardown webview

[user edge-swipe / ‹ Back]
  └─ contentNav pops the VC  →  UINavigationControllerDelegate didShowViewController:
       sees native depth < routerstate depth (user-initiated)
       └─ zapp_router_pop_from_native(windowId)   [NEW Nim entry]
            └─ routerPop + emitRouteChanged + zapp_ios_router_sync
                 └─ native already matches routerstate → NO-OP   (loop broken)
```

`zapp_ios_router_sync` is **idempotent** — it makes native match `routerstate`, so re-entrancy converges. The delegate only calls back into Nim when native is *shorter* than `routerstate` (a user-initiated pop not yet reflected).

## §1 — Opt-in + isolation (keep the gate clean)

- **Opt-in, minimal:** a window-level `nativeRouting?: boolean` (TS `WindowOptions`, default false) threaded to native as a per-window bool the iOS sync reads. iOS-only effect; macOS ignores it. This is the seed of the real `presentation: "route"` / per-nav-context opt-in API (**N3b**).
- **Isolated demo:** the kitchen-sink gate adds a **dedicated** "Push native route" button + a tiny `/detail` route page — it does NOT convert the existing 21-section sidebar nav to native push (that section-nav→native-push UX mapping is an N3b/N3c decision). Minimal, uncoupled proof.
- **macOS untouched:** every native-push path is `when defined(zappIos)`-gated and lives in iOS `.m` files; the desktop router stays exactly N2b (logical stack + content-swap). Gate: macOS build green + the N2b desktop-nav behavior unchanged.

## §2 — The native push mechanism

- **Nim (`router.nim`):** after the existing `routerstate` mutation + `emitRouteChanged` in the `router:*` arms, add `when defined(zappIos): zapp_ios_router_sync(windowId.int32)` (a new `importc`).
- **Nim (`routerstate.nim`):** expose small read accessors the iOS side `importc`s — `routerDepth(win): cint` (entry count) and `routerCurrentUrl(win): cstring` (top entry url). (`routerCurrentParams` optional; params injection is N3b polish.)
- **iOS (`zapp_ios_router_sync(windowId)`):** resolve `contentNav` via `zapp_ios_content_nav_for_window`. If the window isn't `nativeRouting` or has no `contentNav` → no-op. Compare `contentNav` route-VC count to `routerDepth`-1 (root excluded) and reconcile by ±1:
  - **push:** mint a WKWebView through the existing iOS create path (route pane role, host `windowId` so `darwin_window_id_for_webview` maps it for the bridge + `ROUTE_CHANGED`); wrap it in a **new plain `UIViewController`** whose `view` hosts the webview pinned to its own edges (NOT `contentVC`); inject `globalThis[Symbol.for("zapp.route")] = "<url>"` via a document-start `WKUserScript` so the app renders that route on boot; `contentNav.pushViewController:animated:YES`.
  - **pop:** `contentNav.popViewControllerAnimated:YES`, then tear down the popped route webview.
- **Route webview content:** loads the same SPA bundle (asset scheme) + reads `zapp.route` to render its route immediately, and receives `ROUTE_CHANGED` like any pane. For the gate's `/detail`, the app renders a simple "Detail (/detail) — swipe or Back to return" page.

## §3 — Bidirectional sync + the two gotchas

- **Loop-break:** a `UINavigationControllerDelegate` on `contentNav`; `navigationController:didShowViewController:` compares native route-VC depth to `routerDepth` — if native < routerstate, call `zapp_router_pop_from_native(windowId)` (new Nim `exportc`: `routerPop` + `emitRouteChanged` + `zapp_ios_router_sync`, which no-ops). (If `contentNav` already has a delegate from N1's toolbar, compose — don't clobber it.)
- **Swipe-back with a hidden nav bar:** re-enable `contentNav.interactivePopGestureRecognizer` (set `.enabled = YES` and provide a `UIGestureRecognizerDelegate` returning YES for `gestureRecognizerShouldBegin:` only when there's a VC to pop) — the default gesture is disabled while `navigationBarHidden=YES`.
- **Teardown (brk-1 safety):** on pop, the route webview gets the `reference_wkwebview_teardown` recipe — `stopLoading`, nil the navigation/UI delegates, and `removeScriptMessageHandler` for the bridge handler — before the VC deallocs.

## §4 — Scope, components, testing, decomposition

**Files (expected):**
- `runtime/window.ts` — `nativeRouting?: boolean` on `WindowOptions` (passthrough).
- `native/nim/window.nim` (+ the window-config apply path) — thread `nativeRouting` to a per-window native bool.
- `native/nim/routerstate.nim` — `routerDepth` / `routerCurrentUrl` `*`-exported + `{.exportc.}` for iOS importc; `native/nim/router.nim` — the `when defined(zappIos)` `zapp_ios_router_sync` call + `zapp_router_pop_from_native` exportc.
- A new iOS source (e.g. `native/platform/ios/routing.m`) — `zapp_ios_router_sync`, the route VC/webview mint, the nav delegate + swipe-enable + teardown; reuses `zapp_ios_content_nav_for_window` + the `create_ext` webview path.
- `kitchen-sink/zapp.config.ts` / `app.nim` (set `nativeRouting`) + `kitchen-sink/src/...` (the isolated `/detail` demo button + page) + a boot-cost log.
- `docs/api-reference.md` — a short "iOS native routing (preview)" note.

**Testing & gates:** native (ObjC) has no unit harness → correctness via build gates + the human iOS-sim smoke. Nim accessors (`routerDepth`/`routerCurrentUrl`) get a `routerstate` unit-test case. TS: `nativeRouting` passthrough (a normalize/passthrough test if there's a natural site). Gates each task: `bun run check`; `bun test cli/src`; `bun run test:native`; macOS build (`cd kitchen-sink && bun run build` → `[zapp] build complete:`, **N2b desktop nav must still behave**); iOS compile (`… build --platform ios` → `[zapp] build complete:`). New iOS importc symbols satisfy `reference_ios_symbol_parity_gate` (they're `.m`-defined + iOS-built).

**Human iOS-sim SMOKE (you run it; NO in-session sim):** on iPhone sim — tap "Push native route" → a new VC **slides in** rendering the `/detail` page over the root; **native back button** pops it (slide-out) → root restored; **edge swipe-back** also pops it; `ROUTE_CHANGED` fires with correct url/canGoBack on each (verify via an on-screen/console readout); push ~2 deep then pop-from-middle; the headless worker keeps logging across pushes (shared state alive); no crash / no bridge-kill / no double-render loop; the boot-cost log shows the per-route webview time.

**Decomposition (~2 SDD tasks):**
- **T1 — RISK-GATE core (native + Nim):** `nativeRouting` flag thread; `routerstate` accessors + test; `router.nim` iOS hook + `zapp_router_pop_from_native`; the iOS `routing.m` (push/sync/delegate/loop-break/route-webview/swipe-enable/teardown). Gates: check / cli / test:native / macOS build / iOS compile.
- **T2 — kitchen-sink isolated demo + docs + human iOS-sim smoke:** `nativeRouting` on, the `/detail` button + page, cost log, api-reference note. Full gates + the iOS-sim human smoke.

## Decisions (confirmed)

1. **Risk-gate scope = core mechanism, end-to-end but minimal** (real `router.push` → native VC + webview + back + swipe + sync + worker-alive + cost; ~2-deep). Hardcoded-trigger-only and fold-in-the-cache were both rejected.
2. **`routerstate` is the single source of truth; reconcile-to-match** sync (idempotent) breaks the push/pop ↔ swipe/back loop.
3. **New unconstrained VC per route** (never reuse `contentVC`); per-route webviews load the shared bundle + `zapp.route`.
4. **Minimal `nativeRouting` window flag** for the gate (real `presentation:"route"` API = N3b); **isolated `/detail` demo** (no section-nav conversion).
5. **macOS untouched** (`when defined(zappIos)`); N2b behavior must not regress.

## Out of scope / deferred (TRACKED)

- **Lazy/bounded per-route webview cache (keep last K) + scroll/state restore on back** → **N3b, task #770.**
- Real opt-in API (`presentation:"route"` / per-nav-context) + the section-nav→native-push UX mapping → N3b.
- Per-route title/toolbar chrome rebind on push/pop → N3c.
- iPad behavior (nav inside the split content column / size-class) → N3c.
- `params` injection into the pushed route webview (beyond url) → N3b polish.

## Risks

1. **Swipe-back disabled under hidden nav bar** → §3 re-enables `interactivePopGestureRecognizer` with a gesture delegate; the smoke confirms swipe works.
2. **Per-route webview teardown crash (brk-1)** → §3 applies the `reference_wkwebview_teardown` recipe on pop.
3. **Delegate collision with N1's toolbar** (N1 may already set a `contentNav` delegate) → compose/chain, don't clobber; verify toolbar still works on a routed VC in the smoke.
4. **Sync re-entrancy / loop** → idempotent reconcile-to-match + the delegate-only-calls-on-shorter rule; the smoke (rapid push/pop + swipe) confirms no loop.

## Constraints

Branch `feat/ios-native-nav` (commit directly), UNMERGED; commit trailer EXACTLY `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; per-file `git add`; Bun; native-first parity (TS `WindowOptions` ↔ Nim window/routerstate/router ↔ iOS `routing.m`; Nim faithful to the wire; `feedback_nim_zc_parity`; `reference_ios_symbol_parity_gate` for new symbols); macOS is the reference and MUST NOT regress (iOS-only, gated); iOS arm64 / min 15.0, sim functional / device compile-only; NO iOS simulator interaction in-session (build gates + human sim smoke run by the user); default iOS engine zjs; NO git worktree, NO `git commit --amend`, NO merge. Gates: `bun run check`, `bun test cli/src`, `bun run test:native`, macOS build, iOS compile (+ the human iOS-sim smoke at T2).
