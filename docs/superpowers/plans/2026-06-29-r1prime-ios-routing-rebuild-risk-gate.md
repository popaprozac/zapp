# R1′ — iOS Routing Rebuild RISK GATE (idiomatic UISplitViewController) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace Zapp's iOS routing machinery with a thin idiomatic seam that drives the existing `UISplitViewController` directly (`pushViewController:` on the live content nav), and converge iPhone+iPad onto one chrome by deleting the R1 owned-nav fork — proving native push/back/swipe + per-VC toolbar on the real kitchen-sink, both idioms.

**Architecture:** The split chrome already exists for every iOS sidebar window. The rebuild deletes the reconcile loop (`routing.m`), the owned-nav fork (`iphonenav.m`), and the toolbar reapply machinery (`toolbar.m`), and replaces them with: a push seam that resolves **`contentVC.navigationController` LIVE** (the collapsed nav on iPhone / contentNav on iPad — UIKit keeps it correct; this is the fix vs N3a, which targeted the orphaned `contentNav`) and pushes a route VC; and ONE clean `UINavigationControllerDelegate` whose `didShow` reflects user pops into Nim. Nim `gRoutes` stays the source of truth.

**Tech Stack:** ObjC (iOS `routing.m`, `window.m`, `toolbar.m`, `webview.m`), Nim (`router.nim`, `routerstate.nim`, `window.nim`), TypeScript (`cli/src/native.ts`, kitchen-sink), Bun.

**Spec:** `docs/superpowers/specs/2026-06-29-ios-native-routing-rebuild-design.md` (§2 seam, §4 deletions, §5 R1′).

## Global Constraints

- Branch `feat/ios-native-nav` — commit directly. NO git worktree, NO `git commit --amend`, NO merge.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Per-file `git add` ONLY — never `-A`/`.`. Pre-existing unrelated WIP stays unstaged. Each task names exact files.
- Bun, never Node.
- Native-first parity; new `zapp_ios_*` importc/exportc symbols satisfy `reference_ios_symbol_parity_gate` (`.m`-defined + iOS-built).
- **macOS MUST NOT regress** — iOS-only / `when defined(zappIos)`/`TARGET_OS`-gated. **`native/platform/darwin/*` (the macOS toolbar + inset impl) and the iPad `UISplitViewController` split-construction path (`window.m:409–525`) MUST stay byte-for-byte unchanged.**
- iOS arm64 / min 15.0; sim functional / device compile-only; **NO iOS simulator interaction in-session** — build-only gates + the human 2-device sim smoke run by the user.
- **DEFERRED to R2′/R3′ — NOT in R1′:** per-view chrome push-option `{toolbar:false,title}` + `toolbar.setTitle` + `setNavigationBarHidden` + swipe-re-arm (R2′); `--zapp-*` from `env()` + delete `zapp_ios_toolbar_inject_webview_safe_area` + retire `nativeRouting` flag + single-pane-window handling (R3′). R1′ keeps the default bar shown, basic per-VC items, and the existing iOS inset injection working as-is.

