# iOS Native Pane Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild Zapp's iOS pane host on an idiomatic `UISplitViewController` (style by declared panes; inspector as a real third column; per-route navbar that hides independently of swipe-back), deleting the `doubleColumn` + inspector-in-content + `showColumn`-reveal machinery that caused the recurring nav/route bug family.

**Architecture:** The split style is chosen by which panes a window declares — `tripleColumn` (sidebar/content/inspector), `doubleColumn` (sidebar/content), or plain nav (content only). iPhone collapses to one stack: `topColumnForCollapsing→Primary` (launch on sidebar), section-select `showColumn:Supplementary` (lands on content, inspector stays out of the compact stack), drill-downs push. The inspector reaches iPhone via a navbar button (`push` or `sheet`); on iPad it's the third column the button real-toggles. The routing seam, per-pane toolbar stamping, per-route webview teardown, and `env()` insets already exist and are kept — the work is the pane-host *construction* (`window.m`/`sidebar.m`/`inspector.m`), one new `inspector.presentation` option, and making the route navbar honor a per-route `hidden` flag.

**Tech Stack:** ObjC/UIKit (`native/platform/ios/*.m`), Nim (`native/nim/*.nim`, `exportc`/`importc` C-ABI), TypeScript runtime (`runtime/*.ts`), Bun test + Nim `test:native`. The clean-room reference is `spikes/ios-splitview-reference/` (every mechanic below is human-smoked there on iPhone + iPad).

## Global Constraints

