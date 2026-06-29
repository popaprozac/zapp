# iOS Native Routing Rebuild — Idiomatic `UISplitViewController` — Design

**Date:** 2026-06-29
**Branch:** `feat/ios-native-nav` (commit directly; UNMERGED)
**Program:** iOS Native Navigation, cycle **N3** (iOS native routing — the differentiator). **Supersedes** the N3a per-route-VC-on-the-split approach AND the R1 owned-nav (sidebar-first) approach. Program doc: `docs/superpowers/specs/2026-06-27-ios-native-navigation-program-design.md`.
**Status:** Approved (architecture + R1′ risk gate) → writing-plans → SDD. **This spec covers the ARCHITECTURE + the FIRST sub-cycle (R1′).** R2′/R3′ get their own specs.

## Background — why a rebuild (the spike verdict)

Two prior architectures hit the **same chrome-bug family** on iPhone AND iPad: N3a (per-route VC on the `UISplitViewController`) hit the collapse-combine wall; R1 (app-owned `UINavigationController`, sidebar-first) eliminated the wall but reintroduced lost swipe-back, double/stale toolbar items, and a transient back button — the identical bugs iPad #771 already had. When the same class of bug survives an architecture change, the bug is not in the architecture — it is in **Zapp hand-managing what UIKit wants to own**.

A clean-room ObjC/UIKit spike (`spikes/ios-splitview-reference/`, FINDINGS = GO, commits `aaa155b`→`ee26364`) proved the alternative on both idioms, portrait + landscape, with **zero custom navigation or inset code**:
- **Phase 1 (plain VCs):** idiomatic `UISplitViewController` + `pushViewController:` gives sidebar-first collapse (`topColumnForCollapsingToProposedTopColumn: → Primary`), native back button, interactive edge-swipe-back, correct per-VC toolbar (`navigationItem` items swapped to the top VC automatically — no duplication/stale), adaptive tile/overlay.
- **Phase 2 (WKWebView VCs):** a full-bleed WKWebView pinned to the VC's edges receives correct `env(safe-area-inset-*)` automatically — iPhone `inset-top` = 116px (status bar + nav bar), iPad reports the sidebar width as `inset-left` (330px overlay / 62px tile). The native inset-injection layer is unnecessary on iOS.

**Verdict:** rebuild Zapp's iOS routing to drive `UISplitViewController` idiomatically, and DELETE the manual machinery (reconcile loop, `didShow` toolbar-reapply, pop-detection delegate, iOS inset injection) + the R1 owned-nav fork. One rewrite fixes iPhone + iPad #771.

## Survey finding that shapes the rebuild

The split **chrome is already idiomatic for every iOS sidebar window** — iPad AND non-`nativeRouting` iPhone both build a `UISplitViewController` the spike-correct way (`window.m:409–525`, `sidebar.m:135–158`, correct WWDC20 ordering). `nativeRouting` does NOT change the chrome; it only switches on the broken `routing.m` reconcile loop on top of it. So the rebuild is **not** "build a new chrome" — it is "delete the machinery + the owned-nav fork, and drive the existing chrome with direct `pushViewController:`."

## §1 — Architecture: one idiomatic split, both idioms

On **all** iOS sidebar windows (iPhone and iPad), a single idiomatic `UISplitViewController`:
- `UISplitViewControllerStyleDoubleColumn`; sidebar VC = primary column, content VC = secondary; nav-wrapped columns; min/max/preferred column widths; `presentsWithGesture = YES`; `preferredSplitBehavior`/`preferredDisplayMode` applied after nav-wrapping (the existing `sidebar.m` does this correctly).
- A split delegate returns `UISplitViewControllerColumnPrimary` from `splitViewController:topColumnForCollapsingToProposedTopColumn:` → **sidebar-first on iPhone collapse** (the native master-detail pattern: sidebar is the root of the combined stack).
- **No iPhone/iPad fork.** The R1 owned-nav chrome (`iphonenav.m`) is deleted; iPhone falls through to the same `UISplitViewController` path.

UIKit owns: the collapse/expand, the back button, the interactive edge-swipe-pop, the per-VC toolbar swap, and adaptive tile/overlay (by size class). Routing is a thin seam on top — never a reconcile loop.

## §2 — The JS ↔ native-VC seam (the heart of the rebuild)

**Source of truth (unchanged):** Nim `gRoutes` (`routerstate.nim`) is authoritative; the native VC stack is derived; the JS `routerState` Map (`runtime/window.ts`) is a client cache kept current by `window:route-changed`.

