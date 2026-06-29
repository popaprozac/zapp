# R1 — iPhone Owned-Nav Routing RISK GATE — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Prove on the iOS sim that an **app-owned `UINavigationController` (sidebar-first: sidebar = root VC)** hosts the sidebar + content + a pushed route VC cleanly on iPhone — native push, back-button + edge-swipe pop, **toolbar items persist** — gated so the shipped `UISplitViewController` stays the default.

**Architecture:** On iPhone (idiom phone) AND a window with `nativeRouting`, `window.m` builds an owned `UINavigationController` (sidebar VC = root) instead of the `UISplitViewController`; `routing.m` reconciles route VCs onto that owned nav with a stable baseline (`native = 1 + routerDepth`); the toolbar attaches to the owned nav's reliable `topViewController`. iPad + non-gated iPhone keep the split, untouched. This replaces the N3a per-route-VC-on-the-split approach that hit the `UISplitViewController` collapse-combine wall.

**Tech Stack:** ObjC (iOS `window.m`, new `iphonenav.m`, `routing.m`, `toolbar.m`), TypeScript (kitchen-sink), Bun.

## Global Constraints

- Branch `feat/ios-native-nav` — commit directly. NO git worktree, NO `git commit --amend`, NO merge.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Per-file `git add` ONLY — never `-A`/`.`. Pre-existing unrelated WIP stays unstaged.
- Bun, never Node.
- Native-first parity; new `zapp_ios_*` importc/exportc symbols satisfy `reference_ios_symbol_parity_gate` (`.m`-defined + iOS-built).
- **macOS MUST NOT regress** — iOS-only (`when defined(zappIos)` / `TARGET_OS`-gated where Nim/cross-platform). **The iPad `UISplitViewController` path AND the non-gated iPhone split path MUST stay byte-for-byte unchanged** (the owned-nav chrome is a new gated branch).
- iOS arm64 / min 15.0; sim functional / device compile-only; NO iOS simulator interaction in-session.
- Spec: `docs/superpowers/specs/2026-06-29-iphone-native-routing-model-design.md`.