- **Branch:** `feat/ios-native-nav` (UNMERGED). NO worktree, NO `git commit --amend`, NO merge.
- **macOS MUST NOT regress.** macOS is a separate code path (`native/platform/darwin/*`) and is **untouched**. Every native task verifies the default (macOS) build still succeeds.
- **NO iOS-simulator interaction in this session.** The human runs every smoke. Our side is build-only; a build is "complete" only on a `[zapp] build complete:` line **and** a fresh binary mtime — never on Vite `✓ built` alone.
- **Per-file `git add` only** — never `git add -A` / `git add .`. Pre-existing unrelated WIP stays UNSTAGED. Each commit step lists the exact files.
- **Commit trailer `<TRAILER>`** — every commit ends with EXACTLY these two lines (expand `<TRAILER>` verbatim wherever it appears below):
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01DZ9M515fEUqt9EE2oFDyyv
  ```
- **Always Bun, never Node.**
- **Native-first ordering** per feature: C/ObjC primitive → Nim → router → TS runtime → docs, in the same phase.
- **The iOS symbol-parity gate must stay green:** `bun test cli/src/ios-platform-parity.test.ts`.

**Verification commands (used throughout):**
- iOS-sim build: `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios-simulator` → expect `[zapp] build complete:` + fresh `.app` binary mtime.
- macOS regression build: `cd /Users/zach/code/zapp/kitchen-sink && bun run build` → expect `[zapp] build complete:`.
- iOS parity gate: `cd /Users/zach/code/zapp && bun test cli/src/ios-platform-parity.test.ts`.
- Nim/native unit tests: `cd /Users/zach/code/zapp && bun run test:native`.
- TS unit tests: `cd /Users/zach/code/zapp && bun test runtime/window.test.ts`.
- Type check: `cd /Users/zach/code/zapp && bun run check`.

---

## File Structure

**Rebuilt (the pane-host construction):**
- `native/platform/ios/window.m` — `zapp_ios_materialize_pending_windows` (lines 341–694): split style by pane-count; create the inspector as the **Secondary column VC** instead of embedding it in the content VC.
- `native/platform/ios/sidebar.m` — `zapp_ios_sidebar_register` (540–636): nav-wrap up to three columns; `darwin_sidebar_show_content` (773–813): `showColumn:Supplementary` (tripleColumn) / `Secondary` (doubleColumn). `topColumnForCollapsing→Primary` (432–436) already correct.
- `native/platform/ios/inspector.m` — `zapp_ios_inspector_register` (149–258): stop embedding in the content VC (the column is assigned by `window.m`); `darwin_inspector_toggle`/`expand`/`collapse` (280–389): column show/hide on iPad, push/sheet on iPhone.

**Extended (per-route chrome + new option):**
- `native/platform/ios/routing.m` — `ZappRouteVC` + `ZappRouteNavDelegate willShowViewController:` (136–168): honor a per-route `hidden` flag; arm swipe-back when the bar is hidden (port the spike's `armSwipeBack`). `zapp_ios_push_route_vc` (215–272): accept the `hidden` flag.
- `native/nim/window.nim` — add `InspectorPresentation` enum + `InspectorOptions.presentation` + `wopts_inspector_presentation` + parse; thread a per-route `navbar.hidden` through the push.
- `runtime/window.ts` — `InspectorOptions.presentation`; per-route chrome option type.

**Kept verbatim (do NOT touch their behavior):**
- `native/platform/ios/webview.m` — the `env(safe-area-inset-*)` WKUserScript (909–924, `(document.head||document.documentElement)`), `darwin_webview_create_ext`, the `zapp.route` pending-url mechanism.
- `native/platform/ios/routing.m` — `zapp_route_vc_teardown` (73–82), `zapp_ios_push/pop_route_vc`, `zapp_ios_pop_to_content`.
- `native/platform/ios/toolbar.m` — per-pane stamping (`zapp_ios_toolbar_apply_to_nav` with `leftItemsSupplementBackButton=YES`), metrics injection.

**Reverted at Phase 4 (diagnostic probes added during the investigation):**
- `kitchen-sink/src/shell/main-pane.ts` (the `[main-pane]` overlay), `kitchen-sink/index.html` (red probe banner), `kitchen-sink/src/shell/sidebar-pane.ts` (`[zapp-nav]` logs).

---

## Phase 1 — Pane-host seam (RISK GATE)

Goal: the idiomatic split (style by pane-count, inspector as the third column, `showColumn:Supplementary` land-on-content, inspector-button toggle). Tasks 1–3 each compile and keep parity green; integrated behavior is human-smoked at Task 4.

### Task 1: `window.m` — split style by pane-count + inspector as the Secondary column

**Files:**
- Modify: `native/platform/ios/window.m:376-444` (split construction) and `:606-680` (inspector block) inside `zapp_ios_materialize_pending_windows`.
- Reference: `spikes/ios-splitview-reference/src/AppDelegate.m:57-96` (the proven construction).

**Interfaces:**
- Consumes: `ZappIOSDeferred` fields `hasSidebar`, `hasInspector`, `inspectorUrl`, `inspectorNumericId`, `inspectorWidth`, `inspectorCollapsed` (window.m:73-98); `ZappIOSSplitViewController` (impl in sidebar.m); `darwin_webview_create_ext(...)` (webview.m:756, `pane_role` arg: 0=content,1=sidebar,3=inspector).
- Produces: a materialized split whose columns are Primary=sidebar, Supplementary=content, Secondary=inspector (when all three exist); the inspector VC is the split's Secondary column (NOT a child of the content VC). `zapp_ios_inspector_register` is called with this column VC.

- [ ] **Step 1: Read the reference + current code.** Read `spikes/ios-splitview-reference/src/AppDelegate.m:40-140`, then `native/platform/ios/window.m:341-694`. Note: today line 384-385 builds `UISplitViewControllerStyleDoubleColumn` with Primary=sidebar (386) / Secondary=content (390, 405-406); the inspector (606-680) is embedded into the content VC via `zapp_ios_inspector_register`.

- [ ] **Step 2: Choose the split style by declared panes.** Replace the hard-coded `doubleColumn` at window.m:384-385 with style selection. When `d->hasInspector` is true, use `UISplitViewControllerStyleTripleColumn`; else keep `UISplitViewControllerStyleDoubleColumn`. (Content-only windows already take the non-split `ZappIOSRootViewController` path — leave that branch unchanged.) Mirror the spike:
  ```objc
  UISplitViewControllerStyle style = d->hasInspector
      ? UISplitViewControllerStyleTripleColumn
      : UISplitViewControllerStyleDoubleColumn;
  ZappIOSSplitViewController* split = [[ZappIOSSplitViewController alloc] initWithStyle:style];
  ```

- [ ] **Step 3: Assign columns by role.** Keep Primary=sidebarVC. In tripleColumn, content goes to **Supplementary** and the inspector VC goes to **Secondary**; in doubleColumn, content stays **Secondary**. Create the inspector column VC here (a `ZappIOSPaneViewController`, the same class used for content) BEFORE assigning:
  ```objc
  UISplitViewControllerColumn contentColumn = d->hasInspector
      ? UISplitViewControllerColumnSupplementary
      : UISplitViewControllerColumnSecondary;
  [split setViewController:sidebarVC forColumn:UISplitViewControllerColumnPrimary];
  [split setViewController:contentVC forColumn:contentColumn];
  if (d->hasInspector) {
      inspectorVC = [[ZappIOSPaneViewController alloc] init];
      [split setViewController:inspectorVC forColumn:UISplitViewControllerColumnSecondary];
  }
  ```
  Keep `split.presentsWithGesture = YES` (433) and the `window.rootViewController = split` set-before-webview-creation ordering (436).

- [ ] **Step 4: Set the iPad split behavior for three columns.** For tripleColumn windows set `split.preferredDisplayMode = UISplitViewControllerDisplayModeTwoBesideSecondary` and `split.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile` (the spike's iPad-tile-three-up values). Leave the doubleColumn presentation to `zapp_ios_sidebar_register` as today (the sidebar controller applies `preferredDisplayMode`/`preferredSplitBehavior` from the presentation option).

- [ ] **Step 5: Mount the inspector webview into the inspector column VC.** In the inspector block (606-680), the inspector webview must mount into `inspectorVC.view` (the Secondary column), NOT into the content VC. Keep the existing `darwin_webview_create_ext(..., inspectorVC.view, ..., /*pane_role*/3, ...)` call and the re-slot dance (649-658), but the container view is now the column VC created in Step 3. Then call `zapp_ios_inspector_register(window, inspectorVC, contentVC, contentWebview, numeric_id, inspectorNumericId, inspectorWidth, inspectorCollapsed)` (the register is rebuilt in Task 2 to store-refs-only). Remove any code that adds the inspector as a child of the content VC.

- [ ] **Step 6: iOS-sim build.** Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios-simulator`. Expected: `[zapp] build complete:` + fresh binary. (Behavior is smoked at Task 4; this step only proves it compiles + links.)

- [ ] **Step 7: Parity + macOS regression.** Run: `cd /Users/zach/code/zapp && bun test cli/src/ios-platform-parity.test.ts` (expect pass) and `cd /Users/zach/code/zapp/kitchen-sink && bun run build` (expect `[zapp] build complete:` — macOS unaffected).