**Push (`router.push` / drill-down):**
1. `router.push` → `windowAction("router:push", …)` → Nim `routeWindowAction` `router:push` arm → `routerPush` + `emitRouteChanged("push")`.
2. The current `when defined(zappIos): zapp_ios_router_sync(target)` call (`router.nim:715`) is **replaced** by `zapp_ios_push_route_vc(windowId, url, opts)`.
3. `zapp_ios_push_route_vc` resolves the nav controller **live from the content VC**: `contentVC.navigationController` — the *combined collapsed nav* on iPhone, the *secondary-column contentNav* on iPad. UIKit keeps this correct across collapse/expand. **This is the decisive difference from N3a**, which pushed onto the orphaned `contentNav` (causing UIKit to reflect/nest it → the wall). It then mints a route VC + its WKWebView (full-bleed, `zapp.route` identity via the existing `zapp_ios_set_pending_route_url` + document-start injection), sets its `navigationItem` from `opts`, and `[nav pushViewController:routeVC animated:YES]`.

**Pop (user back button / edge-swipe / programmatic):**
- ONE clean `UINavigationControllerDelegate` per content nav. Its `didShowViewController:` detects a user-initiated pop (native depth dropped below routerstate depth) and calls **`zapp_router_pop_from_native(windowId)`** (already exists, exportc) → `routerPop` + `emitRouteChanged("pop")`. A programmatic `router.pop` pops the VC; the same `didShow` fires but depths already match → no loop. **No want/have reconcile, no `pushedVCs` registry, no self-healing delegate chain.**