Per-task gates: `bun run check`; `bun test cli/src`; `bun run test:native`; macOS build (`cd kitchen-sink && bun run build` → `[zapp] build complete:`, MUST stay green); iOS compile (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`). T3 ends in the **human 2-device iOS-sim smoke**.

## RISK-GATE note for implementers

T1 (the new seam) and T2 (delete the fork) are the genuinely-new work; they REUSE proven pieces, cited inline. The **mechanism is proven only at T3's human sim smoke** — T1/T2 gate on build-green + iOS-compile + macOS/iPad-split-unchanged. The genuine unknowns are: (a) **live-nav resolution** — `contentVC.navigationController` must resolve to the right nav in every state (collapsed iPhone = combined nav; expanded iPad = contentNav); (b) the **router-action→native-op mapping** (push/pop/popToRoot/replace → which nav op); (c) **single-delegate ownership** (one delegate per content nav, no chaining race); (d) **route-VC teardown timing** (`viewDidDisappear:` when actually removed). If any resists, **report DONE_WITH_CONCERNS** with exactly what you saw — that signal IS the point of a risk gate; do NOT force a hack silently.

**Reusable pieces (verbatim, keep/repurpose):**
- `ZappRouteVC` shell + `viewDidLayoutSubviews` inset-inject (`routing.m:58–70`).
- `zapp_route_vc_teardown` recipe (`routing.m:75–85`): `stopLoading` + nil `navigationDelegate`/`UIDelegate` + `removeScriptMessageHandlerForName:@"zapp"`.
- `zapp_ios_set_pending_route_url(const char*)` + `g_pending_route_url` (`webview.m:753–754`); the `zapp.route` document-start injection (`webview.m:859–869`) consumes it once.
- `darwin_webview_create_ext(window, inspectable, accept_first_mouse, url, numeric_id, transparent, container_view, identity_window_id, pane_role, host_has_sidebar, host_has_inspector)` — container-mount path (`webview.m:981–994`): pass `(__bridge void*)vc.view` as `container_view`, `windowId` as `identity_window_id`, `pane_role` 0; the webview lands as `vc.view.subviews.firstObject`.
- `zapp_ios_toolbar_apply_to_nav(nav, entry, includeToggleSidebar)` (`toolbar.m:523–540`) — stamps items onto `nav.topViewController.navigationItem`; reuse as the per-VC stamp.
- `zapp_ios_toolbar_inject_webview_safe_area(WKWebView*)` (`toolbar.m:202–221`) — keep (R1′ insets stay as-is; deleted in R3′).
- `zapp_window_native_routing(int32_t)` (`window.nim:27`) — the gate the seam still checks.
- Nim `emitRouteChanged` (`router.nim:169–193`), `zapp_router_pop_from_native` (`router.nim:195–201`, exportc) — KEEP.

**Owned-nav machinery to cut TOGETHER (T2):** `zapp_ios_owned_nav_enabled` (iphonenav.m:22; externs+calls window.m:328,384,512,587), `zapp_ios_register_owned_nav` (iphonenav.m:28; window.m:329,402), `zapp_ios_owned_nav_for_window` (iphonenav.m:37; routing.m + toolbar.m:90,562,965,1303), `zapp_ios_owned_content_vc_for_window` (iphonenav.m:42; routing.m), `ZappOwnedNavController`/`g_owned_navs` (iphonenav.m:12–19), `cli/src/native.ts:136`, `zapp_router_seed_empty` (routerstate.nim:21; only caller window.m:406).

---

## Task 1: New idiomatic routing seam (rewrite `routing.m`) + Nim arm mapping + set_items retarget

**Files:** Rewrite `native/platform/ios/routing.m`; Modify `native/nim/router.nim`, `native/platform/ios/toolbar.m` (set_items retarget only).

**Goal of T1:** `routing.m` becomes the minimal idiomatic seam, driving the LIVE content nav, deleting the reconcile loop + `ZappRoutingNavDelegate` + `zapp_routing_nav`. It stays **chrome-agnostic** (resolves the content VC as "owned-content-vc if the owned-nav chrome is present, else the split content-vc") so it works on BOTH the still-present owned-nav chrome (iPhone) and the split chrome (iPad) — T2 then deletes the owned-nav chrome and the fallback. **iphonenav.m + the window.m owned-nav branch are UNCHANGED in T1.**

**Interfaces produced (T2/router.nim consume):**
- `void zapp_ios_push_route_vc(int32_t windowId, const char* url)` — push a route VC onto the live content nav.
- `void zapp_ios_pop_route_vc(int32_t windowId)` — programmatic pop one VC.
- `void zapp_ios_pop_to_content(int32_t windowId)` — pop all route VCs back to the content VC (popToRoot).

- [ ] **Step 1 — Read the current `routing.m` in full** so you keep the reusable shells and delete the rest. Keep verbatim: the `ZappRouteVC` `@interface`/`@implementation` + `viewDidLayoutSubviews` (`:58–70`), `zapp_route_vc_teardown` (`:75–85`), and the externs you still need (`darwin_window_get_by_numeric_id`, `router_depth`, `router_current_url`, `zapp_router_pop_from_native`, `zapp_ios_set_pending_route_url`, `zapp_ios_toolbar_inject_webview_safe_area`, `darwin_webview_create_ext` via its header). DELETE: `zapp_ios_router_sync` (the want/have reconcile), `ZappRoutingNavDelegate` (`@interface`+`@implementation`, all methods), `zapp_routing_nav`, `g_routing_delegates`, and the owned-nav externs (`zapp_ios_owned_nav_for_window`, `zapp_ios_owned_content_vc_for_window`).

- [ ] **Step 2 — Resolve the live content nav.** Add a helper that returns the content VC's CURRENT navigation controller (the decisive fix vs N3a). The content VC is the persistent secondary-column pane VC; resolve it via the existing accessor (`zapp_ios_content_vc_for_window` from `sidebar.m`; if the owned-nav chrome is present, `zapp_ios_owned_content_vc_for_window`). **VERIFY `zapp_ios_content_vc_for_window` exists in sidebar.m; if it does NOT, add it** (sidebar.m registers the content VC when building the split — mirror the sidebar accessor registry). Report DONE_WITH_CONCERNS if the content VC can't be resolved on the split chrome.
  ```objc
  // The nav controller the content VC currently lives in — UIKit keeps this
  // correct across collapse/expand (collapsed combined nav on iPhone, contentNav
  // on iPad). This is what we push onto. (T2 removes the owned-nav fallback.)
  extern UIViewController* zapp_ios_content_vc_for_window(void* win);         // sidebar.m (verify/add)
  extern UIViewController* zapp_ios_owned_content_vc_for_window(void* win);   // iphonenav.m (deleted in T2)
  static UINavigationController* zapp_route_content_nav(void* win) {
      UIViewController* contentVC = zapp_ios_owned_content_vc_for_window(win); // nil unless owned-nav chrome
      if (!contentVC) contentVC = zapp_ios_content_vc_for_window(win);          // split chrome
      return contentVC.navigationController;   // LIVE nav — the fix vs N3a
  }
  ```

- [ ] **Step 3 — The single clean nav delegate.** ONE `UINavigationControllerDelegate` per content nav, installed once. `didShowViewController:` detects a user-initiated pop (native depth dropped below routerstate depth) and reflects it into Nim. No compose/prev-chain, no self-heal, no `pushedVCs` (route VCs self-tear-down). Distinguishing programmatic vs user pop is free: a programmatic `router.pop` mutates routerstate FIRST then pops the VC, so by `didShow` the depths match (no double); a user back/swipe pops the VC first, so `didShow` sees native < router → pop_from_native.
  ```objc
  @interface ZappRouteNavDelegate : NSObject <UINavigationControllerDelegate>
  @property (nonatomic, assign) int32_t windowId;
  @end
  @implementation ZappRouteNavDelegate
  - (void)navigationController:(UINavigationController*)nav
         didShowViewController:(UIViewController*)vc animated:(BOOL)animated {
      // routerDepth counts content+routes; native stack also holds the sidebar
      // root on collapsed iPhone, so compare deltas, not absolutes: if the user
      // popped (native shrank below what routerstate expects), reflect into Nim.
      int nativeRouteDepth = 0;
      for (UIViewController* v in nav.viewControllers)
          if ([v isKindOfClass:[ZappRouteVC class]]) nativeRouteDepth++;
      int wantRouteDepth = (int)router_depth(self.windowId) - 1;  // depth 1 = content (0 route VCs)
      if (wantRouteDepth < 0) wantRouteDepth = 0;
      if (nativeRouteDepth < wantRouteDepth) {
          zapp_router_pop_from_native(self.windowId);  // Nim pops + emits ROUTE_CHANGED
      }
  }
  @end
  static NSMutableDictionary<NSNumber*, ZappRouteNavDelegate*>* g_route_delegates;
  static void zapp_route_install_delegate(UINavigationController* nav, int32_t windowId) {
      if (!g_route_delegates) g_route_delegates = [NSMutableDictionary dictionary];
      ZappRouteNavDelegate* d = g_route_delegates[@(windowId)];
      if (!d) { d = [ZappRouteNavDelegate new]; d.windowId = windowId; g_route_delegates[@(windowId)] = d; }
      if (nav.delegate != d) nav.delegate = d;   // single owner; re-assert if UIKit reset it
  }
  ```
  Count route VCs by class (not absolute `nav.viewControllers.count`) so the sidebar root on collapsed iPhone doesn't skew the delta. **Report DONE_WITH_CONCERNS** if a single delegate fights an existing nav delegate (e.g. a toolbar delegate) or if the depth delta mis-fires on collapse/expand.

- [ ] **Step 4 — `ZappRouteVC` self-teardown.** Add `viewDidDisappear:` to `ZappRouteVC` so a popped route VC tears down its own webview (no external registry):
  ```objc
  - (void)viewDidDisappear:(BOOL)animated {
      [super viewDidDisappear:animated];
      if (self.isMovingFromParentViewController || self.isBeingDismissed) {
          zapp_route_vc_teardown(self);   // brk-1: stopLoading + nil delegates + remove "zapp" handler
      }
  }
  ```

- [ ] **Step 5 — The push seam.** `zapp_ios_push_route_vc` mints a route VC + webview and pushes onto the live nav (mirrors the old mint path, minus the reconcile):
  ```objc
  void zapp_ios_push_route_vc(int32_t windowId, const char* url) {
      if (!zapp_window_native_routing(windowId)) return;     // gate (kept; retired in R3')
      void* win = darwin_window_get_by_numeric_id(windowId);
      if (!win) return;
      UINavigationController* nav = zapp_route_content_nav(win);
      if (!nav) return;                                       // no nav yet → deferred
      zapp_route_install_delegate(nav, windowId);
      ZappRouteVC* vc = [[ZappRouteVC alloc] init];
      zapp_ios_set_pending_route_url(url);                    // route identity (consumed once, doc-start)
      darwin_webview_create_ext(win, /*inspectable*/true, /*first_mouse*/false, url, windowId,
                                /*transparent*/false, (__bridge void*)vc.view, windowId,
                                /*pane_role*/0, /*host_has_sidebar*/true, /*host_has_inspector*/false);
      vc.webview = (WKWebView*)vc.view.subviews.firstObject;
      // Per-VC toolbar items (idiomatic — UIKit shows them when this VC is top).
      // Reuse the existing per-window toolbar entry stamp; R2' adds per-view title/opt-out.
      zapp_ios_toolbar_apply_to_nav(nav, /*entry for this window*/NULL, /*includeToggleSidebar*/NO);
      [nav pushViewController:vc animated:YES];
  }
  ```
  Match the real `darwin_webview_create_ext` arg list + the real `inspectable`/`host_has_*` values the content pane uses (read `window.m:527–540`). For the toolbar stamp, use the real `zapp_ios_toolbar_apply_to_nav` signature + how the per-window toolbar entry is looked up (read `toolbar.m:523–540`); if items shouldn't be force-applied at push (the app sets them via `setItems`), it is fine to leave the route VC's `navigationItem` empty and let `setItems` target the top VC (Step 7) — **choose whichever the smoke shows correct and note it**.

- [ ] **Step 6 — Pop + popToRoot ops.**
  ```objc
  void zapp_ios_pop_route_vc(int32_t windowId) {           // programmatic router.pop
      void* win = darwin_window_get_by_numeric_id(windowId); if (!win) return;
      UINavigationController* nav = zapp_route_content_nav(win); if (!nav) return;
      if ([nav.topViewController isKindOfClass:[ZappRouteVC class]]) [nav popViewControllerAnimated:YES];
  }
  void zapp_ios_pop_to_content(int32_t windowId) {          // popToRoot / lateral reset → back to content VC
      void* win = darwin_window_get_by_numeric_id(windowId); if (!win) return;
      UIViewController* contentVC = zapp_ios_owned_content_vc_for_window(win);
      if (!contentVC) contentVC = zapp_ios_content_vc_for_window(win);
      UINavigationController* nav = contentVC.navigationController; if (!nav) return;
      if ([nav.viewControllers containsObject:contentVC]) [nav popToViewController:contentVC animated:NO];
  }
  ```

- [ ] **Step 7 — Retarget `setItems` + delete the reapply-on-didShow call.** In `toolbar.m`, `darwin_toolbar_set_items` (iOS path) must apply items to the **current top VC's `navigationItem`** of the live content nav (so app-set items land on whatever route/content VC is on top); the new `ZappRouteNavDelegate` does NOT reapply. Read `darwin_toolbar_set_items` (`toolbar.m`, ~`:562` area) and `zapp_ios_toolbar_apply_to_nav` (`:523–540`): change the nav resolution to `zapp_route_content_nav`-equivalent (live content nav) and apply to its `topViewController`. **Do NOT yet delete** `zapp_ios_toolbar_reapply_for_window`/`_hidden`/`ZappIOSToolbarNavDelegate` (T2 removes them once nothing calls them). Remove only the `zapp_ios_toolbar_reapply_for_window` call that lived in the now-deleted `ZappRoutingNavDelegate.didShow`.

- [ ] **Step 8 — Nim arm mapping.** In `native/nim/router.nim`, replace the iOS sync call(s) in the `router:*` arms (`~:698–715`) — `zapp_ios_router_sync(target)` — with the per-action ops. Add the importc decls (replacing the `zapp_ios_router_sync` importc at `~:29–30`):
  ```nim
  when defined(zappIos):
    proc zapp_ios_push_route_vc(windowId: int32, url: cstring) {.importc, cdecl.}
    proc zapp_ios_pop_route_vc(windowId: int32) {.importc, cdecl.}
    proc zapp_ios_pop_to_content(windowId: int32) {.importc, cdecl.}
  ```
  Map (read the exact arms first): `router:push` → `zapp_ios_push_route_vc(target, url.cstring)`; `router:pop` → `zapp_ios_pop_route_vc(target)`; `router:popToRoot` → `zapp_ios_pop_to_content(target)`; `router:replace` → on iOS the lateral section switch happens after a `popToRoot` (kitchen-sink `sidebar-pane.ts`), so `replace` at depth 1 is a content re-render with NO native nav change — call `zapp_ios_pop_to_content(target)` defensively (idempotent if already at content) and let the content webview re-render via `emitRouteChanged`. `zapp_router_pop_from_native` (`:195–201`) is UNCHANGED (the new delegate calls it; it pops routerstate + emits — it must NOT call any native op, else a loop). **Report DONE_WITH_CONCERNS** if the action→op mapping produces a double-pop or a stuck state in reasoning.

- [ ] **Step 9 — Gates.** `bun run check`; `bun test cli/src`; `bun run test:native`; macOS build (`[zapp] build complete:`); iOS compile (`[zapp] build complete:`). (T1 intermediate: iPhone still has the owned-nav chrome; the chrome-agnostic seam resolves its content VC via the owned fallback, so it functions on both idioms — but the converged behavior is smoked at T3. Build-green is the T1 gate.)

- [ ] **Step 10 — Commit.**
  ```bash
  git add native/platform/ios/routing.m native/nim/router.nim native/platform/ios/toolbar.m
  # + native/platform/ios/sidebar.m IF you added zapp_ios_content_vc_for_window
  git commit  # message + trailer
  ```
  Message: `feat(ios): idiomatic routing seam (live content-nav push) replacing the reconcile loop`

---

## Task 2: Delete the owned-nav fork + converge the chrome + delete the reapply machinery

**Files:** Delete `native/platform/ios/iphonenav.m`; Modify `cli/src/native.ts`, `native/platform/ios/window.m`, `native/platform/ios/toolbar.m`, `native/platform/ios/routing.m`, `native/nim/window.nim`, `native/nim/routerstate.nim`.

**Goal of T2:** remove the entire owned-nav machinery (cut-together list above) so iPhone falls through to the SAME `UISplitViewController` path as iPad (converged), and delete the now-dead toolbar reapply machinery. After T2 the seam's owned-content-vc fallback is gone (split content-vc only).

- [ ] **Step 1 — Remove `iphonenav.m` from the build + delete the file.** `cli/src/native.ts:136` — delete the `path.join(iosDir, "iphonenav.m"),` line. Then `git rm native/platform/ios/iphonenav.m`.

- [ ] **Step 2 — `window.m`: delete the owned-nav branch, converge to split.** Remove the `if (ownedNav) { … } else { … }` wrapper so the split-construction body runs unconditionally for `d->hasSidebar` (the EXISTING split path, `window.m:409–525`, stays byte-for-byte — just un-wrapped from the `else`). Delete: the `BOOL ownedNav = zapp_ios_owned_nav_enabled(...)` line + the entire owned-nav arm (`~385–408`, incl. `zapp_ios_register_owned_nav` + `zapp_router_seed_empty`); the externs `zapp_ios_owned_nav_enabled` / `zapp_ios_register_owned_nav` / `zapp_router_seed_empty` (`:328,329,332`); and re-gate the split-specific follow-up calls that were `if (... && !zapp_ios_owned_nav_enabled(...))` back to plain `if (d->hasSidebar)` (the `zapp_ios_sidebar_register` + `zapp_ios_sidebar_set_content_webview` guards at `~:512,587` — drop the `&& !zapp_ios_owned_nav_enabled(...)` clause). **The iPad split path body must read byte-identical to before (only the `else`-wrapper + the gate-clauses removed).**

- [ ] **Step 3 — `routing.m`: drop the owned-content-vc fallback.** In `zapp_route_content_nav` + `zapp_ios_pop_to_content`, remove the `zapp_ios_owned_content_vc_for_window` line + its extern — resolve only `zapp_ios_content_vc_for_window` now.

- [ ] **Step 4 — `toolbar.m`: remove the owned-nav references.** Delete the `zapp_ios_owned_nav_for_window` extern (`:90`) + the 4 use sites: the R1 short-circuit in `zapp_ios_toolbar_reapply_for_window_hidden` (`:965–969`), the owned-nav branch of the `darwin_toolbar_set_items` guard (`:562`), and the `ownedNavM` branch in `zapp_toolbar_inject_metrics` (`:1303`) — leaving the collapsed/expanded nav-selection paths intact.

- [ ] **Step 5 — Delete the dead toolbar reapply machinery.** Now that the new seam (T1) sets per-VC `navigationItem` and `setItems` targets the live top VC, delete `zapp_ios_toolbar_reapply_for_window`, `zapp_ios_toolbar_reapply_for_window_hidden`, and `ZappIOSToolbarNavDelegate` (`@interface`+`@implementation`). **First grep the iOS tree for any remaining caller** (`grep -rn zapp_ios_toolbar_reapply_for_window native/platform/ios`); if a non-deleted call site remains (e.g. a metrics-defer in `ZappIOSPaneViewController`), retarget or remove it. **Report DONE_WITH_CONCERNS** if a live caller can't be cleanly removed. KEEP `zapp_ios_toolbar_apply_to_nav` (the seam uses it) and `zapp_ios_toolbar_inject_webview_safe_area` (R1′ insets).

- [ ] **Step 6 — Remove `zapp_router_seed_empty`.** Its only caller was `window.m:406` (deleted Step 2). Delete the proc from `native/nim/routerstate.nim:21` + its test, if any. (`createWindow`'s normal `routerSeed(id, "/")` now governs — the converged split shows the sidebar + seeds depth-1 "/", no empty-seed trick needed.) Run the routerstate tests to confirm nothing references it.

- [ ] **Step 7 — Gates.** Full set. **macOS build MUST stay green; the iPad split path is byte-unchanged.** `grep -rn "owned_nav\|iphonenav\|seed_empty\|ZappRoutingNavDelegate\|zapp_ios_router_sync\|reapply_for_window" native/ cli/` must come back empty (no dangling refs).

- [ ] **Step 8 — Commit.**
  ```bash
  git add cli/src/native.ts native/platform/ios/window.m native/platform/ios/routing.m native/platform/ios/toolbar.m native/nim/window.nim native/nim/routerstate.nim
  git rm native/platform/ios/iphonenav.m
  git commit  # message + trailer
  ```
  Message: `refactor(ios): delete owned-nav fork + reapply machinery — converge on UISplitViewController`

---

## Task 3: Kitchen-sink confirm + docs + HUMAN 2-DEVICE iOS-SIM SMOKE

**Files:** Confirm `kitchen-sink/zapp/app.nim` (`nativeRouting: true`) + `kitchen-sink/src/shell/main-pane.ts` (per-route identity) + `sidebar-pane.ts` (lateral nav) intact; Modify `docs/api-reference.md`.

- [ ] **Step 1 — Confirm the kitchen-sink engages the new seam (no edits expected).** `nativeRouting: true` still set; `main-pane.ts` per-route identity (`zapp.route` + `!canGoBack`) + the `/detail` demo button intact; `sidebar-pane.ts` iOS lateral nav (`popToRoot` + `replace` + `showContent`) intact. Report each as intact, or edit only if genuinely broken by the seam change.

- [ ] **Step 2 — Docs.** In `docs/api-reference.md`, update the iOS native-routing note: iOS sidebar windows now use one idiomatic `UISplitViewController` (iPhone collapsed = sidebar-first stack; iPad = side-by-side); `router.push` is a native `pushViewController:` with native back-button + edge-swipe; the per-route-VC reconcile + owned-nav fork are gone. Mark the per-view chrome opt-out + `--zapp-*`-from-`env()` as **coming in R2′/R3′**.

- [ ] **Step 3 — Gates.** Full set: `bun run check`; `bun test cli/src`; `bun run test:native`; macOS build; iOS compile.

- [ ] **Step 4 — Commit.** `git add docs/api-reference.md` (+ any kitchen-sink file actually edited). Message: `docs(ios): one idiomatic UISplitViewController routing path (R1′)`.

- [ ] **Step 5 — HUMAN 2-DEVICE iOS-SIM SMOKE GATE.** STOP for the user. Build + run kitchen-sink on an **iPhone sim** AND an **iPad sim**.
  - **iPhone (collapsed):** (a) starts on the **sidebar**; (b) select a section → content pushes; (c) `router.push("/detail")` → route VC **pushes** (native slide); **back-button AND edge-swipe** pop it; (d) the **toolbar follows the top VC** (no double/stale items — the R1 toolbar-drop is gone); (e) no sticky route / no duplicate inspectable webview (Safari Web Inspector) / route webview tears down on pop / worker keeps logging.
  - **iPad (expanded):** (f) sidebar + content **side-by-side**; (g) section select updates content; (h) `router.push("/detail")` pushes **within the content column**, native back + edge-swipe; (i) toolbar correct — **the #771 bugs (disabled back/fwd, toolbar drop, sticky, inset) are GONE.**

  If a gotcha shows (live-nav mis-resolves, double-pop, toolbar drop, sticky, leak), capture it — that's the risk-gate signal; iterate before R2′.

## Self-Review

**Spec coverage:** §2 seam (live `contentVC.navigationController` push + single `didShow` pop + self-teardown) → T1. §4 deletions (owned-nav fork, reconcile, reapply machinery, `zapp_router_seed_empty`) → T1+T2; the cut-together dependency list is fully enumerated in T2. §5 R1′ (converge + seam + 2-device smoke) → T1–T3. macOS-untouched + iPad-split-byte-unchanged → T2 Steps 2/7 explicit. Deferred (per-view chrome, env-insets, flag retirement) → Global Constraints, explicitly out of R1′.

**Placeholder scan:** the new-seam code (resolver, delegate, push/pop/popToRoot, Nim mapping) is concrete. The genuine risk-gate unknowns — live-nav resolution / `zapp_ios_content_vc_for_window` existence, the push-time-vs-setItems toolbar-stamp choice, the action→op mapping, single-delegate ownership — carry named line anchors + `DONE_WITH_CONCERNS` instructions + the smoke as the proof. This is the honest level for a risk-gate native rewrite (matches the R1 plan's pattern).

**Type/name consistency:** `zapp_ios_push_route_vc` / `zapp_ios_pop_route_vc` / `zapp_ios_pop_to_content` (routing.m defs ↔ router.nim importc, T1 ↔ T2 — names match). `zapp_route_content_nav` / `ZappRouteNavDelegate` / `g_route_delegates` (internal, consistent). `zapp_ios_content_vc_for_window` (resolver, both ops). `zapp_router_pop_from_native` (delegate → Nim, unchanged, no native op = no loop). `zapp_window_native_routing` (gate, kept). All consistent.