- [ ] **Step 8: Commit.**
  ```bash
  cd /Users/zach/code/zapp
  git add native/platform/ios/window.m
  git commit -m "feat(ios): split style by pane-count; inspector as Secondary column

  tripleColumn when inspector declared (Primary=sidebar, Supplementary=content,
  Secondary=inspector); doubleColumn otherwise. Inspector VC is now the split's
  Secondary column, not a child of the content VC.

  <TRAILER>"
  ```

### Task 2: `inspector.m` — register stores refs; toggle/expand/collapse become column ops (iPad) / push (iPhone, push-mode)

**Files:**
- Modify: `native/platform/ios/inspector.m` — `zapp_ios_inspector_register` (149-258), `darwin_inspector_expand` (280-350), `darwin_inspector_collapse` (354-372), `darwin_inspector_toggle` (377-389).
- Reference: `spikes/ios-splitview-reference/src/ContentViewController.m:111-159` (`toggleInspector` branching on `isCollapsed`).

**Interfaces:**
- Consumes: the `inspectorVC` now assigned as the split's Secondary column by Task 1; `splitViewController` reachable via `inspectorVC.splitViewController` or the stored content VC's `splitViewController`.
- Produces: `darwin_inspector_toggle/expand/collapse(int32_t host_slot)` that on regular width call `showColumn:`/`hideColumn:UISplitViewControllerColumnSecondary` (real toggle via `displayMode` check); on compact (iPhone) push a fresh inspector VC (this task implements push only; sheet-mode is Phase 3). These remain the `darwin_inspector_*` symbols imported by `native/nim/router.nim:150-155` — do not rename.

- [ ] **Step 1: Read the reference + current code.** Read `spikes/.../ContentViewController.m:111-159` and `native/platform/ios/inspector.m:149-421`. Note today's register (149-258) does `addChildViewController:inspectorVC` to the content VC + Auto-Layout-constrains the content webview's trailing edge to the inspector — that embed is being removed.

- [ ] **Step 2: Rebuild `zapp_ios_inspector_register` to store refs only.** Since Task 1 makes `inspectorVC` the Secondary column, this function must NOT `addChildViewController:` or re-constrain the content webview. Keep: storing `inspectorVC` (weak), `contentVC` (weak), `hostWindowId`, `inspectorSlotId`, `width`, and registering the controller in the registry. Delete: the `addChildViewController:`, the width constraint that drove the in-content embed, and the content-webview trailing re-constrain (the content webview keeps its edge-pin from `darwin_webview_create_ext`). Keep the registry insert so `darwin_inspector_*` can find the controller by slot.

- [ ] **Step 3: Rebuild `darwin_inspector_toggle` for the column model.** Branch on `split.isCollapsed`:
  ```objc
  void darwin_inspector_toggle(int32_t host_slot) {
      ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(host_slot);
      if (!c) return;
      zapp_ios_inspector_on_main(^{
          UISplitViewController* split = c.contentVC.splitViewController;
          if (!split) return;
          if (split.isCollapsed) {
              // Compact (iPhone): push a fresh inspector route VC (push-mode default).
              darwin_inspector_expand(host_slot);
              return;
          }
          // Regular (iPad): toggle the Secondary column.
          BOOL visible = split.displayMode == UISplitViewControllerDisplayModeTwoBesideSecondary
                      || split.displayMode == UISplitViewControllerDisplayModeSecondaryOnly;
          if (visible) [split hideColumn:UISplitViewControllerColumnSecondary];
          else         [split showColumn:UISplitViewControllerColumnSecondary];
      });
  }
  ```

- [ ] **Step 4: Rebuild `darwin_inspector_expand` / `darwin_inspector_collapse`.** Regular width: `expand` → `[split showColumn:UISplitViewControllerColumnSecondary]`; `collapse` → `[split hideColumn:UISplitViewControllerColumnSecondary]`. Compact (iPhone), push-mode: `expand` pushes a fresh inspector VC onto the content nav, `collapse` pops it if the top VC is the pushed inspector. Use the content nav: `UINavigationController* nav = c.contentVC.navigationController;`. The pushed inspector VC mounts its own webview — for push-mode reuse the same inspector column webview is not possible (it belongs to the column); instead create a lightweight inspector route VC via the existing route push path OR a dedicated inspector push. Keep `zapp_ios_inspector_emit_*` emits ("inspector-collapsed"/"inspector-resized") on each transition for JS parity. Emit `"inspector-expanded"`/`"inspector-collapsed"` as today.

- [ ] **Step 5: Keep the documented no-ops.** `darwin_inspector_set_collapsible` (412-414) and `darwin_inspector_set_resizable` (419-421) remain no-ops (no iOS divider). `darwin_inspector_set_width` (395-407) keeps the iPad animate-width path but now drives the Secondary column's `preferredSupplementaryColumnWidth`/`preferredSecondaryColumnWidth` — set `split.preferredSecondaryColumnWidth = width` and emit `inspector-resized`.

- [ ] **Step 6: iOS-sim build + parity + macOS regression.** Run the iOS-sim build, `bun test cli/src/ios-platform-parity.test.ts`, and the macOS build. All green.

- [ ] **Step 7: Commit.**
  ```bash
  cd /Users/zach/code/zapp
  git add native/platform/ios/inspector.m
  git commit -m "feat(ios): inspector is the Secondary column — toggle = show/hideColumn (iPad), push (iPhone)

  Drop the addChildViewController embed-in-content; register stores refs only.
  darwin_inspector_toggle/expand/collapse drive UISplitViewControllerColumnSecondary
  on regular width and push the inspector on compact (push-mode).

  <TRAILER>"
  ```