Per-task gates: `bun run check`; `bun test cli/src`; `bun run test:native`; macOS build (`cd kitchen-sink && bun run build` → `[zapp] build complete:`, MUST stay green); iOS compile (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`). T5 ends in the **human iOS-sim smoke**.

## RISK-GATE note for the implementer

This proves an unproven chrome. Task 1 (cleanup) is mechanical. **Tasks 2–3 are the genuinely-new native code** but they **mirror existing patterns**, cited inline: `window.m`'s split construction (`native/platform/ios/window.m:384–436`) + the pane `create_ext` mount (`window.m:498–520`); `sidebar.m`'s per-window registry + accessors (`zapp_ios_sidebars` + `zapp_ios_*_for_window`, `sidebar.m:122,168–222`); `routing.m`'s existing reconcile + `ZappRoutingNavDelegate` + teardown; `toolbar.m`'s `zapp_ios_toolbar_apply_to_nav` (`toolbar.m:517–535`). The **routerstate↔owned-nav mapping** (sidebar = depth-0 chrome; `native = 1 + routerDepth`; first-above-sidebar = the persistent content VC, depth 2+ = ephemeral route VCs) is the genuine unknown R1 proves — implement it as specified and **report DONE_WITH_CONCERNS** if a piece (owned-nav hosting the webview, sidebar-as-root, the back-swipe, the content-VC-vs-route-VC push distinction, toolbar attach) resists, with what you saw. T1–T4 gates = build-green + iOS-compile; the **mechanism is proven in T5's human sim smoke**.

---

## Task 1: Strip the N3a diagnostics + collapsed targeting from `routing.m`

**Files:** Modify `native/platform/ios/routing.m`.

The carry-forward (f279d93) left debugging noise + the throwaway `collapsedNav`-vs-`contentNav` targeting. Remove them, leaving the reusable reconcile/delegate/teardown intact and `zapp_routing_nav` returning `contentNav` (the owned-nav resolver lands in Task 3).

- [ ] **Step 1 — Remove the two diagnostic-only externs.** Delete these lines (they're used only by the diagnostics; `routing.m` keeps `zapp_ios_content_nav_for_window`):
  ```objc
  extern BOOL zapp_ios_split_is_collapsed_for_window(void* window_ptr);
  extern UINavigationController* zapp_ios_collapsed_nav_for_window(void* window_ptr);
  ```
  (plus the `// N3a DIAGNOSTIC …` comment block above them.)

- [ ] **Step 2 — Replace `zapp_routing_nav` with the plain content-nav resolver.** Replace the whole function (currently `routing.m:153–158`, the collapsed-vs-content logic) with:
  ```objc
  // The navigation controller that hosts the route stack. iPad/expanded → contentNav
  // (a clean nav). Task 3 extends this to return the iPhone owned nav when present.
  static UINavigationController* zapp_routing_nav(void* win) {
      return zapp_ios_content_nav_for_window(win);
  }
  ```

- [ ] **Step 3 — Delete `zapp_nav_vc_dump`** (the whole `static NSString* zapp_nav_vc_dump(...)` function, `routing.m:163`-ish).

- [ ] **Step 4 — Remove all `[zapp-routing]` `NSLog`s** in `zapp_ios_router_sync` + the delegate `didShowViewController:`: the `SYNC` block (the diagnostic `{ … }` scope dumping collapsed/contentNav/routingNav around `routing.m:185–199`), the `PUSH branch`/`after PUSH`/`POP branch`/`NOOP` logs, the `didShow … →` log, and the `teardown … (pushedVCs …)` log. Keep the surrounding control flow (the `if (have < want)` / `else if` / `else` branches, the push, the pop loop, the teardown diff) — only the `NSLog(@"[zapp-routing]…")` statements (and the now-empty diagnostic `{ … }` scope) are removed. Fix the stale push-branch comment `→ push 1 ZappRouteVC onto contentNav` to `→ push 1 ZappRouteVC`.

- [ ] **Step 5 — Gates.** `bun run check`; `bun test cli/src`; `bun run test:native`; `cd kitchen-sink && bun run build` (macOS, `[zapp] build complete:`); `cd kitchen-sink && bun run build --platform ios` (`[zapp] build complete:`). The iOS routing now targets `contentNav` everywhere (iPhone routing is intentionally broken-on-the-split until Task 2/3 — build-green is the only assertion here; the smoke is T5).

- [ ] **Step 6 — Commit.**
  ```bash
  git add native/platform/ios/routing.m
  git commit  # message + trailer
  ```
  Message: `refactor(ios): strip N3a routing diagnostics + collapsed targeting (R1 cleanup)`

---

## Task 2: Owned-nav chrome construction (`iphonenav.m` + `window.m` branch)

**Files:** Create `native/platform/ios/iphonenav.m`; Modify `native/platform/ios/window.m`, `cli/src/native.ts`.

**Interfaces produced (consumed by Task 3/4):**
- `bool zapp_ios_owned_nav_enabled(int32_t window_id)` — true when this window uses the owned-nav chrome (idiom phone + `nativeRouting`).
- `UINavigationController* zapp_ios_owned_nav_for_window(void* window_ptr)` — the owned nav, or nil.
- `UIViewController* zapp_ios_owned_content_vc_for_window(void* window_ptr)` — the held content VC (the persistent content webview's VC), pushed by Task 3.
- `void zapp_ios_register_owned_nav(void* window_ptr, UINavigationController* nav, UIViewController* sidebarVC, UIViewController* contentVC)`.

- [ ] **Step 1 — Create `native/platform/ios/iphonenav.m`** — a per-window owned-nav registry + accessors, mirroring `sidebar.m`'s `zapp_ios_sidebars` registry (`sidebar.m:122,168–222`):
  ```objc
  // iPhone owned-nav chrome (R1). On iPhone with native routing, the window root is
  // an app-owned UINavigationController (sidebar = root VC) instead of a
  // UISplitViewController — eliminating the collapse-combine collision. Per-window
  // registry mirrors ios/sidebar.m's zapp_ios_sidebars.
  #import <UIKit/UIKit.h>

  extern void* darwin_window_get_by_numeric_id(int32_t numeric_id);
  extern const char* zapp_form_factor(void);            // "phone" | "tablet" (platform.m)
  extern bool zapp_window_native_routing(int32_t window_id);  // window.nim (exportc)

  @interface ZappOwnedNavController : NSObject
  @property (nonatomic, strong) UINavigationController* nav;
  @property (nonatomic, strong) UIViewController* sidebarVC;   // owned nav root
  @property (nonatomic, strong) UIViewController* contentVC;   // held; pushed on section-select (Task 3)
  @end
  @implementation ZappOwnedNavController @end

  static NSMutableDictionary<NSValue*, ZappOwnedNavController*>* g_owned_navs = nil;

  // Gate: this window uses the owned-nav chrome iff phone idiom AND native routing.
  bool zapp_ios_owned_nav_enabled(int32_t window_id) {
      const char* ff = zapp_form_factor();
      bool phone = (ff && strcmp(ff, "phone") == 0);
      return phone && zapp_window_native_routing(window_id);
  }

  void zapp_ios_register_owned_nav(void* window_ptr, UINavigationController* nav,
                                   UIViewController* sidebarVC, UIViewController* contentVC) {
      if (!window_ptr || !nav) return;
      if (!g_owned_navs) g_owned_navs = [NSMutableDictionary dictionary];
      ZappOwnedNavController* c = [ZappOwnedNavController new];
      c.nav = nav; c.sidebarVC = sidebarVC; c.contentVC = contentVC;
      g_owned_navs[[NSValue valueWithPointer:window_ptr]] = c;
  }

  UINavigationController* zapp_ios_owned_nav_for_window(void* window_ptr) {
      if (!window_ptr || !g_owned_navs) return nil;
      return g_owned_navs[[NSValue valueWithPointer:window_ptr]].nav;
  }
  UIViewController* zapp_ios_owned_content_vc_for_window(void* window_ptr) {
      if (!window_ptr || !g_owned_navs) return nil;
      return g_owned_navs[[NSValue valueWithPointer:window_ptr]].contentVC;
  }
  ```

- [ ] **Step 2 — Register `iphonenav.m` in the iOS source list.** In `cli/src/native.ts`, add `path.join(iosDir, "iphonenav.m"),` immediately after the `routing.m` entry (currently line 135). (Only the iOS `iosDir` list — NOT the `darwinDir` list.)

- [ ] **Step 3 — `window.m`: branch to the owned-nav chrome when gated.** In the `if (d->hasSidebar) { … }` block (`window.m:376`), at the TOP — before constructing the `ZappIOSSplitViewController` — add the gate + the owned-nav branch. Declare the externs near the other window.m externs (`window.m:309` area):
  ```objc
  extern bool zapp_ios_owned_nav_enabled(int32_t window_id);
  extern void zapp_ios_register_owned_nav(void* window_ptr, UINavigationController* nav,
                                          UIViewController* sidebarVC, UIViewController* contentVC);
  ```
  Then in the `d->hasSidebar` branch, wrap the existing split construction:
  ```objc
  if (d->hasSidebar) {
      BOOL ownedNav = zapp_ios_owned_nav_enabled(d->numeric_id);
      if (ownedNav) {
          // OWNED-NAV CHROME (R1): sidebar VC = root of an app-owned UINavigationController.
          // Both pane VCs are created here so the shared create_ext calls below mount each
          // webview into its FINAL container (no re-parenting). contentVC is HELD (not pushed)
          // — Task 3 pushes it on section-select; at launch the nav shows the sidebar.
          sidebarVC = [[UIViewController alloc] init];
          contentVC = [[ZappIOSPaneViewController alloc] init];
          contentVC.view.backgroundColor = bgColor;
          sidebarVC.view.backgroundColor = d->sidebar_has_bg
              ? [UIColor colorWithRed:d->sidebar_bg_r/255.0 green:d->sidebar_bg_g/255.0
                                 blue:d->sidebar_bg_b/255.0 alpha:1.0]
              : [UIColor systemBackgroundColor];
          UINavigationController* ownedNavVC =
              [[UINavigationController alloc] initWithRootViewController:sidebarVC];
          ownedNavVC.navigationBarHidden = NO;  // toolbar lives here (Task 4)
          ownedNavVC.view.backgroundColor = bgColor;
          window.rootViewController = ownedNavVC;   // BEFORE any webview creation
          zapp_ios_register_owned_nav((__bridge void*)window, ownedNavVC, sidebarVC, contentVC);
          // NOTE: do NOT call zapp_ios_sidebar_register / build the split for this window.
      } else {
          ZappIOSSplitViewController* split = …;   // EXISTING split construction, UNCHANGED
          … // (the entire current d->hasSidebar split body, verbatim)
          window.rootViewController = split;
      }
  } else { … no-sidebar path, UNCHANGED … }
  ```
  Then the **shared pane `create_ext` calls** (`window.m:491–520`, content into `contentVC.view`, sidebar into `sidebarVC.view`) run as-is for BOTH chromes — they mount into the VC views, which exist in both. **Guard the split-only follow-ups:** the existing `if (d->hasSidebar) { zapp_ios_sidebar_register(...) }` call (`window.m:476–490`) and any split-specific setup (leading-constraints, presentation) must be skipped when `ownedNav` — wrap them `if (d->hasSidebar && !zapp_ios_owned_nav_enabled(d->numeric_id)) { … }` (re-read the gate; it's pure). The implementer must read `window.m:444–640` and gate every split-specific call (`zapp_ios_sidebar_register`, inspector split-builder, leading-constraint handoff) behind `!ownedNav`, leaving the pane create_ext + slot-registration shared. **Report DONE_WITH_CONCERNS if a split-specific call can't be cleanly skipped.**

- [ ] **Step 4 — Gates.** Full gate set. iOS compile is the key gate (the chrome compiles + links + the new symbols resolve). The owned-nav chrome's runtime boot is proven in T5; here, confirm macOS + the non-gated/iPad iOS paths are unchanged (the split branch is byte-identical) and iOS compiles.

- [ ] **Step 5 — Commit.**
  ```bash
  git add native/platform/ios/iphonenav.m native/platform/ios/window.m cli/src/native.ts
  git commit  # message + trailer
  ```
  Message: `feat(ios): owned-nav chrome construction (sidebar-first root) gated on phone+nativeRouting`

---

## Task 3: Route the owned nav (resolver + baseline `1 + routerDepth` + section→content push)

**Files:** Modify `native/platform/ios/routing.m`; possibly `native/nim/routerstate.nim` / `native/nim/router.nim` (seeding) + `kitchen-sink/src/shell/sidebar-pane.ts` (section→content).

**Interfaces consumed (from Task 2):** `zapp_ios_owned_nav_for_window`, `zapp_ios_owned_content_vc_for_window`, `zapp_ios_owned_nav_enabled`.

**The model (the genuine unknown R1 proves):** owned nav = `[sidebar(0), content(1), …routes(2+)]`. The sidebar is **depth-0 chrome** (not a route). `routerDepth` counts content+routes, so **`want_native = 1 + routerDepth`**. The **first level above the sidebar (native index 1) is the persistent content VC** (`zapp_ios_owned_content_vc_for_window`, holding the content webview that lateral-switches sections); **indices 2+ are ephemeral route VCs** (`ZappRouteVC` with per-route webviews). At launch the owned nav shows the sidebar (no content pushed).

- [ ] **Step 1 — Owned-nav resolver.** Extend `zapp_routing_nav` (Task 1 left it returning `contentNav`):
  ```objc
  extern UINavigationController* zapp_ios_owned_nav_for_window(void* window_ptr);
  extern UIViewController* zapp_ios_owned_content_vc_for_window(void* window_ptr);
  …
  static UINavigationController* zapp_routing_nav(void* win) {
      UINavigationController* owned = zapp_ios_owned_nav_for_window(win);
      if (owned) return owned;                       // iPhone owned-nav chrome
      return zapp_ios_content_nav_for_window(win);   // iPad / expanded
  }
  ```

- [ ] **Step 2 — Baseline-aware reconcile.** In `zapp_ios_router_sync`, after resolving `nav`, compute the baseline so the sidebar root is excluded. For the owned nav the baseline is **1** (the sidebar); for the iPad contentNav it is **0** (no chrome root above the content VC — contentNav's root IS the content). Set:
  ```objc
  UIViewController* ownedContent = zapp_ios_owned_content_vc_for_window(win);
  int baseline = (zapp_ios_owned_nav_for_window(win) != nil) ? 1 : 0;  // sidebar root on owned nav
  int want = baseline + router_depth(windowId);
  int have = (int)nav.viewControllers.count;
  ```
  Then the existing push/pop reconcile runs against `want`/`have`. **Push distinction:** when pushing and the new top should be **native index 1 on the owned nav** (i.e. `have == 1 && ownedContent != nil`), push the **held content VC** (`ownedContent`) — NOT a new `ZappRouteVC`; otherwise mint a `ZappRouteVC` (the existing path). The content VC is persistent (do NOT add it to `pushedVCs`/tear it down on pop — only `ZappRouteVC`s tear down; the existing teardown diff already filters by `isKindOfClass:[ZappRouteVC class]` / the `pushedVCs` list, so the content VC is naturally exempt). Re-read the push branch and add the `if (have == baseline && ownedContent) [nav pushViewController:ownedContent animated:YES]; else { …existing ZappRouteVC mint… }`.

- [ ] **Step 3 — Section-select → content push (routerstate seeding).** The model needs the sidebar shown at launch (routerDepth such that `want == 1` = sidebar only) and a section-select to bring routerDepth to 1 (→ `want == 2`, push content). Read `native/nim/routerstate.nim` `routerSeed` + where `window.nim createWindow` calls it; for the owned-nav chrome the launch state must be **sidebar-only** (no content pushed). Implement ONE of: (a) the kitchen-sink sidebar's first section-select drives routerDepth 0→1 (so seed routerstate empty/at a sentinel for this chrome), or (b) keep the `/` seed but treat depth-1-at-launch as "content not yet revealed" until the first sidebar tap. **Pick (a) if it's clean**: on iOS owned-nav, `sidebar-pane.ts` section-select already does `popToRoot` + `replace` (carry-forward); ensure the FIRST select results in `want == 2` (content pushed). Decide + implement so launch shows the sidebar and the first section tap pushes content. **This is the routerstate↔nav seeding design point — implement it coherently and report DONE_WITH_CONCERNS with the chosen semantics.**

- [ ] **Step 4 — Gates.** Full set incl. iOS compile + `bun run test:native` (if `routerstate.nim`/`router.nim` touched, their tests still pass). macOS unaffected.

- [ ] **Step 5 — Commit.** `git add` the touched files (routing.m + any of routerstate.nim/router.nim/sidebar-pane.ts).
  Message: `feat(ios): route the owned nav — baseline 1+routerDepth, sidebar→content push`

---

## Task 4: Toolbar on the owned nav (persist across push+back)

**Files:** Modify `native/platform/ios/toolbar.m`.

The owned nav has a reliable `topViewController`, so the toolbar attaches normally (no collapsed/`contentVC`-targeting workaround). N1's toolbar finds the nav via `zapp_ios_content_nav_for_window` (→ nil for owned-nav windows, since they aren't in `zapp_ios_sidebars`). Make the toolbar reach the owned nav.

- [ ] **Step 1 — Read** `toolbar.m`'s `zapp_ios_toolbar_reapply_for_window` (~`toolbar.m:1000+`) — where it picks `collapsedNav` vs `contentNav` (via `zapp_ios_split_is_collapsed_for_window`) and calls `zapp_ios_toolbar_apply_to_nav` (`toolbar.m:517–535`, which sets `nav.topViewController.navigationItem.{left,right}BarButtonItems`).

- [ ] **Step 2 — Owned-nav branch in reapply.** Add `extern UINavigationController* zapp_ios_owned_nav_for_window(void* window_ptr);` and, at the TOP of `zapp_ios_toolbar_reapply_for_window` (and the metrics/inject paths that resolve the nav), short-circuit to the owned nav when present:
  ```objc
  UINavigationController* owned = zapp_ios_owned_nav_for_window(window_ptr);
  if (owned) { zapp_ios_toolbar_apply_to_nav(owned, entry, /*includeToggleSidebar*/YES); return; }
  ```
  (Place after `entry` is resolved; reuse the existing `entry` lookup. The owned nav's `topViewController` is the content/route VC — reliable — so the items attach to whatever VC is on top, and a push+back re-fires the delegate/reapply to re-attach.)

- [ ] **Step 3 — Reapply on push/pop.** Confirm `routing.m`'s `ZappRoutingNavDelegate didShowViewController:` (or a reapply call) re-applies the toolbar when the top VC changes on the owned nav, so items follow the top VC. If N1's `ZappIOSToolbarNavDelegate` isn't on the owned nav, call `zapp_ios_toolbar_reapply_for_window((__bridge void*)nav.view.window)` from the routing delegate's `didShowViewController:` after a push/pop (mirror `sidebar.m`'s collapse/expand reapply calls). Wire minimally so the toolbar follows the top VC.

- [ ] **Step 4 — Gates.** Full set. iOS compile. macOS unaffected.

- [ ] **Step 5 — Commit.** `git add native/platform/ios/toolbar.m` (+ routing.m if the reapply call was added there).
  Message: `feat(ios): toolbar attaches to the owned nav top VC (persists across push)`

---

## Task 5: Kitchen-sink wiring + docs + HUMAN iOS-SIM SMOKE

**Files:** Confirm/modify `kitchen-sink/zapp/app.nim` (nativeRouting on) + `kitchen-sink/src/shell/*` (already has lateral nav + /detail demo from the carry-forward); `docs/api-reference.md`.

- [ ] **Step 1 — Confirm the gate engages.** Verify `kitchen-sink/zapp/app.nim` still sets `nativeRouting: true` (carry-forward) — on iPhone this now selects the owned-nav chrome. Verify `kitchen-sink/src/shell/main-pane.ts` (per-route identity) + `sidebar-pane.ts` (lateral nav) are intact (carry-forward). No new TS expected unless the section→content mapping (Task 3) needs a kitchen-sink hook.

- [ ] **Step 2 — Docs.** In `docs/api-reference.md`, update the "iOS native routing (preview)" note: on iPhone, `nativeRouting` now hosts the content in an app-owned navigation stack (sidebar-first) so `router.push` is a real native push; iPad keeps the split; macOS/Windows content-swap. Mark **preview / R1 risk gate**.

- [ ] **Step 3 — Gates.** Full set: `bun run check`; `bun test cli/src`; `bun run test:native`; macOS build; iOS compile.

- [ ] **Step 4 — Commit.** `git add kitchen-sink/zapp/app.nim docs/api-reference.md` (+ any kitchen-sink/src touched).
  Message: `feat(kitchen-sink): owned-nav routing demo + docs (R1 risk gate)`

- [ ] **Step 5 — HUMAN iOS-SIM SMOKE GATE.** STOP for the controller/user. Build + run the kitchen-sink on the **iPhone simulator**. Verify (spec §3):
  1. App **starts on the sidebar** (section list).
  2. Select a section → content **pushes** in (native slide); `‹ back` returns to the sidebar; **edge-swipe-back** works.
  3. `router.push("/detail")` (the demo button) → a route VC **pushes** onto the owned nav (native slide); **back-button AND edge-swipe** pop it; route stays coherent.
  4. **Toolbar items persist** across the section push and the /detail push+back (the N3a toolbar-drop is gone).
  5. No sticky route / no duplicate inspectable webview (Safari Web Inspector shows the expected webviews) / route webviews tear down on pop / the worker keeps logging.

  If a gotcha shows (sidebar doesn't root, content doesn't push, swipe-back fails, toolbar drops, sticky/leak), capture it — that's the risk-gate signal; we iterate before R2.

## Self-Review

**Spec coverage:** §1 idiom-branched owned-nav sidebar-first → T2 (chrome) + T3 (routing). §1 "iPad/non-gated unchanged" → T2 gates the split branch behind `!ownedNav`. §3 R1 components: gate (T2), section→content push (T3), route push (T3), toolbar persist (T4), human smoke (T5). §2 routing-API direction (flag transitional) → respected (nativeRouting is the gate; drop is R3, out of R1 scope). Reuse-from-N3a-WIP → carry-forward (f279d93) + T1 strips throwaway.

**Placeholder scan:** Nim/TS/config + the `iphonenav.m` registry are concrete code. The `window.m` split-skip guarding (T2 Step 3) and the routerstate seeding (T3 Step 3) are **risk-gate design points** with the model specified + a `DONE_WITH_CONCERNS` instruction + named line anchors — decidable against the cited code, not open placeholders (this is the honest level for the genuinely-new chrome a risk gate exists to prove).

**Type/name consistency:** `zapp_ios_owned_nav_enabled` / `zapp_ios_owned_nav_for_window` / `zapp_ios_owned_content_vc_for_window` / `zapp_ios_register_owned_nav` (iphonenav.m defs ↔ window.m/routing.m/toolbar.m externs — names match across T2/T3/T4). `zapp_routing_nav` (T1 plain → T3 owned-aware). `want = baseline + router_depth` (T3). `nativeRouting` (kitchen-sink ↔ `zapp_window_native_routing`). All consistent.
