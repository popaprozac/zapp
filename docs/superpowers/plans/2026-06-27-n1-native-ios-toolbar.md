# N1 — Native iOS Toolbar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the cross-platform `placement` toolbar items in the content column's `UINavigationItem` on iOS — a real native nav bar — replacing the kitchen-sink HTML top-bar.

**Architecture:** Fill the 6 no-op functions in `native/platform/ios/toolbar.m`, mirroring `native/platform/darwin/toolbar.m` adapted to UIKit (`NSToolbarItem`→`UIBarButtonItem`, `NSImage`→`UIImage`). Reach the content `UINavigationController` via `zapp_ios_sidebar_for_slot(slot).contentNav` (sidebar.m), set `contentVC.navigationItem` from the placement buckets, show the bar, inject `--zapp-toolbar-height`. The TS/Nim/router wire already exists (`toolbar:setItems` reaches the stubs); this cycle is the iOS `.m` consumer + docs.

**Tech Stack:** Objective-C (UIKit: `UINavigationItem`/`UIBarButtonItem`/`UISegmentedControl`/`UIMenu`/`UIImage`), WKWebView (`evaluateJavaScript`/`WKUserScript`), Bun (gates).

## Global Constraints

- Branch `feat/ios-native-nav` — commit directly. NO worktree, NO `git commit --amend`, NO merge.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Per-file `git add` only — never `-A`/`.`. Pre-existing unrelated WIP stays unstaged.
- Bun, never Node.
- macOS is the parity reference — do NOT touch `native/platform/darwin/toolbar.m` or regress `NSToolbar`. This cycle is iOS-only + the kitchen-sink + docs.
- NO iOS simulator interaction in-session — build-only gates; human smoke (iPhone+iPad) run by the controller/user.
- Decisions (from the spec): `toggleSidebar`/`toggleInspector` → manual `UIBarButtonItem` → `darwin_sidebar_toggle`/`darwin_inspector_toggle` (NOT `displayModeButtonItem`); no-sidebar windows deferred; native toolbar renders on-`setItems` (no flag); `trackingSeparator` dropped on iOS; `badge`/`style:prominent`/`controlRepresentation` ignored without error.