### Task 3: `sidebar.m` — section-select lands on content (`showColumn:Supplementary`)

**Files:**
- Modify: `native/platform/ios/sidebar.m` — `zapp_ios_sidebar_register` (540-636), `darwin_sidebar_show_content` (773-813).
- Reference: `spikes/ios-splitview-reference/src/SidebarViewController.m:46-82` (the `showColumn:Supplementary` recipe + popToRoot-if-drilled).

**Interfaces:**
- Consumes: the split built in Task 1 (tripleColumn when inspector present); `ZappIOSSidebarController` properties (`splitVC`, `contentVC`, `contentNav`).
- Produces: `darwin_sidebar_show_content(int32_t host_slot)` that, when collapsed, surfaces the **content** column (Supplementary in tripleColumn, Secondary in doubleColumn) — never the inspector. Keeps the `darwin_sidebar_*` symbols imported by `router.nim:139-149`.

- [ ] **Step 1: Read the reference + current code.** Read `spikes/.../SidebarViewController.m:46-82` and `native/platform/ios/sidebar.m:773-813`. Today `darwin_sidebar_show_content` does compact `showColumn:UISplitViewControllerColumnSecondary` — correct for doubleColumn (Secondary=content) but WRONG for tripleColumn (Secondary=inspector → folds content+inspector → lands on inspector).

- [ ] **Step 2: Make `show_content` target the content column by style.** The content column is Supplementary when the split style is tripleColumn, else Secondary. Resolve it from the split:
  ```objc
  static UISplitViewControllerColumn zapp_ios_content_column(UISplitViewController* svc) {
      // tripleColumn has a Supplementary column; doubleColumn does not.
      return (svc.style == UISplitViewControllerStyleTripleColumn)
          ? UISplitViewControllerColumnSupplementary
          : UISplitViewControllerColumnSecondary;
  }
  ```
  In the compact branch of `darwin_sidebar_show_content`, call `[c.splitVC showColumn:zapp_ios_content_column(c.splitVC)]`. Add the popToRoot-if-drilled guard before it (mirror the spike): if `c.contentNav.viewControllers.count > 1`, `[c.contentNav popToRootViewControllerAnimated:NO]` first. Leave the overlay-regular (`hideColumn:Primary`) and tile-regular (no-op) branches unchanged.

- [ ] **Step 3: Nav-wrap three columns in `zapp_ios_sidebar_register`.** Today (581-591) it nav-wraps Primary(sidebar) + Secondary(content) and re-installs via `setViewController:forColumn:`. For tripleColumn, the content column is Supplementary and the inspector column (Secondary) also needs nav-wrapping so it gets its own `navigationItem` (the per-pane toolbar requirement). Where the split has a Secondary inspector VC (tripleColumn), wrap it in a `UINavigationController` (bar visible — it's the inspector's own bar) and re-install at `UISplitViewControllerColumnSecondary`; wrap content at the content column. Keep `navigationBarHidden` choices per pane as today for sidebar (hidden) / content (managed by the route delegate). The inspector nav bar shows (it carries the inspector's title + its own items).

- [ ] **Step 4: iOS-sim build + parity + macOS regression.** All green.

- [ ] **Step 5: Commit.**
  ```bash
  cd /Users/zach/code/zapp
  git add native/platform/ios/sidebar.m
  git commit -m "feat(ios): section-select lands on content (showColumn:Supplementary in tripleColumn)

  show_content resolves the content column by split style (Supplementary for
  tripleColumn, Secondary for doubleColumn) + popToRoot-if-drilled. Nav-wrap the
  inspector (Secondary) column so it carries its own navigationItem.

  <TRAILER>"
  ```

### Task 4: Phase 1 GATE — human smoke (iPhone + iPad) + macOS

**Files:** none (verification only).

- [ ] **Step 1: Full build sweep.** Run, in order: `bun test cli/src/ios-platform-parity.test.ts`; `cd kitchen-sink && bun run build --platform ios-simulator` (expect `[zapp] build complete:` + fresh binary); `cd kitchen-sink && bun run build` (macOS, expect complete).

- [ ] **Step 2: Hand the human the smoke sheet.** STOP and ask the human to run the kitchen-sink iOS app on an **iPhone** sim and an **iPad** sim and confirm:
  - iPhone: cold-launch shows the **sidebar**; tapping a section lands on **content** (NOT the inspector); the inspector toggle button opens the inspector (push) and Back returns to content.
  - iPad: three columns tile side-by-side (sidebar | content | inspector); the inspector toggle button **hides/shows** the inspector column.
  - No macOS check needed from the human (build-verified).

- [ ] **Step 3: Record the gate.** On human PASS, append to `.superpowers/sdd/progress.md`: `Phase 1 GATE: PASS (iPhone land-on-content + inspector-button; iPad 3-col tile + toggle)`. On FAIL, capture the exact symptom and return to the relevant task before proceeding.

---

## Phase 2 — Per-route chrome + lifecycle

Goal: a route can declare `navbar.hidden`, and a hidden bar still swipes back. The teardown already exists (kept); this phase threads the flag and ports the spike's swipe re-arm into `ZappRouteVC`.

### Task 5: Thread a per-route `navbar.hidden` flag through the push

**Files:**
- Modify: `native/platform/ios/routing.m` — `zapp_ios_push_route_vc` (215-272) signature + `ZappRouteVC` (44-68); `native/nim/router.nim:35` (the importc decl); the Nim caller that pushes routes.
- Reference: `spikes/.../DetailViewController.m:206-217` (viewWillAppear hides the bar).

**Interfaces:**
- Consumes: the route URL + a new `hidden` boolean from the Nim router.
- Produces: `void zapp_ios_push_route_vc(int32_t windowId, const char* url, bool navbarHidden)` — `ZappRouteVC` stores `navbarHidden`; the nav delegate reads it.

- [ ] **Step 1: Add a `navbarHidden` property to `ZappRouteVC`.** In routing.m:44-46 add `@property (nonatomic, assign) BOOL navbarHidden;`.

- [ ] **Step 2: Widen `zapp_ios_push_route_vc`.** Add a trailing `bool navbarHidden` parameter (routing.m:215). After creating the VC, set `vc.navbarHidden = navbarHidden;` before the push.

- [ ] **Step 3: Update the Nim importc + caller.** In `native/nim/router.nim:35` change the decl to `proc zapp_ios_push_route_vc(windowId: int32, url: cstring, navbarHidden: bool) {.importc, cdecl.}`. Find the Nim call site (grep `zapp_ios_push_route_vc(` under `native/nim/`) and pass the route's hidden flag — for now pass `false` (no route declares hidden yet; the flag is wired end-to-end in Task 7's smoke via the kitchen-sink). Keep the signature change atomic with the C side so the build links.