**Lateral nav (section switch in the sidebar):** `popToRootViewControllerAnimated:NO` on the content nav, then swap the content (Zapp's existing iOS `popToRoot` + `replace` in `sidebar-pane.ts`), then reveal the content column (`showColumn:Secondary` on collapsed iPhone).

**Teardown:** each route VC tears down its own webview in `viewDidDisappear:` when it is being removed from the nav (the brk-1 recipe: `stopLoading` + nil delegates + `removeScriptMessageHandlerForName:@"zapp"`). No external teardown bookkeeping.

**Event fan-out (preserve):** `emitRouteChanged` → `dispatch_event_to_all` broadcasts `window:route-changed` to all pane webviews (content + sidebar + inspector). The sidebar pane uses it to sync its active-item highlight; route-VC webviews ignore it via the `myRoute` (`zapp.route`) guard in `main-pane.ts`. This contract is preserved for every new route VC webview.

## §3 — Per-view chrome API (default ON, opt-out)

The nav bar carries two separable things: its **presence** (which provides the free native back button on drill-down + the iPhone sidebar-toggle) and its **content** (title + items). Content is opt-in either way; presence defaults ON.

- **Default:** every route's nav bar is present, empty until populated.
- **Push options:** `router.push("/x", { toolbar?: false, title?: string })`.
  - `toolbar: false` → `setNavigationBarHidden:YES` on that route's VC, **and re-arm `interactivePopGestureRecognizer`** (hiding the bar otherwise disables edge-swipe-back) so swipe still works on a chromeless view. The view is then truly edge-to-edge (`env(safe-area-inset-top)` shrinks to the status bar). Known at push time → **no flash**.
  - `title` → the pushed VC's `navigationItem.title` (immediate, no flash).
- **Runtime (view-owned, dynamic):** the existing `Window.current().toolbar.setItems(...)` plus a new **`toolbar.setTitle(...)`**, applied to the top VC's `navigationItem`. UIKit shows the right items for the top VC automatically — no reapply.

Cross-platform shape: "no chrome / full-bleed" reads the same conceptually as macOS `titleBarStyle: hidden` (this rebuild is iOS-scoped; the API is named to stay cross-platform-friendly).

## §4 — Insets, flag retirement, cleanup

**Insets (iOS only):** delete `zapp_ios_toolbar_inject_webview_safe_area` and the route-VC injection path. A route's full-bleed WKWebView gets `env(safe-area-inset-*)` for free (spike Phase 2: includes the nav bar). Keep the cross-platform `--zapp-*` var contract by defining the iOS vars **from `env()`** in a one-time CSS snippet (`:root { --zapp-safe-area-top: env(safe-area-inset-top); … }`), rather than computing + injecting natively per layout. Insets are **dev-driven**: pad with the vars to respect chrome, or ignore them for truly edge-to-edge. **macOS `--zapp-*` injection (`darwin/toolbar.m`, `darwin/webview.m`) is UNTOUCHED** — macOS has no reliable `env()` equivalent (insets come from NSToolbar/titlebar/NSSplitView metrics); the rebuild is iOS-scoped.

**Flag:** `nativeRouting` is **retired as an architecture switch**. On an iOS sidebar window, `router.push` is simply a native push; apps that want pure in-webview routing use client-side history and never call `router.push`. (Concrete retirement steps — remove the gate vs keep a deprecated no-op field — are an R3′ implementation detail.)

**Single-pane iOS window (no sidebar):** wrap its root VC in a `UINavigationController` so `router.push` performs the same idiomatic push there; fall back to in-window content-swap only when there is genuinely no nav host.

**Delete:** all of `routing.m` (`zapp_ios_router_sync` + `ZappRouteVC` + `ZappRoutingNavDelegate` + `zapp_routing_nav` + teardown); all of `iphonenav.m`; the `toolbar.m` reapply machinery (`zapp_ios_toolbar_reapply_for_window` + `_hidden` + `ZappIOSToolbarNavDelegate`) + `zapp_ios_toolbar_inject_webview_safe_area`. **#771 closes** in the same rewrite (iPad-expanded routing parity falls out of the converged idiomatic path).

**Keep (unchanged):** the split chrome construction, `sidebar.m`, `inspector.m` (iPad-pane / iPhone-sheet), Nim `gRoutes` + `zapp_router_pop_from_native` + `emitRouteChanged`, the runtime `RouterHandle`, the kitchen-sink `main-pane.ts` per-route identity + `sidebar-pane.ts` lateral nav.

## §5 — Decomposition (3 sub-cycles; risk-gate first)

- **R1′ — RISK GATE (this spec's first plan):** delete the owned-nav fork (`iphonenav.m` + the `window.m` ownedNav branch) and the `routing.m` reconcile loop; wire the §2 seam — `zapp_ios_push_route_vc` (live `contentVC.navigationController` push) + a single clean `UINavigationControllerDelegate.didShow` → `zapp_router_pop_from_native`; route VCs set their own `navigationItem`; route-VC webview self-teardown. Converge iPhone + iPad on the one `UISplitViewController`. **Ends in a human iOS-sim smoke on BOTH idioms:** start on sidebar → select section pushes content → `router.push("/detail")` native push → back-button + edge-swipe pop → toolbar follows the top VC → no sticky route / no duplicate inspectable webview / route webviews tear down on pop / worker keeps logging. Proves the new seam end-to-end. If it holds, the rest is parity + cleanup.
- **R2′ — chrome parity:** the §3 per-view chrome API (`{toolbar,title}` push-options + `toolbar.setTitle` + `setNavigationBarHidden:` + swipe re-arm), lateral-nav `popToRoot` semantics, pane-event fan-out parity, kitchen-sink demo (an edge-to-edge opt-out route + a titled route). Own spec/plan. Human smoke.
- **R3′ — insets + flag retirement + cleanup:** §4 `--zapp-*`-from-`env()` (iOS), delete the iOS inset injection, retire `nativeRouting`, single-pane window handling, final delete of dead machinery, docs refresh, **close #771**, final cross-impl review + `finishing-a-development-branch` for the whole `feat/ios-native-nav` branch. Own spec/plan.

## §6 — Risks

1. **Live-nav resolution across collapse/expand** — `contentVC.navigationController` must resolve to the right nav in every state (collapsed iPhone = combined nav; expanded iPad = contentNav; rotation/size-class change). The spike proved `[contentVC.navigationController pushViewController:]` works both idioms; R1′ confirms on the real chrome. Mitigated by R1′ being the risk gate.
2. **Single delegate per content nav** — today the routing + toolbar delegates chain and race. The rebuild has ONE `UINavigationControllerDelegate` per content nav; any residual bar-show/hide logic (e.g. hide bar on the sidebar root) folds into it. Ownership clarity is a known subtle area.
3. **Inset-var migration** — switching iOS `--zapp-*` from native injection to `env()`-backed CSS must not change layout for apps relying on the vars; verify the values match (R3′). macOS untouched, so no cross-platform regression.
4. **`nativeRouting` retirement** — dropping/repurposing a shipped flag is mildly breaking; R3′ decides remove-vs-deprecate. The kitchen-sink + templates are updated in the same cycle.

## §7 — Out of scope / deferred (tracked)

- Per-route webview cache + scroll/state restore on back — N3b (#770).
- Large-iPhone-landscape (regular-width) side-by-side — UIKit's adaptive split handles it; verify in smoke.
- iPad-multitasking-compact-width edge cases — #718-adjacent.
- Route-registry chrome declaration (`routes: {…}` in config) — future convenience; v1 uses push-options + runtime.

## Constraints

Branch `feat/ios-native-nav` (commit directly), UNMERGED; commit trailer EXACTLY `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; per-file `git add`; Bun never Node; native-first parity (TS runtime ↔ Nim router/wire ↔ native ↔ docs in the same PR; `reference_ios_symbol_parity_gate` for new `zapp_ios_*` importc/exportc symbols); **macOS MUST NOT regress** (iOS-only / `when defined(zappIos)`/`TARGET_OS`-gated; macOS `--zapp-*` injection + the iPad split chrome are untouched); iOS arm64 / min 15.0, sim functional / device compile-only; **NO iOS simulator interaction in-session** (build gates + human sim smoke run by the user); default iOS engine zjs; NO git worktree, NO `git commit --amend`, NO merge. SDD pre-approved for the program. Gates: `bun run check`, `bun test cli/src`, `bun run test:native`, macOS build (`[zapp] build complete:`), iOS compile (`[zapp] build complete:`) — plus the human iOS-sim smoke at each sub-cycle.
