# Per-Pane Toolbars + Presentation Coupling Implementation Plan (#782 / #781 / #783)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the sidebar and inspector panes their own native navigation bars (title + toolbar items), config-implied, on a per-VC `viewWillAppear` visibility foundation that also fixes the #784 residuals and #783 single-window swipe-back; plus fix #781 (tile presentation reshowing a collapsed inspector).

**Architecture:** One foundation refactor moves nav-bar VISIBILITY ownership from the `ZappRouteNavDelegate` (willShow/didShow) to each view controller's `viewWillAppear`/`viewWillDisappear` (the native UIKit idiom, spike-proven — the delegate keeps owning toolbar ITEMS and the pop gesture). On that foundation, per-pane chrome is authored as `sidebar:{title?,toolbar?}` / `inspector:{title?,toolbar?}` sugar that desugars into the ONE window toolbar def with items tagged `pane:"sidebar"|"inspector"`; iOS stamps them onto the existing sidebar/inspector column navs, macOS orders them into the sidebar region via the existing `NSTrackingSeparatorToolbarItem` mechanism (zero darwin/toolbar.m change).

**Tech Stack:** TypeScript (runtime/), Nim (native/nim/), Objective-C (native/platform/ios/ + darwin/), Bun test runner, kitchen-sink demo app.

## Global Constraints