- [ ] **Step 4: iOS-sim build + parity + macOS regression.** All green (passing `false` keeps current behavior).

- [ ] **Step 5: Commit.**
  ```bash
  cd /Users/zach/code/zapp
  git add native/platform/ios/routing.m native/nim/router.nim
  git commit -m "feat(ios): thread per-route navbarHidden through zapp_ios_push_route_vc

  ZappRouteVC stores navbarHidden; Nim importc widened. Caller passes false for
  now; the route delegate consumes it in the next task.

  <TRAILER>"
  ```

### Task 6: Apply per-route bar visibility + arm swipe-back when hidden

**Files:**
- Modify: `native/platform/ios/routing.m` — `ZappRouteNavDelegate willShowViewController:` (136-168); add a `ZRPopGestureDelegate` + `armSwipeBack` to `ZappRouteVC`.
- Reference: `spikes/.../DetailViewController.m:38-104` (`ZRPopGestureDelegate`), `:303-338` (`armSwipeBack`), `:233-251` (cancelled-swipe transitionCoordinator).

**Interfaces:**
- Consumes: `ZappRouteVC.navbarHidden`.
- Produces: when a route VC declares `navbarHidden`, its bar is hidden on `willShow` and swipe-back still works (re-arm + scroll-pan arbitration + `allowsBackForwardNavigationGestures=NO`).

- [ ] **Step 1: Read the reference.** Read the three spike ranges above. Note the three-layer swipe recipe and the weak-ref `ZRPopGestureDelegate` (no retain cycle).

- [ ] **Step 2: Make `willShowViewController:` honor the route's flag.** In `ZappRouteNavDelegate willShowViewController:` (routing.m:136-168), when the shown VC is a `ZappRouteVC`, set the bar from its `navbarHidden` (`[nav setNavigationBarHidden:routeVC.navbarHidden animated:animated]`) instead of unconditionally showing it. Keep showing the bar for the content VC and hiding for other (sidebar) VCs as today. Preserve the idempotency guard (only call `setNavigationBarHidden:` on change) and the one-tick `zapp_toolbar_inject_metrics` dispatch.

- [ ] **Step 3: Add `ZRPopGestureDelegate`.** Port the spike's class (DetailViewController.m:38-104) into routing.m: `<UIGestureRecognizerDelegate, UINavigationControllerDelegate>`, `duringPushAnimation` BOOL, **weak** `realDelegate`, `gestureRecognizerShouldBegin:` returning `nav.viewControllers.count > 1 && !duringPushAnimation`, `shouldRecognizeSimultaneouslyWithGestureRecognizer:` returning YES, and will/didShow forwarding to `realDelegate` while flipping `duringPushAnimation`. Keep refs weak so no cycle with the route VC.

- [ ] **Step 4: Add `armSwipeBack` to `ZappRouteVC`.** In the route VC's `viewWillAppear:` (add the override), when `self.navbarHidden`, call an `armSwipeBack` that mirrors the spike (DetailViewController.m:303-338): set `nav.interactivePopGestureRecognizer.delegate = self.popDelegate` (forwarding `realDelegate` to the existing `ZappRouteNavDelegate`), `[self.webview.scrollView.panGestureRecognizer requireGestureRecognizerToFail:nav.interactivePopGestureRecognizer]`, `self.webview.allowsBackForwardNavigationGestures = NO`, and `if (@available(iOS 26.0,*)) nav.interactiveContentPopGestureRecognizer.enabled = YES;`. NOTE the route's webview is the weak `webview` property already on `ZappRouteVC`.

- [ ] **Step 5: Add the cancelled-swipe smoothing.** In the route VC's `viewWillDisappear:` (add the override), port the spike's transitionCoordinator block (DetailViewController.m:233-251): if the interactive transition cancels, re-hide the bar without animation to avoid a flash. Only relevant when `self.navbarHidden`.

- [ ] **Step 6: Confirm teardown still fires.** Verify `zapp_route_vc_teardown` (routing.m:73-82) is still invoked from `viewDidDisappear:` when `isMovingFromParentViewController` — adding the `viewWillDisappear:` override must not shadow it. If `viewDidDisappear:` already exists keep it; the teardown call is unchanged.