Per-task gates: `bun run check`; `bun test cli/src`; `bun run test:native`; iOS compile (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`); macOS build (`cd kitchen-sink && bun run build` → `[zapp] build complete:`).

## Reference map (read before implementing — from exploration)

- **Entry stubs** (`native/platform/ios/toolbar.m`, fill these): `darwin_toolbar_set_items(void* window_ptr, const char* toolbar_json, int32_t host_slot)` (the live entry — router calls it); `darwin_toolbar_update_item(void* window_ptr, const char* item_json)`; `darwin_toolbar_remove(void* window_ptr)`; `zapp_toolbar_inject_metrics(void* window_ptr, int32_t host_slot, bool add_user_script)`; `zapp_toolbar_unregister(void* window_ptr)`; `darwin_toolbar_attach(...)` (unused on iOS — leave a no-op or minimal).
- **Reach the content nav controller:** `extern ZappIOSSidebarController* zapp_ios_sidebar_for_slot(int32_t slot)` is `static` in sidebar.m — so add a small exported accessor in sidebar.m if needed, OR (preferred) add an exported helper in sidebar.m like `UINavigationController* zapp_ios_content_nav_for_window(void* window_ptr)` returning `c.contentNav` (and the split VC for completeness). `contentNav` is `ZappIOSSidebarController.contentNav` (sidebar.m:81); the controller is in the `zapp_ios_sidebars` dict keyed by `[NSValue valueWithPointer:window_ptr]`. Set items on `contentNav.topViewController.navigationItem` (= `contentVC.navigationItem`); show via `contentNav.navigationBarHidden = NO`.
- **Content webview for metrics:** `extern WKWebView* zapp_ios_content_webview_for_slot(int32_t slot)` (window.m:116).
- **macOS to mirror** (`native/platform/darwin/toolbar.m`): `zapp_toolbar_parse_items` (~463–541, the per-item dict reads + placement bucketing), `zapp_toolbar_emit_click` (~95–112, event `window:toolbar-clicked` payload `{"windowId":"win-N","id":"…"}`), the group-select emit (`window:toolbar-group-selected` `{windowId,id,index,selected}`), and `zapp_toolbar_inject_metrics` (~825–920, the `--zapp-toolbar-height` JS).
- **iOS eval-all:** `extern void zapp_ios_eval_js_all_webviews(...)` (window.m:598) — use for the click/group emit fan-out. Window-id string: `win-<numeric_id>`.
- **Sidebar/inspector toggles:** `extern void darwin_sidebar_toggle(int32_t)` / `extern void darwin_inspector_toggle(int32_t)` (confirm exact names/signatures in sidebar.m/inspector.m before use).
- **Build registration:** if `ios/toolbar.m` gains helpers or the icon resolver in a new file, ensure the iOS source list (the CLI iOS build manifest / `cli/src/native.ts` iOS sources) includes them. (Confirm `ios/toolbar.m` is already in the iOS build — it is, since the stubs link today.)

---

## Task 1: RISK GATE — core items + nav bar + metrics

**Files:**
- Modify: `native/platform/ios/toolbar.m` (fill `darwin_toolbar_set_items`, `zapp_toolbar_inject_metrics`, `zapp_toolbar_unregister`; add the JSON parse, the per-window registry, the iOS icon resolver, the click emit)
- Modify: `native/platform/ios/sidebar.m` (add an exported accessor to reach `contentNav`/split-VC from a `window_ptr`, if not already reachable)

**Interfaces:**
- Consumes: the placement wire JSON (same shape macOS parses); `zapp_ios_content_webview_for_slot`, `zapp_ios_eval_js_all_webviews`, `darwin_window_get_by_numeric_id`, `darwin_sidebar_toggle`, `darwin_inspector_toggle`.
- Produces: a working content nav bar for the CORE item types; `--zapp-toolbar-height` injection; `window:toolbar-clicked` emit. T2 extends the same parse with segmented/group/menu.

- [ ] **Step 1: Read the references** — `native/platform/darwin/toolbar.m` (`zapp_toolbar_parse_items`, `zapp_toolbar_emit_click`, `zapp_toolbar_inject_metrics`), `native/platform/ios/sidebar.m` (`ZappIOSSidebarController`, `contentNav`, `zapp_ios_sidebars`, `zapp_ios_sidebar_for_slot`), `native/platform/ios/window.m` (`zapp_ios_content_webview_for_slot`, `zapp_ios_eval_js_all_webviews`, `darwin_window_get_by_numeric_id`). Confirm `darwin_sidebar_toggle`/`darwin_inspector_toggle` signatures.

- [ ] **Step 2: iOS icon resolver** — add `static UIImage* zapp_ios_resolve_icon(NSString* spec)` in `ios/toolbar.m`: `nil`/empty → nil; `"sf:NAME"` → `[UIImage systemImageNamed:NAME]`; `"data:…;base64,…"` → decode + `[UIImage imageWithData:]`; else treat as a file path → `[UIImage imageWithContentsOfFile:]`. (Parallel to the macOS `NSImage` resolver; iOS uses `UIImage`.)

- [ ] **Step 3: Reach the content nav** — in `ios/sidebar.m`, add (and declare `extern` in toolbar.m):
  ```objc
  UINavigationController* zapp_ios_content_nav_for_window(void* window_ptr) {
      NSValue* key = [NSValue valueWithPointer:window_ptr];
      return zapp_ios_sidebars[key].contentNav;  // nil for no-sidebar windows
  }
  ```
  (No-sidebar windows return nil → `set_items` becomes a safe no-op for them, matching the "deferred" decision.)

- [ ] **Step 4: `darwin_toolbar_set_items`** — on the main thread:
  1. `UINavigationController* nav = zapp_ios_content_nav_for_window(window_ptr); if (!nav) return;`
  2. Parse `toolbar_json` (NSJSONSerialization) → `items` array. Bucket each item by `placement` (default `"leading"`) into leading/center/trailing arrays of `UIBarButtonItem*` (center collects a title/titleView).
  3. For the CORE types build items:
     - `button`: `UIBarButtonItem` with `zapp_ios_resolve_icon(icon)` (image) or `label` (title); `target/action` → a handler that calls the click emit with the item `id`. Store `id`↔item in the per-window registry. `enabled` honored.
     - `toggleSidebar`: `UIBarButtonItem` (image `[UIImage systemImageNamed:@"sidebar.leading"]`) → action `darwin_sidebar_toggle(host_slot)`.
     - `toggleInspector`: `UIBarButtonItem` (image `sidebar.trailing`) → `darwin_inspector_toggle(host_slot)`.
     - `label`: if placement `center` → set `vc.navigationItem.titleView` (a `UILabel`) or `.title = text`; else a `customView` UILabel bar item.
     - `space` → `UIBarButtonItem(barButtonSystemItem: UIBarButtonSystemItemFixedSpace)`; `flexibleSpace` → `…FlexibleSpace`.
     - `trackingSeparator` → skip (dropped on iOS). Unknown/other (segmented/group/menu) → skip in T1 (T2 adds them).
  4. Assign: `vc.navigationItem.leftBarButtonItems = leading; vc.navigationItem.rightBarButtonItems = trailing;` center → `titleView`/`title`. (`vc` = `nav.topViewController`, i.e. `contentVC`.)
  5. `nav.navigationBarHidden = NO;`
  6. Call `zapp_toolbar_inject_metrics(window_ptr, host_slot, true)`.

- [ ] **Step 5: `zapp_toolbar_inject_metrics`** — mirror macOS: compute `nav.navigationBar.frame.size.height` (the shown bar height); build the JS `(function(){try{var r=document.documentElement; if(r){ r.style.setProperty('--zapp-toolbar-height','<H>px'); }}catch(e){}})();`; eval into the content webview (`zapp_ios_content_webview_for_slot(host_slot)`) via `evaluateJavaScript`, and when `add_user_script` add a `WKUserScript` (AtDocumentStart) to the content webview's `configuration.userContentController` so it survives in-webview navigations. (Sidebar/inspector panes optional in T1.)

- [ ] **Step 6: Click emit** — a helper `zapp_ios_toolbar_emit_click(int32_t numeric_id, NSString* itemId)` that builds `{"windowId":"win-<N>","id":"<itemId>"}` and calls `zapp_ios_eval_js_all_webviews` with `globalThis[Symbol.for('zapp.bridge')]._onEvent('window:toolbar-clicked', '<json>')` — match the macOS payload + the bridge `_onEvent` call exactly (read `zapp_toolbar_emit_click`). Wire each `button`'s target/action to it.

- [ ] **Step 7: `zapp_toolbar_unregister`** — clear the per-window toolbar registry entry (built items map). Keep `darwin_toolbar_attach` a no-op (iOS uses the `set_items` late-attach path).

- [ ] **Step 8: Build gates**

Run: `cd kitchen-sink && bun run build --platform ios` → expect `[zapp] build complete:`.
Run: `cd kitchen-sink && bun run build` → expect `[zapp] build complete:` (macOS unaffected).
Run: `bun run check`; `bun test cli/src`; `bun run test:native` (all pass — no TS/Nim change).

- [ ] **Step 9: Commit** (`git add native/platform/ios/toolbar.m native/platform/ios/sidebar.m`; trailer).

- [ ] **Step 10: HUMAN SMOKE GATE (RISK GATE)** — STOP for the controller/user. On iPhone + iPad, the kitchen-sink content nav bar shows the CORE items (sidebar toggle, Compose/Inbox buttons, status title, inspector toggle); the content webview is NOT overlapped by the bar (`--zapp-toolbar-height` set); tapping a button fires `window:toolbar-clicked` (visible via the existing kitchen-sink toolbar handlers); sidebar/inspector toggles work. (Segmented/group/filter-menu items are absent until T2 — expected.)

---

## Task 1.5: Collapse-aware bar delivery (iPhone launch bug + iPad duplicate toggle)

**Added after the T1 risk-gate smoke.** Two real findings surfaced (both about how the content nav bar interacts with `UISplitViewController` collapse state):
- **iPhone (the launch bug):** the native bar does NOT appear at app launch — only after a manual re-`setItems`. Root cause (confirmed in `sidebar.m`): on iPhone the split **collapses** to one column; UIKit COMBINES the two bar-hidden column nav controllers into a single `collapsedNav`, and `splitViewControllerDidCollapse:` force-sets `collapsedNav.navigationBarHidden = YES` (`sidebar.m:385`). T1's `set_items` un-hides **`contentNav`**, but in collapsed mode `contentNav` is not the displayed controller — `collapsedNav` is, and it stays hidden. (iPad never collapses → its bar showed, which is why iPad worked and iPhone didn't.)
- **iPad: duplicate sidebar toggle.** In the expanded column split, UIKit auto-provides a system sidebar button; our manual `toggleSidebar` button is then a second, redundant one.

**Decision (confirmed):** the sidebar affordance is the **system button when the split is expanded/regular** (omit our manual `toggleSidebar` there) and **our manual button when collapsed/compact** (iPhone + iPad multitasking-narrow, where no system button exists). The bar must be managed on the controller that is actually on screen, and re-applied across collapse/expand transitions.

**Files:**
- Modify: `native/platform/ios/toolbar.m` (collapse-aware target nav + re-apply hook + iPad de-dup)
- Modify: `native/platform/ios/sidebar.m` (call into toolbar re-apply on collapse/expand; expose the collapsed/displayed nav + collapse state)

**Interfaces:**
- Consumes: the T1 registry (`ZappIOSToolbarEntry` storing built items per window), `zapp_ios_collapsed_nav`, the `ZappIOSSidebarController` collapse delegate (`splitViewControllerDidCollapse:` / `DidExpand:`), `darwin_sidebar_toggle`.
- Produces: a re-apply entry point (e.g. `zapp_ios_toolbar_reapply_for_window(void* window_ptr)`) that sidebar.m calls on collapse/expand so the bar survives the transition.

- [ ] **Step 1: Root-cause (systematic-debugging, no fix yet).** Read `native/platform/ios/sidebar.m` collapse/expand handling (`splitViewControllerDidCollapse:`/`DidExpand:`, `zapp_ios_collapsed_nav`, `topColumnForCollapsingToProposedTopColumn`, `collapsedNav`/`contentNav`/`sidebarNav`) and the T1 `darwin_toolbar_set_items`. Confirm in the report: (a) which nav controller is on screen in collapsed vs expanded, (b) why the startup `set_items` bar is hidden on collapsed iPhone, (c) why a later manual `set_items` ("Attach") appears to work (timing/registry/collapse-settled), (d) how the iPad system sidebar button is auto-added. Write the confirmed mechanism before changing code.

- [ ] **Step 2: Collapse-aware bar target + re-apply.** Make `set_items` (and a new `zapp_ios_toolbar_reapply_for_window`) show the bar on the controller that is actually displayed: when the split is **collapsed**, target `collapsedNav` (show its bar only when the content VC is the visible/top VC; keep it hidden when the sidebar root is shown — this also fixes the empty-gap); when **expanded**, target `contentNav` as today. Store the built items on the registry entry so the bar can be rebuilt/re-shown without the app re-calling `setItems`.

- [ ] **Step 3: Re-apply on collapse/expand.** In `sidebar.m`'s `splitViewControllerDidCollapse:` and `splitViewControllerDidExpand:`, after the existing logic, call `zapp_ios_toolbar_reapply_for_window` for that window so a set toolbar survives the transition (and the collapse handler no longer blanket-hides a bar that has items). Use a `UINavigationControllerDelegate` (`willShowViewController:`) on the collapsed/content nav to toggle the bar per visible VC (content → shown, sidebar root → hidden).

- [ ] **Step 4: iPad de-dup.** When building the leading bucket: include the `toggleSidebar` item as our manual `UIBarButtonItem` ONLY when the split is collapsed/compact; when expanded/regular, omit it and rely on the system sidebar button (which already drives the column and fires our displayMode-change delegate → the sidebar-visibility event still flows). Re-evaluate this on collapse/expand via the re-apply hook.

- [ ] **Step 5: Build gates** — `cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`; `cd kitchen-sink && bun run build` → `[zapp] build complete:` (macOS untouched); `bun run check`; `bun test cli/src`; `bun run test:native`.

- [ ] **Step 6: Commit** (`git add native/platform/ios/toolbar.m native/platform/ios/sidebar.m`; trailer).

- [ ] **Step 7: HUMAN SMOKE GATE (re-smoke).** STOP for the controller/user. iPhone: the native bar shows the core items **at launch** (no manual attach needed); no empty toolbar gap above the sidebar list; toggles + clicks work. iPad: a **single** sidebar toggle (no duplicate); the bar persists across rotation / multitasking collapse→expand. macOS unchanged.

---

## Task 2: Breadth — segmented, group, menu + update/remove

**Files:**
- Modify: `native/platform/ios/toolbar.m`

**Interfaces:**
- Consumes: T1's parse/registry/emit. Extends the per-item build + adds `update_item`/`remove`.

- [ ] **Step 1: `segmented`** — build a `UISegmentedControl` (segments from the JSON `segments[]`: title or `zapp_ios_resolve_icon(icon)`), wrap in `UIBarButtonItem(customView:)`. Map `selectionMode` (`one`→`momentary=NO` single-select; `momentary`→`momentary=YES`; `any`→ not natively supported, approximate single-select + note). On `valueChanged`, emit `window:toolbar-group-selected` `{"windowId","id","index","selected"}` (mirror macOS payload). Apply initial `selected`.

- [ ] **Step 2: `group`** — flatten the group's `items[]` into individual `UIBarButtonItem`s appended to the same placement bucket (iOS nav bars have no `NSToolbarItemGroup`); each sub-button wires the click emit by its `id`.

- [ ] **Step 3: `button.menu`** — when a `button` has `menu[]`, build a `UIMenu` (`UIAction`s from the menu items; nested submenus → nested `UIMenu`) and set `barButtonItem.menu = …` (iOS 14+). Menu-item taps emit the existing menu-click event (mirror how macOS routes `NSMenuToolbarItem` selections — read the macOS path).

- [ ] **Step 4: `darwin_toolbar_update_item`** — parse `item_json` (`{id, …patch}`), find the item in the per-window registry by `id`, apply the patch (label/icon/enabled/badge-ignored/selected for segmented). Unknown id → no-op (match macOS).

- [ ] **Step 5: `darwin_toolbar_remove`** — hide the bar (`nav.navigationBarHidden = YES`), clear `navigationItem` items, drop the registry entry, re-inject `--zapp-toolbar-height: 0`.

- [ ] **Step 6: graceful degradation** — confirm `trackingSeparator` is skipped and `badge`/`style:prominent`/`controlRepresentation` are ignored without crashing (they appear in the kitchen-sink JSON).

- [ ] **Step 7: Build gates** (iOS + macOS builds; `bun run check`; `bun test cli/src`; `bun run test:native`).

- [ ] **Step 8: Commit** (`git add native/platform/ios/toolbar.m`; trailer).

---

## Task 3: Kitchen-sink migration + docs

**Files:**
- Modify: `kitchen-sink/src/shell/main-pane.ts` (remove the `ks-ios-topbar` HTML header + its button wiring)
- Modify: `kitchen-sink/src/style.css` (remove the now-dead `.ks-ios-topbar*` rules)
- Modify: `docs/api-reference.md` (document the iOS toolbar)

**Interfaces:**
- Consumes: the native toolbar from T1+T2 (the existing `shellToolbar()` `setItems` call now renders natively on iOS).

- [ ] **Step 1: Remove the HTML top-bar** — in `main-pane.ts`, delete the `iosTopBar` header string (lines ~11–18) and its insertion, and the `[data-sidebar-toggle]`/`[data-inspector-toggle]` click wiring (~37–43) — the native `toggleSidebar`/`toggleInspector` bar items now handle it. Leave the unconditional `Window.current().toolbar.setItems(shellToolbar())` call (it now renders natively on iOS).

- [ ] **Step 2: Remove dead CSS** — drop the `.ks-ios-topbar` / `-inner` / `-menu` / `-title` / `-inspector` rules from `style.css`.

- [ ] **Step 3: Docs** — in `docs/api-reference.md`, in the Toolbar section, add an "iOS" subsection: placement → content nav bar (`leading`→leftBarButtonItems, `center`→title/titleView, `trailing`→rightBarButtonItems); `toggleSidebar`/`toggleInspector` → bar buttons; segmented→UISegmentedControl, group→flattened, button.menu→UIMenu; `trackingSeparator` dropped on iOS; `badge`/`prominent` ignored on the nav bar; native toolbar renders when `setItems` is called (no flag); **no-sidebar windows + create-time `WindowOptions.toolbar` on iOS are follow-ups**.

- [ ] **Step 4: Full gates** — `bun run check`; `bun test cli/src`; `bun run test:native`; iOS compile; macOS build (all green / `[zapp] build complete:`).

- [ ] **Step 5: Commit** (`git add kitchen-sink/src/shell/main-pane.ts kitchen-sink/src/style.css docs/api-reference.md`; trailer).

- [ ] **Step 6: FINAL HUMAN SMOKE GATE** — STOP for the controller/user. iPhone + iPad: the **full** kitchen-sink toolbar renders natively (sidebar toggle, Compose/Inbox, the nav group + view/format segmented controls, the Filter pull-down menu, status title, inspector toggle); the old HTML `☰`/title/`⊟` top-bar is gone; toggles + clicks + segmented selection + the filter menu all work; no webview overlap. macOS unchanged (parity).

---

## Self-Review

**Spec coverage:** core items + nav bar + metrics + click emit + icon resolver (T1); segmented/group/menu + update/remove + degradation (T2); kitchen-sink HTML-top-bar removal + docs (T3). toggleSidebar/Inspector manual mapping, no-sidebar deferred, on-`setItems`, trackingSeparator-dropped — all in Global Constraints + tasks. Risk-gate-first (T1 ends in the intrusion/render smoke). All spec sections covered.

**Placeholder scan:** native ObjC steps reference the exact macOS functions to mirror + the exact iOS APIs/signatures/event payloads + the reach helpers (from exploration) rather than transcribing invented ObjC — appropriate for a port; each step is a concrete, decidable action. No "TBD"/"handle edge cases".

**Type/name consistency:** event names (`window:toolbar-clicked`, `window:toolbar-group-selected`) + payload shape match macOS; reach helpers (`zapp_ios_sidebar_for_slot`/new `zapp_ios_content_nav_for_window`, `zapp_ios_content_webview_for_slot`, `zapp_ios_eval_js_all_webviews`) match the exploration; `--zapp-toolbar-height` var name matches macOS + the runtime.