- Branch `feat/nim-native`, banked in place — NO worktree, NO `git commit --amend`, NO merge without explicit ask.
- Per-file `git add` ONLY. Pre-existing unrelated WIP (assets/*, spikes/* except this cycle's, benchmarks/*, vendor/bare, untracked) stays UNSTAGED and must survive every commit.
- Commit trailer EXACTLY these two lines (verify against `git log -1 --format=%B` before committing):
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01DZ9M515fEUqt9EE2oFDyyv
  ```
- Always Bun, never Node.
- macOS must NOT regress: darwin/* changes are limited to the `normalizeToolbar` ORDERING consumption in T2/T5 — **NO darwin/toolbar.m changes**. macOS build verified per native task.
- NO iOS-simulator interaction in-session — the human runs every smoke. "Build complete" = `[zapp] build complete:` line + fresh binary mtime.
- iOS parity gate `bun test cli/src/ios-platform-parity.test.ts` stays green.
- iOS build: `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios-simulator`. macOS build: `cd /Users/zach/code/zapp/kitchen-sink && bun run build`. Type/test: `bun run check`, `bun test runtime/`.
- TDD required for T2 and T3.
- Web-canvas tenet (memory `feedback_web_canvas_default_native_optin`): panes are bar-less by default; providing `title`/`toolbar` config IS the opt-in. Never a boolean flag.

---

## Ground Truth (exploration @ `280e6a2`, referenced by tasks — file:line)

**Pane VC class (T1, T4):** `ZappIOSPaneViewController` (`native/platform/ios/window.m:387-478`) hosts all three panes via `paneRole` property (0=content, 1=sidebar, 3=inspector). Existing overrides: `viewSafeAreaInsetsDidChange`, `viewDidAppear:`, `viewWillTransitionToSize:`, `viewDidLayoutSubviews`. **No `viewWillAppear`/`viewWillDisappear`.** Uses `windowPtr` (all panes wired) — sidebar VC has `hostSlot=−1` deliberately (`window.m:1042-1054`), so the override must use `windowPtr`, not hostSlot. `ZappRouteVC` (`routing.m:101-155`) — distinct class, has `navbarHidden`, no `viewWillAppear`. Plain no-split window (`ZappIOSRootViewController`, `window.m:484-492`) is NOT nav-wrapped — bar ownership vacuous, set_items no-ops (`toolbar.m:988-992`).

**Navs (T1, T4):** iPad `sbNav` bar-hidden (`sidebar.m:906-907`) + `ctNav` bar-visible (`:908-914`); iPhone combined via `zapp_ios_collapsed_nav` (`:405-414`), captured `c.collapsedNav` at didCollapse (`:693-701`); persistent `inspectorNav` (`window.m:1245-1246`), iOS-26 Inspector column (`:1291-1295`), inspector's bar already renders Close (`inspector.m:316-336`).

**7 visibility-writer sites to retire (T1):**
1. `zapp_ios_sidebar_apply_collapsed_bar` (`sidebar.m:463-488`) — IMPURE: also stamps items `:487` (`if (showBar) zapp_ios_toolbar_stamp_vc(win, effectiveVC);`). Call sites `sidebar.m:1165` (show_content), `:1206` (show_sidebar).
2. didShow re-assert (`routing.m:442-446`).
3. didCollapse priming (`sidebar.m:725` only: `[nav setNavigationBarHidden:!toolbarRegistered animated:NO];`).
4. willShow write (`routing.m:333-346`) — IMPURE: metrics re-inject nested at `:339-345` (`dispatch_async → zapp_toolbar_inject_metrics(capturedWin, capturedSlot, false)`).
5. setItems attach primer (`toolbar.m:1071-1078`).
6. remove() hide primers (`toolbar.m:1479-1482` collapsed, `:1512-1515` expanded) — the `--zapp-toolbar-height:0` inline JS (`:1523-1564`) is justified BY the primer; re-sequence its comment/logic.
7. construction primers (`sidebar.m:907/914`, `window.m:977`).

**KEEP in delegate (T1):** item stamping (willShow `routing.m:361`, didShow force-restamp `:461-462`), pop-gesture ownership, depth reconciliation (`routing.m:370-393`), drop-webview retarget (`:464-470`), and the iOS-26 gesture toggle `routing.m:457-459` (`nav.interactiveContentPopGestureRecognizer.enabled = shownRouteWantsBarHidden`) — STAYS in didShow (I1 invariant: `.enabled` written only at settled moments; toggling mid-transition cancels an in-flight pop).

**Want-state rule (T1, T4):** `zapp_route_bar_want_state` (`routing.m:239-251`) + wrapper `zapp_route_bar_should_show(win, vc, contentVC)` (`:258-260`). REUSE — do not reimplement. Sidebar VC's want-state must become "hidden unless the sidebar pane has title/toolbar configured" (config-implied); content VC keeps existing rule; inspector VC keeps its rule.

**Spike reference (T1):** `spikes/ios-splitview-reference/src/DetailViewController.m:206-252` — `viewWillAppear` hides bar; `viewWillDisappear` uses `transitionCoordinator animateAlongsideTransition:` with `completion:` checking `ctx.isCancelled` — port this exact pattern to `ZappRouteVC` for coordinator-coupled cancelled-swipe roll-back.

**#783 guard (T1):** `zapp_ios_route_install_nav_delegate` (`routing.m:545-548`): `if (!nav || windowId <= 0) return;`. Main window is id 0 → sidebar rearm (`sidebar.m:435-436`) + didCollapse install (`:707-708`) silently no-op for win-0. Fix: allow install for id 0 (change to `< 0`, or key off resolved window) so single-window swipe-back works; the per-VC visibility refactor already removes the visibility half of this asymmetry.

**Config surface (T2, T3):** `SidebarOptions` (`runtime/window.ts:244-285`; Nim `window.nim:126-137`), `InspectorOptions` (`window.ts:294-317`; Nim `:139-149`) — NO toolbar/title today. Window toolbar travels create-time as `toolbarJson` string (`window.ts:1893-1903` → Nim `parseToolbarJson`/`serializeToolbar` `window.nim:592-595`, `ToolbarItemOpt` `:103-124`). Sidebar/inspector travel as SCALAR accessors `wopts_sidebar_*` (`window.nim:274-296`) into the deferred struct → `zapp_ios_sidebar_register` (`window.m:1066-1074`) / `zapp_ios_inspector_register` (`window.m:1301-1308`). New string accessor follows `toolbarJsonCache` pin pattern (`window.nim:193-194`).

**normalizeToolbar seam (T2, T5):** `applyToolbarConventions` (`window.ts:907-943`) is THE placement point — returns `[...prefix, ...rest, ...suffix]` (`:942`) where prefix=`[flexibleSpace, toggleSidebar, trackingSeparator(sidebar)]`, suffix=`[trackingSeparator(inspector), toggleInspector]`. Called from `normalizeToolbar` (`:947-1117`, params `windowId?` `:955`, `url?` `:956`). Existing pane-scoped wire key: `trackingSeparator.pane` (`:1004-1013`; Nim `:106`, serialize `:450`; darwin consume `darwin/toolbar.m:523-530`).

**macOS mechanism (T5):** `zapp_toolbar_parse_items` buckets by placement (`darwin/toolbar.m:500-560`), maps trackingSeparator+pane to `kZappTrackingSeparatorId`/`...InspectorId` (`:523-530`), concatenates `leading|flexSpace|center|flexSpace|trailing` (`:561-574`); `NSTrackingSeparatorToolbarItem` (`:247-250`) makes items ordered before the sidebar separator render over the sidebar — already works, no darwin change needed, only `applyToolbarConventions` ordering.

**#781 (T6):** `zapp_ios_apply_presentation` (`sidebar.m:172-202`) sets split-GLOBAL `preferredSplitBehavior`/`preferredDisplayMode` + `showColumn:Primary`; called from register (`:942`), rotation/trait (`:637/645/665`), toggle-expand (`:1270`), explicit set (`:1443-1455`). Inspector collapsed truth: `[split isShowingColumn:UISplitViewControllerColumnInspector]` (`inspector.m:613`); `lastCollapsedEmit` dedupe (`:116`); didHide dedupe-silence (`:369`). No per-column displayMode/behavior API exists — presentation is split-global by UIKit design.

---

## File Structure

- `native/platform/ios/window.m` — `ZappIOSPaneViewController` gains `viewWillAppear`/`viewWillDisappear` (T1); pane register passes title/toolbar (T4).
- `native/platform/ios/routing.m` — `ZappRouteVC` gains viewWillAppear/viewWillDisappear (T1); delete willShow/didShow visibility writes, keep items+gesture (T1); #783 guard (T1).
- `native/platform/ios/sidebar.m` — delete `apply_collapsed_bar` + its calls + didCollapse priming + construction primers, re-home stamp (T1); #781 apply_presentation wrapper (T6).
- `native/platform/ios/toolbar.m` — delete setItems/remove primers, re-sequence height JS (T1); iOS pane stamping onto column navs (T4).
- `native/platform/ios/inspector.m` — pane register title/items (T4); #781 collapsed-state read/restore helper (T6).
- `runtime/window.ts` — SidebarOptions/InspectorOptions +title/+toolbar; normalizeToolbar pane bucketing; setTitle handles (T2, T5).
- `runtime/window.test.ts` — pane bucketing round-trip tests (T2).
- `native/nim/window.nim` — Nim SidebarOptions/InspectorOptions +title/+toolbarJson, accessors, parse (T3).
- `native/nim/tests/` — Nim serialize/parse parity test (T3).
- `darwin/toolbar.m` — UNCHANGED (macOS ordering is normalizeToolbar-only).
- `docs/api-reference.md`, `kitchen-sink/zapp/app.nim` + `kitchen-sink/src/shell/*` — demo + docs (T7).

---

### Task 1: Per-VC visibility FOUNDATION (RISK GATE — Opus-implemented)

**This is the go/no-go task. It is investigation-shaped (surgical deletes across 7 sites, 2 impure) and is implemented by the orchestrator (Opus 4.8) directly, not a Sonnet subagent.** It ends at human gate G1.

**Files:**
- Modify: `native/platform/ios/window.m` (`ZappIOSPaneViewController`), `native/platform/ios/routing.m` (`ZappRouteVC`, delegate), `native/platform/ios/sidebar.m` (delete apply_collapsed_bar + primers), `native/platform/ios/toolbar.m` (delete setItems/remove primers)

**Interfaces:**
- Produces: `ZappIOSPaneViewController`/`ZappRouteVC` own their bar-hidden via viewWillAppear reading `zapp_route_bar_want_state`; the delegate no longer writes `navigationBarHidden` anywhere. Sidebar want-state = "hidden unless pane configured" — but T1 ships with panes UNconfigured (no title/toolbar wired yet), so sidebar stays bar-less exactly as today. T4 later makes it show when configured.
- Consumes: `zapp_route_bar_should_show` (`routing.m:258`), `zapp_ios_toolbar_stamp_vc` (`toolbar.m`), `zapp_toolbar_inject_metrics` (`toolbar.m`).

- [ ] **Step 1: `ZappIOSPaneViewController` viewWillAppear/viewWillDisappear** (window.m). One override branched on `paneRole`. Content (0): `[self.navigationController setNavigationBarHidden:!zapp_route_bar_should_show(self.windowPtr, self, self) animated:animated]` — content is its own contentVC. Sidebar (1): hidden (T1 baseline — want-state returns NO with no config). Inspector (3): keep its current rule. On a visibility change, fire the re-homed metrics inject (`dispatch_async` → `zapp_toolbar_inject_metrics(windowPtr, slot, false)`).
- [ ] **Step 2: `ZappRouteVC` viewWillAppear/viewWillDisappear** (routing.m), porting `DetailViewController.m:206-252`: viewWillAppear sets `setNavigationBarHidden:navbarHidden animated:` (or want-state); viewWillDisappear uses `transitionCoordinator animateAlongsideTransition:^{ [nav setNavigationBarHidden:!navbarHidden animated:YES]; } completion:^(ctx){ if (ctx.isCancelled) [nav setNavigationBarHidden:navbarHidden animated:NO]; }` for the interactive case, else a plain set.
- [ ] **Step 3: Delete the 7 visibility writes.** Sidebar `apply_collapsed_bar` (`sidebar.m:463-488`) — re-home its stamp (`:487`) to the delegate's willShow/didShow stamp path, delete the function + both call sites (`:1165`, `:1206`). didShow re-assert (`routing.m:442-446`) — delete, keep the rest of didShow incl. the iOS-26 gesture toggle (`:457-459`) UNCHANGED. didCollapse priming (`sidebar.m:725`) — delete the one line, keep the enclosing method. willShow write (`routing.m:333-346`) — delete visibility, re-home metrics inject to Step 1's VC path, keep item stamp (`:361`). setItems primer (`toolbar.m:1071-1078`) — delete. remove() primers (`toolbar.m:1479-1482`, `:1512-1515`) — delete, re-sequence the `--zapp-toolbar-height:0` JS comment (bar visibility is now VC-owned). construction primers (`sidebar.m:907/914`, `window.m:977`) — delete.
- [ ] **Step 4: #783 guard.** `routing.m:545-548`: allow delegate install for window id 0 so single-window swipe-back works (change `<= 0` to `< 0`, confirm no negative-id caller depends on the old skip; the visibility half is already handled by viewWillAppear).
- [ ] **Step 5: Gates.** iOS-sim build (`[zapp] build complete:` + fresh mtime), macOS build, parity test, `bun run check`. Commit (per-file add of the 4 .m files).
- [ ] **Step 6: GATE G1 (human, iPhone + iPad).** Re-run the #771 G2 matrix (per-route chrome title/toolbar/navbarHidden, hidden-navbar swipe-back + cancel, iPad edge-pins + rotation + divider drag with a route up, toolbar transitions) — the foundation must HOLD the line. PLUS #784 residuals now pass (return-to-sidebar bar-less; cancelled swipe animates out). PLUS #783 single-window launch swipe-back (sidebar↔content edge-swipe works before any push). **A red G1 stops the cycle.**

---

### Task 2: Pane wire generalization + normalizeToolbar bucketing (TDD — Sonnet)

**Files:**
- Modify: `runtime/window.ts` (SidebarOptions/InspectorOptions types + `applyToolbarConventions` + `normalizeToolbar` + desugar)
- Test: `runtime/window.test.ts`

**Interfaces:**
- Produces: `SidebarOptions.title?: string`, `SidebarOptions.toolbar?: ToolbarOptions` (+ inspector symmetric). A `pane?: "sidebar" | "inspector"` field on every normalized toolbar item wire dict (generalized from trackingSeparator's existing `pane`). `normalizeToolbar` accepts pane-tagged items and `applyToolbarConventions` orders pane-tagged items into their pane region; untagged items stay in the content region exactly as today.
- Consumes: existing `normalizeToolbar(opts, hasSidebar, hasInspector, windowId?, url?)` shape.

- [ ] **Step 1: Failing test — pane bucketing.** In `runtime/window.test.ts`:
```ts
test("sidebar-tagged items order into the sidebar region, untagged stay in content", () => {
  const out = normalizeToolbar(
    { items: [
      { id: "s1", label: "New", pane: "sidebar" },
      { id: "c1", label: "Share" },
      { id: "i1", label: "Info", pane: "inspector" },
    ] },
    /*hasSidebar*/ true, /*hasInspector*/ true, /*windowId*/ 0,
  );
  const ids = out.items.map(i => i.id);
  // sidebar item sits before the sidebar trackingSeparator; content in the middle; inspector after its separator
  expect(ids.indexOf("s1")).toBeLessThan(ids.indexOf("__tracking_sidebar"));
  expect(ids.indexOf("c1")).toBeGreaterThan(ids.indexOf("__tracking_sidebar"));
  expect(ids.indexOf("c1")).toBeLessThan(ids.indexOf("__tracking_inspector"));
  expect(ids.indexOf("i1")).toBeGreaterThan(ids.indexOf("__tracking_inspector"));
});
```
(Use the actual tracking-separator ids from `applyToolbarConventions`; the implementer verifies the exact id strings at `window.ts:907-943`.)
- [ ] **Step 2: Run to verify it fails.** `bun test runtime/window.test.ts -t "sidebar-tagged"` → FAIL (pane items not bucketed).
- [ ] **Step 3: Implement pane bucketing** in `applyToolbarConventions`: partition `rest` into `sidebarItems` (pane==="sidebar"), `inspectorItems` (pane==="inspector"), `contentItems` (untagged); return `[...sidebarPrefix(sidebarItems), toggleSidebar, trackingSep(sidebar), ...contentItems, trackingSep(inspector), ...inspectorItems, toggleInspector]` (exact anchor order per the existing prefix/suffix). Add `pane` passthrough on the item wire dict (mirror the trackingSeparator `pane` handling).
- [ ] **Step 4: Desugar test.** Test that `sidebar:{title,toolbar:{items}}` merges its items with `pane:"sidebar"` into the single normalized def (title carried separately as a pane-title field). Implement the desugar in the window-create normalize path.
- [ ] **Step 5: Run all runtime tests.** `bun test runtime/` → PASS; `bun run check` clean.
- [ ] **Step 6: Commit** (per-file add of `runtime/window.ts` + `runtime/window.test.ts`).

---

### Task 3: Nim SidebarOptions/InspectorOptions title + toolbarJson (parity-tested — Sonnet)

**Files:**
- Modify: `native/nim/window.nim` (SidebarOptions/InspectorOptions fields, accessors, `windowOptsApplyJson` parse)
- Test: existing Nim test harness under `native/nim/tests/` (serialize/parse parity)

**Interfaces:**
- Produces: Nim `SidebarOptions.title: string`, `SidebarOptions.toolbarJson: string` (+ inspector); C-ABI accessors `wopts_sidebar_title`, `wopts_sidebar_toolbar_json`, `wopts_inspector_title`, `wopts_inspector_toolbar_json` (cstring, pinned via the `toolbarJsonCache` pattern at `window.nim:193-194`); `windowOptsApplyJson` parses `sidebar.title`/`sidebar.toolbar` (+inspector) from the window-config JSON T2 produces.
- Consumes: the window-config JSON shape T2's desugar emits.

- [ ] **Step 1: Failing parity test** — round-trip a WindowOptions with `sidebar:{title:"Files", toolbar:{items:[{id:"new"}]}}` through serialize→parse, assert `wopts_sidebar_title == "Files"` and the toolbar JSON round-trips.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Add fields + accessors + parse** (window.nim), following the existing scalar-accessor + `toolbarJsonCache` pinning pattern.
- [ ] **Step 4: Run Nim test → PASS; `bun run check` clean; parity gate green.**
- [ ] **Step 5: Commit** (per-file add of `native/nim/window.nim` + the test).

---

### Task 4: iOS pane stamping + toggle cooperation (native — Sonnet, brief carries targeting)

**Files:**
- Modify: `native/platform/ios/window.m` (pane register passes title/toolbar), `native/platform/ios/sidebar.m` (`zapp_ios_sidebar_register` stamps sidebar nav navigationItem), `native/platform/ios/inspector.m` (inspector nav), `native/platform/ios/toolbar.m` (pane-item stamp helper)

**Interfaces:**
- Consumes: T3 accessors (`wopts_sidebar_title`/`_toolbar_json`, inspector), T1's `viewWillAppear` (shows the bar iff want-state says so), the existing per-nav `navigationItem` on `sbNav`/`inspectorNav`.
- Produces: the sidebar/inspector column navs render their configured title + items; sidebar want-state now returns "show" when the pane has title/toolbar (config-implied) — wire this into `zapp_route_bar_want_state`'s sidebar branch.

- [ ] **Step 1:** thread `wopts_sidebar_title`/`_toolbar_json` (+inspector) from window.m into `zapp_ios_sidebar_register`/`zapp_ios_inspector_register`.
- [ ] **Step 2:** stamp the pane title (`nav.topViewController.navigationItem.title`) + pane-tagged items onto the sidebar/inspector column nav's `navigationItem` (reuse the toolbar entry builder; the items arrive pane-tagged in the window toolbar def).
- [ ] **Step 3:** make the sidebar branch of `zapp_route_bar_want_state` return show=YES when the sidebar pane has title or items (config-implied). viewWillAppear (T1) then reveals the bar automatically.
- [ ] **Step 4:** verify toggle placement cooperates with the split-VC's native display-mode button (sidebar-toggle in the sidebar bar when expanded; migrates to content when collapsed) — this is UIKit-native once the sidebar owns a bar; confirm no manual toggle-placement fight remains.
- [ ] **Step 5:** gates (iOS-sim + macOS build, parity, check). Commit per-file.

---

### Task 5: macOS sidebar-region ordering + setTitle runtime (Sonnet)

**Files:**
- Modify: `runtime/window.ts` (`win.sidebar.setTitle`/`win.inspector.setTitle` handles; confirm macOS ordering falls out of T2's `applyToolbarConventions`)

**Interfaces:**
- Produces: `SidebarHandle.setTitle(s: string): void`, `InspectorHandle.setTitle(s: string): void` (one action each → `windowAction`). macOS renders pane-tagged items in the sidebar region via the existing trackingSeparator mechanism (T2's ordering; ZERO darwin/toolbar.m). macOS `title` = documented no-op (apps own the sidebar header in HTML).
- Consumes: T2's pane bucketing (already orders items correctly for macOS's identifier-array mechanism), the existing `windowAction` bridge.

- [ ] **Step 1:** add `setTitle` to SidebarHandle/InspectorHandle → `windowAction("sidebar:setTitle", {windowId, title})` (+inspector); native routes to the pane nav's `navigationItem.title` on iOS (no-op on macOS).
- [ ] **Step 2:** verify macOS build renders pane-tagged items in the sidebar region with NO darwin/toolbar.m change (T2's ordering + existing NSTrackingSeparatorToolbarItem). Confirm `git diff darwin/toolbar.m` is empty.
- [ ] **Step 3:** gates (macOS build + iOS-sim build + check). Commit per-file.

---

### Task 6: #781 inspector-presentation preservation (Sonnet)

**Files:**
- Modify: `native/platform/ios/sidebar.m` (`zapp_ios_apply_presentation` wrapper), `native/platform/ios/inspector.m` (collapsed-state read/restore helper)

**Interfaces:**
- Produces: `zapp_ios_apply_presentation` captures `isShowingColumn:UISplitViewControllerColumnInspector` before the display-mode write and re-`hideColumn:` after if it was collapsed; covers all 5 call sites (register, rotation ×3, toggle-expand, explicit set). The didHide dedupe (`inspector.m:369`) keeps the corrective re-hide emit-silent.
- Consumes: `[split isShowingColumn:...Inspector]` (`inspector.m:613`), `hideColumn:`.

- [ ] **Step 1:** add an inspector helper `BOOL zapp_ios_inspector_is_collapsed(UIWindow*)` reading the live `isShowingColumn:Inspector` (26+), and a `zapp_ios_inspector_restore_collapsed(UIWindow*, BOOL wasCollapsed)` that re-`hideColumn:` when `wasCollapsed`.
- [ ] **Step 2:** in `zapp_ios_apply_presentation` (`sidebar.m:172-202`): capture `wasCollapsed` before the `UIView animate` block, restore after `layoutIfNeeded`/`showColumn:Primary`, availability-guarded (26+).
- [ ] **Step 3:** gates (iOS-sim + macOS build, parity, check). Commit per-file.

---

### Task 7: Kitchen-sink demo + docs + GATE G2 (Sonnet)

**Files:**
- Modify: `kitchen-sink/zapp/app.nim` (sidebar `title` + a toolbar item; inspector `title`), `kitchen-sink/src/shell/*` if a handler is needed, `docs/api-reference.md`

**Interfaces:**
- Consumes: everything T2–T6.
- Produces: a smokable demo of a titled sidebar with a toolbar item + a titled inspector; docs covering `SidebarOptions`/`InspectorOptions` `title`/`toolbar`, the web-canvas config-implied tenet, macOS `title` no-op, and split-global presentation.

- [ ] **Step 1:** kitchen-sink sidebar gets `title:"Kitchen Sink"` + a leading toolbar item (e.g. a compose/`sf:square.and.pencil`); inspector gets `title:"Inspector"`. TS-only / Nim config-only.
- [ ] **Step 2:** docs — `api-reference.md` SidebarOptions/InspectorOptions `title`/`toolbar`, the tenet (bar-less default, config = opt-in), macOS title no-op, `preferredSplitBehavior`/`preferredDisplayMode` split-global (sidebar overlay carries inspector by design; #781 preserves collapsed state across it).
- [ ] **Step 3:** gates (iOS-sim + macOS build, parity, check).
- [ ] **Step 4: GATE G2 (human, combined iPhone + iPad + macOS):** sidebar/inspector own populated bars + titles on iPad; toggle placement correct; #771 routing regression clean; macOS renders sidebar-region items with zero darwin/toolbar.m change; #781 — collapse the inspector then rotate → stays collapsed.

---

## Self-Review

**Spec coverage:** Phase 1 (per-VC foundation + #783 + #784) → T1. Phase 2 (per-pane chrome: authoring T2, wire T3, iOS T4, macOS+setTitle T5) → T2–T5. Phase 3 (#781 T6, demo+docs+G2 T7) → T6–T7. Web-canvas tenet → T4 (config-implied want-state) + T7 docs. All spec sections mapped.

**Placeholder scan:** native tasks (T4/T6) describe exact sites + mechanism rather than full ObjC line-by-line — acceptable because the per-task brief (generated via `task-brief` at execution) carries the Ground Truth file:line block, and the reviewer (Opus) checks against it; the TDD tasks (T2/T3) carry real test code. No TBD/TODO.

**Type consistency:** `pane: "sidebar"|"inspector"` used identically in T2 (TS wire), T3 (Nim toolbarJson passthrough — `pane` already serialized at `window.nim:450`), T4 (native bucket read). `zapp_route_bar_should_show`/`zapp_route_bar_want_state` referenced consistently T1/T4. `wopts_sidebar_title`/`_toolbar_json` consistent T3→T4.

**Risk sequencing:** T1 is the human-gated go/no-go; T2/T3 are pure TS/Nim (no native risk); T4 is the one native feature task (the Sonnet-on-native read); T6 is a contained wrapper. Correct ordering — the foundation proves out before any feature rides it.