- [ ] **Step 7: iOS-sim build + parity + macOS regression.** All green.

- [ ] **Step 8: Commit.**
  ```bash
  cd /Users/zach/code/zapp
  git add native/platform/ios/routing.m
  git commit -m "feat(ios): per-route navbar.hidden + swipe-back re-arm on hidden routes

  willShow sets the bar from ZappRouteVC.navbarHidden; armSwipeBack ports the
  spike recipe (pop-gesture delegate re-arm + scroll-pan requireToFail +
  allowsBackForwardNavigationGestures=NO + iOS26 content pop). Cancelled-swipe
  bar flash smoothed via transitionCoordinator. Teardown unchanged.

  <TRAILER>"
  ```

### Task 7: Phase 2 GATE — human smoke (iPhone)

**Files:** none (verification only). A temporary kitchen-sink edit drives the smoke and is reverted in Phase 4.

- [ ] **Step 1: Make the existing `/detail` route declare `navbar.hidden`.** In the kitchen-sink, set the `/detail` push to request a hidden navbar (the runtime option lands in Phase 3/4; for this gate, temporarily pass the hidden flag through the push path the Nim caller exposes, or hardcode `true` at the `zapp_ios_push_route_vc` call for the `/detail` URL). Build iOS-sim.

- [ ] **Step 2: Hand the human the smoke sheet.** Ask the human to run the iPhone sim and confirm on `/detail`: the route is **full-bleed with no navbar**; left-edge **swipe-back works** (content slides in under the drag); the in-content Back also works; after pop, no leak — and lateral section switches still land on content. Capture the `[zapp-nav] detail dealloc` line if instrumented.

- [ ] **Step 3: Revert the temporary hardcode** (if used) so the tree is clean for Phase 3, then record `Phase 2 GATE: PASS` in `.superpowers/sdd/progress.md`.

---

## Phase 3 — `inspector.presentation` (push | sheet) + iPad real-toggle

Goal: make the iPhone inspector presentation configurable, mirroring the existing `sidebarPresentation` option (TDD), and confirm the iPad real-toggle.

### Task 8: `inspector.presentation` option — Nim enum + parse + accessor (TDD)

**Files:**
- Modify: `native/nim/window.nim` (enum ~57-61 pattern, `InspectorOptions` struct 145-155, accessor pattern at 291, parse in `windowOptsApplyJson` 646-656).
- Test: `native/nim/tests/windowmanager_test.nim` (mirror blocks at 93-103, 198-206, 209-226; defaults block 113-121).

**Interfaces:**
- Produces: `InspectorPresentation {.pure.} = enum (Default="", Push="push", Sheet="sheet")`; `InspectorOptions.presentation*: InspectorPresentation`; `wopts_inspector_presentation(p): cstring`; JSON parse of `inspector.presentation`.

- [ ] **Step 1: Write the failing Nim tests.** In `native/nim/tests/windowmanager_test.nim`, add three blocks mirroring the sidebar ones:
  ```nim
  block:
    let o = WindowOptions(title: "ipres")
    windowOptsApplyJson(o, parseJson("""{"inspector":{"url":"#in","width":300,"presentation":"sheet"}}"""))
    doAssert o.inspector.presentation == InspectorPresentation.Sheet, "inspector.presentation must parse to the enum"
  block:
    let o = WindowOptions(title: "ipres-default")
    windowOptsApplyJson(o, parseJson("""{"inspector":{"url":"#in"}}"""))
    doAssert o.inspector.presentation == InspectorPresentation.Default, "absent inspector.presentation must default to Default"
  block:
    let o = WindowOptions(title: "ipres-bad")
    windowOptsApplyJson(o, parseJson("""{"inspector":{"presentation":"nope"}}"""))
    doAssert o.inspector.presentation == InspectorPresentation.Default, "unknown inspector.presentation must fall back to Default"
  ```

- [ ] **Step 2: Run the tests — verify they FAIL.** Run: `cd /Users/zach/code/zapp && bun run test:native`. Expected: compile error / assertion failure on `InspectorPresentation` / `inspector.presentation` (not yet defined).

- [ ] **Step 3: Add the enum + struct field + lookup + accessor.** In `native/nim/window.nim`: add `InspectorPresentation {.pure.} = enum (Default="", Push="push", Sheet="sheet")` (next to `SidebarPresentation`, 57-61); add `presentation*: InspectorPresentation` to `InspectorOptions` (145-155); add an `inspectorPresStr` lookup table mirroring `sidebarPresStr` (231-234); add `proc wopts_inspector_presentation(p: pointer): cstring {.exportc, cdecl.} = inspectorPresStr[opt(p).inspector.presentation].cstring` (mirror line 291).

- [ ] **Step 4: Parse it in `windowOptsApplyJson`.** Inside the `inspector` block (646-656) add: `if jHasStr(insp, "presentation"): o.inspector.presentation = enumFromStr[InspectorPresentation](jStr(insp, "presentation"), InspectorPresentation.Default)`.

- [ ] **Step 5: Run the tests — verify they PASS.** Run: `cd /Users/zach/code/zapp && bun run test:native`. Expected: the three new blocks pass.

- [ ] **Step 6: Add the defaults assertion + commit.** Add `doAssert o.inspector.presentation == InspectorPresentation.Default` to the defaults block (113-121); re-run `bun run test:native` (pass). Commit:
  ```bash
  cd /Users/zach/code/zapp
  git add native/nim/window.nim native/nim/tests/windowmanager_test.nim
  git commit -m "feat(ios): inspector.presentation option (Nim enum + parse + accessor, TDD)

  InspectorPresentation Default/Push/Sheet, mirroring SidebarPresentation; parsed
  in windowOptsApplyJson; wopts_inspector_presentation accessor.

  <TRAILER>"
  ```

### Task 9: `inspector.presentation` — TS type + test, and wire the accessor to the native push/sheet choice

**Files:**
- Modify: `runtime/window.ts` (`InspectorOptions` interface 296-325).
- Test: `runtime/window.test.ts` (mirror the `BackgroundExtension` const block 27-40).
- Modify: `native/platform/ios/inspector.m` — `darwin_inspector_expand` compact branch to read the presentation and push (default) or present a sheet; the native call must reach `wopts_inspector_presentation` for the window.

**Interfaces:**
- Consumes: `wopts_inspector_presentation` (Task 8).
- Produces: `InspectorOptions.presentation?: "push" | "sheet"` (TS); compact `darwin_inspector_expand` chooses push vs sheet.

- [ ] **Step 1: Write the failing TS test.** In `runtime/window.test.ts`, mirror the existing presentation-string test pattern (the `BackgroundExtension` block at 27-40 and any `sidebar` presentation test) asserting `InspectorOptions` accepts `presentation: "push"` and `"sheet"`. Run `cd /Users/zach/code/zapp && bun test runtime/window.test.ts` — expect FAIL (type/usage not present).

- [ ] **Step 2: Add the TS field.** In `runtime/window.ts` `InspectorOptions` (296-325) add `presentation?: "push" | "sheet";` with a doc comment mirroring `SidebarOptions.presentation` (291-293): on iPhone, `push` (default) pushes the inspector as a page; `sheet` presents it as a modal sheet; on iPad it is always the third column the toggle shows/hides.

- [ ] **Step 3: Run the TS test — PASS.** `cd /Users/zach/code/zapp && bun test runtime/window.test.ts` (pass) and `bun run check` (types clean).

- [ ] **Step 4: Wire the native sheet path.** In `inspector.m` `darwin_inspector_expand` compact branch, read the window's inspector presentation. The sheet path largely exists from the prior held-sheet implementation — branch: if presentation is `"sheet"`, present the inspector VC via `UISheetPresentationController` (medium+large detents + grabber, with a Done button), as the legacy iPhone path did; else (push / default) push the inspector VC onto the content nav (Task 2's push-mode). Resolve the presentation by calling `wopts_inspector_presentation` for the window's deferred options (thread the window pointer / numeric id into the controller at register time if not already available).

- [ ] **Step 5: iOS-sim build + parity + macOS regression + type check.** All green.

- [ ] **Step 6: Commit.**
  ```bash
  cd /Users/zach/code/zapp
  git add runtime/window.ts runtime/window.test.ts native/platform/ios/inspector.m
  git commit -m "feat(ios): inspector.presentation push|sheet — TS type + native compact branch

  InspectorOptions.presentation in runtime; darwin_inspector_expand compact branch
  pushes (default) or presents a UISheetPresentationController per the option.

  <TRAILER>"
  ```

### Task 10: Phase 3 GATE — human smoke (iPhone push vs sheet + iPad toggle)

**Files:** none (verification only); a temporary kitchen-sink `inspector.presentation` toggle drives it.

- [ ] **Step 1: Build with the kitchen-sink declaring `inspector.presentation`.** Temporarily set the kitchen-sink window's `inspector.presentation` to `"push"`, build iOS-sim; then `"sheet"`, build again.
- [ ] **Step 2: Human smoke.** Ask the human to confirm on iPhone: `push` opens the inspector as a page (Back returns); `sheet` opens it as a draggable modal (Done/swipe dismisses). On iPad: the inspector toggle button **shows and hides** the third column (real toggle, not just show).
- [ ] **Step 3: Revert the temporary kitchen-sink toggle; record `Phase 3 GATE: PASS`.**

---

## Phase 4 — Kitchen-sink rebuild, iPad polish, docs

### Task 11: Revert diagnostic probes + rebuild the kitchen-sink shell on the seam

**Files:**
- Modify: `kitchen-sink/src/shell/main-pane.ts` (remove the `[main-pane]` debug overlay added during diagnosis), `kitchen-sink/index.html` (remove the red probe banner), `kitchen-sink/src/shell/sidebar-pane.ts` (remove `[zapp-nav]` console logs).
- Modify: kitchen-sink window config to declare `sidebar` + `inspector` so the tripleColumn path is exercised.

- [ ] **Step 1: Revert the probes.** Remove the `dbg`/`updateDbg`/`lastEvt`/`evtCount` overlay block from `main-pane.ts` (added ~lines 86-101 + the calls in the `router.on` handler), restoring the handler to its pre-probe form. Remove the red diagnostic banner from `kitchen-sink/index.html`. Remove the `[zapp-nav]` `console.log` lines from `sidebar-pane.ts` (the click handler + any route-event logs). Keep the actual nav logic.

- [ ] **Step 2: Confirm the shell uses native panes.** Ensure the kitchen-sink window declares `sidebar` and `inspector` (so the rebuilt tripleColumn path runs). The lateral nav (sidebar select → `popToRoot` + `replace` + `showContent`) and the `/detail` drill stay as the section model intends.

- [ ] **Step 3: iOS-sim build + macOS build + type check.** All green.

- [ ] **Step 4: Commit.**
  ```bash
  cd /Users/zach/code/zapp
  git add kitchen-sink/src/shell/main-pane.ts kitchen-sink/index.html kitchen-sink/src/shell/sidebar-pane.ts
  git commit -m "chore(kitchen-sink): remove iOS diagnostic probes; run on the rebuilt pane seam

  <TRAILER>"
  ```

### Task 12: Exercise all sidebar/inspector sizing options + iPad detail inset

**Files:**
- Verify/adjust: `native/platform/ios/sidebar.m` (`darwin_sidebar_set_width`/`set_resizable`/`set_collapsible`/`set_presentation`), `native/platform/ios/inspector.m` (`darwin_inspector_set_width`).
- Modify (if needed): the iPad detail-route inset (the `viewSafeAreaInsetsDidChange` / `env()` path) — only if the human smoke shows a wrong inset.

- [ ] **Step 1: Build a sizing matrix in the kitchen-sink window config (temporary).** Configure sidebar with `width`/`minWidth`/`maxWidth`/`resizable`/`collapsible`/`presentation: "overlay"|"tile"` and inspector with `width`/`presentation`. Build iOS-sim.

- [ ] **Step 2: Human smoke (iPad + iPhone).** Ask the human to confirm: sidebar respects `width`/`minWidth`/`maxWidth`; `resizable:false` locks the divider; `collapsible` gates the collapse gesture; `presentation: overlay` vs `tile` behave; inspector `width` applies; and the iPad `/detail` route inset is correct (no bleed, no oversized gap).

- [ ] **Step 3: Fix any divergence at the native layer only** (no kitchen-sink hacks). If the iPad detail inset is wrong, adjust the route VC's safe-area handling in `routing.m`/`window.m` (the `env()` path is the source of truth — do not reintroduce native inset injection). iOS-sim build + macOS build after any fix.

- [ ] **Step 4: Revert the temporary sizing matrix** from the kitchen-sink config (keep one representative configuration). Commit any native fixes:
  ```bash
  cd /Users/zach/code/zapp
  git add native/platform/ios/sidebar.m native/platform/ios/inspector.m  # + routing.m/window.m if touched
  git commit -m "fix(ios): pane sizing-option + iPad detail-inset adjustments from smoke

  <TRAILER>"
  ```
  (If no native change was needed, skip the commit and note "sizing options verified, no change" in the ledger.)

### Task 13: Docs + final 2-device smoke

**Files:**
- Modify: `docs/api-reference.md` (or the inspector/sidebar option docs) — document `inspector.presentation` and the per-route `navbar.hidden`; note iOS per-pane toolbars + the iPhone collapse behavior (land-on-content, inspector-as-button).

- [ ] **Step 1: Document the new surface.** Add `inspector.presentation: "push" | "sheet"` (iPhone) to the inspector options doc, mirroring the `sidebarPresentation` entry; document per-route `navbar.hidden` (independent of swipe-back); add a short "iOS pane behavior" note (tripleColumn by pane-count; iPhone collapse lands on content; inspector is a navbar button on iPhone, a side column on iPad).

- [ ] **Step 2: Final full build sweep.** `bun run test:all` (TS + native + check), `bun test cli/src/ios-platform-parity.test.ts`, `cd kitchen-sink && bun run build --platform ios-simulator`, `cd kitchen-sink && bun run build` (macOS). All green.

- [ ] **Step 3: Final human smoke (iPhone + iPad).** Ask the human to run the full kitchen-sink sequence on both devices once more (sidebar→content→detail→back→section switch; inspector toggle; sizing) and confirm no regressions.

- [ ] **Step 4: Commit docs + record completion.**
  ```bash
  cd /Users/zach/code/zapp
  git add docs/api-reference.md
  git commit -m "docs(ios): inspector.presentation + per-route navbar.hidden + iOS pane behavior

  <TRAILER>"
  ```
  Append `Phase 4 GATE: PASS — iOS pane foundation complete` to `.superpowers/sdd/progress.md`.

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-06-29-ios-native-pane-foundation-design.md`):
- §3.1 split-by-pane-count → Task 1. §3.2 iPhone collapse recipe → Tasks 1+3. §3.3 inspector.presentation push|sheet + iPad toggle → Tasks 2, 8, 9, 10. §3.4 per-pane + per-route chrome (navbar.hidden ⟂ swipe) → Tasks 3 (per-pane nav-wrap), 5, 6. §3.5 per-route teardown → kept (Task 6 Step 6 verifies). §3.6 env() insets → kept (Task 12 guards). §4 delete doubleColumn/inspector-in-content/showColumn → Tasks 1, 2, 3. §4 kitchen-sink rebuild + sizing + iPad inset → Tasks 11, 12. Docs → Task 13. All spec sections map to a task.
- **Placeholder scan:** the native ObjC steps reference the spike file:line as source-of-truth and the exact Zapp function/line to change — no "add error handling"/"similar to" placeholders. Option-parsing tasks (8, 9) carry full test + impl code.
- **Type consistency:** `InspectorPresentation` (Nim) ↔ `InspectorOptions.presentation` (TS) ↔ `wopts_inspector_presentation` accessor are named consistently across Tasks 8–9. `zapp_ios_push_route_vc(windowId, url, navbarHidden)` signature is defined in Task 5 and consumed in Task 6. `darwin_inspector_*` symbol names are preserved (router.nim imports unchanged).
- **Gate discipline:** every phase ends with a human-smoke GATE (Tasks 4, 7, 10, 13); each native task independently builds + keeps parity green; macOS is regression-checked at every native task.
