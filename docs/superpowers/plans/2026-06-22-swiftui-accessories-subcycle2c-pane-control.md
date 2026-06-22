# SwiftUI Accessories Sub-cycle 2c — Pane Control Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the SwiftUI pane path (macOS) to parity with AppKit for sidebar/inspector **width**, **resize lock**, **collapsible**, and **presentation (tile/overlay)** — identical end-user API + result whether `native.swiftui` is on or off.

**Architecture:** Reach-through. A SwiftUI `NavigationSplitView` on macOS is backed by a real `NSSplitViewController`; Zapp hosts the panes in an `NSHostingController` (`window.contentViewController`), so we lazily resolve that embedded `NSSplitViewController` by walking the hosting controller's child VCs, populate the *existing* `ZappSidebarController`/`ZappInspectorController` `splitVC`+`item` fields, and **reuse the existing AppKit `darwin_sidebar_*`/`darwin_inspector_*` bodies**. Create-time geometry stays on the SwiftUI `.navigationSplitViewColumnWidth` modifier (PaneState-driven). Visibility (collapse/expand) stays on the proven 2a PaneState path (animated); width/resize/collapsible/presentation go through the resolved split.

**Tech Stack:** ObjC (`native/platform/darwin/{window,sidebar,inspector}.m`), Swift (`panes.swift`), the `#ifdef ZAPP_HAS_SWIFTUI` gate, Nim router (unchanged), runtime TS (unchanged — the parity point).

**Branch:** `feat/nim-native` (unmerged). **Commit trailer:** `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Spec:** `docs/superpowers/specs/2026-06-22-swiftui-accessories-subcycle2c-pane-control-design.md`. **Probe (Phase 0, done):** `spikes/swiftui-pane-control/` — PARTIAL GO.

---

## File Structure

- `native/platform/darwin/sidebar.m` — add a lazy `NSSplitViewController` resolver; replace the three `swiftPaneState` no-op early-returns (`set_width`/`set_collapsible`/`set_resizable`) with "resolve the split, run the AppKit body."
- `native/platform/darwin/inspector.m` — same for the inspector trio.
- `native/platform/darwin/window.m` — a shared recursive split-finder helper (callable from sidebar.m/inspector.m via a small extern); pass create-time geometry + presentation into PaneState; apply forced-tile (`canCollapseFromWindowResize`) when the split first resolves.
- `native/platform/darwin/swift/panes.swift` — PaneState gains create-time `sidebarWidth/min/max`, `inspectorWidth/min/max`, and a `sidebarCollapsible` flag; `.navigationSplitViewColumnWidth` reads them; conditionally `.toolbar(removing: .sidebarToggle)` when non-collapsible.
- `docs/native-ui-strategy.md` + `docs/api-reference.md` — parity matrix update + any deviations.
- `kitchen-sink/zapp/app.nim` + `kitchen-sink/src/**` — showcase configuring presentation modes (Nim + TS).

**Untouched:** `native/nim/router.nim` (sidebar:*/inspector:* arms already wired), `runtime/window.ts` (`SidebarHandle`/`InspectorHandle`/`SidebarOptions`/`InspectorOptions` — the parity surface), the AppKit path, iOS.

## Verification model

This is native + visual work (like 2a/2b): "tests" are **build gates** (`[zapp] build complete:` as the LAST line — Vite's `✓ built` is NOT success) + **human visual smoke**. Nim unit tests don't cover ObjC/SwiftUI. Build the kitchen-sink with `cd kitchen-sink && bun run ../cli/src/zapp-cli.ts build` (Nim is the default; no env flag). `native.swiftui` defaults true; `native: { swiftui: false }` in `kitchen-sink/zapp.config.ts` forces the AppKit path. **Note:** the working tree may carry an uncommitted `swiftui: false` toggle — for 2c, swiftui must be ON to exercise the SwiftUI path; flip it (and never commit either state).

---

### Task 1: RISK GATE — resolve the embedded NSSplitViewController + prove settings stick (human visual)

**Files:**
- Modify: `native/platform/darwin/window.m`
- Modify: `native/platform/darwin/sidebar.m`

This task proves the whole approach. **GO** (split found + AppKit settings hold across SwiftUI re-layout) → continue with T2+. **NO-GO** (no split, or SwiftUI clobbers) → STOP and report; the cycle falls back to the SwiftUI-native `@State` approach from the spike with documented deviations.

- [ ] **Step 1: Add a recursive split-finder helper.** In `native/platform/darwin/window.m`, near the top (after the imports / before `ZappWindowDelegate`), add a non-static finder + its extern. It walks a view controller's child VCs for an `NSSplitViewController` (SwiftUI's `NavigationSplitView` installs one as a child of the `NSHostingController`):

```objc
// Reach-through (Sub-cycle 2c): a SwiftUI NavigationSplitView on macOS is backed
// by an NSSplitViewController nested under our NSHostingController. Walk the VC
// tree to find it so the existing AppKit sidebar/inspector primitives can drive it.
NSSplitViewController* zapp_find_split_vc(NSViewController* vc) {
    if (!vc) return nil;
    if ([vc isKindOfClass:[NSSplitViewController class]]) return (NSSplitViewController*)vc;
    for (NSViewController* child in vc.childViewControllers) {
        NSSplitViewController* found = zapp_find_split_vc(child);
        if (found) return found;
    }
    return nil;
}
```

- [ ] **Step 2: Declare the extern in sidebar.m.** At the top of `native/platform/darwin/sidebar.m` (with the other externs), add:

```objc
@class NSSplitViewController;
extern NSSplitViewController* zapp_find_split_vc(NSViewController* vc);
```

- [ ] **Step 3: Temporary probe in `darwin_sidebar_set_width`.** In `sidebar.m`, replace the `swiftPaneState` no-op early-return inside `darwin_sidebar_set_width` (currently lines ~204-207) with a probe that lazily resolves the split and applies AppKit settings:

```objc
    if (c.swiftPaneState) {
        // 2c RISK GATE probe: resolve the SwiftUI-backed NSSplitViewController and
        // try to drive it with AppKit primitives. If this sticks, the reach-through works.
        void* win_ptr = darwin_window_get_by_numeric_id(window_id);
        NSWindow* win = (__bridge NSWindow*)win_ptr;
        NSSplitViewController* svc = zapp_find_split_vc(win.contentViewController);
        NSLog(@"[zapp] 2c probe: split=%@ items=%lu width=%d", svc,
              (unsigned long)svc.splitViewItems.count, width);
        if (svc.splitViewItems.count > 0) {
            NSSplitViewItem* side = svc.splitViewItems.firstObject;
            side.canCollapse = NO;
            if (@available(macOS 11.0, *)) side.canCollapseFromWindowResize = NO;
            [svc.splitView setPosition:(CGFloat)width ofDividerAtIndex:0];
        }
        return;
    }
```

- [ ] **Step 4: Build the kitchen-sink (SwiftUI ON).** Ensure `kitchen-sink/zapp.config.ts` does NOT have `native: { swiftui: false }` (remove the line if present — do not commit the change). Then:

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run ../cli/src/zapp-cli.ts build 2>&1 | tail -20`
Expected: LAST line `[zapp] build complete: …`. (If it fails to compile, fix the helper/extern and rebuild.)

- [ ] **Step 5: HUMAN VISUAL GATE — does it resolve + stick?** Run `cd /Users/zach/code/zapp/kitchen-sink && bun run ../cli/src/zapp-cli.ts dev`. Use the kitchen-sink Sidebar section's "set width" control (or any path that fires `sidebar:setWidth`). **Pause for the user to confirm:**
  1. The console logs `[zapp] 2c probe: split=<NSSplitViewController …> items=N` with N ≥ 2 (the split was FOUND).
  2. The sidebar **jumps to the set width**.
  3. The sidebar **no longer collapses** (canCollapse=NO held) — try the toggle + narrowing the window.
  4. The setting **STICKS** across navigating sections + resizing the window (not clobbered by SwiftUI re-layout — the 2b failure mode).

  **GO** = all four hold → proceed to T2. **NO-GO** = split not found OR settings get clobbered → STOP, report to the user, and switch the cycle to the SwiftUI-native fallback (spike's `@State` min/ideal/max + window min-size, with documented deviations).

- [ ] **Step 6: Commit the gate scaffolding.**

```bash
git add native/platform/darwin/window.m native/platform/darwin/sidebar.m
git commit -m "$(cat <<'EOF'
feat(darwin): 2c risk gate — reach the SwiftUI NSSplitViewController (sidebar probe)

zapp_find_split_vc walks the NSHostingController's child VCs to the
NavigationSplitView's backing NSSplitViewController; darwin_sidebar_set_width
probes it on the SwiftUI path (canCollapse=NO + setPosition) to prove the
AppKit reach-through resolves and sticks across SwiftUI re-layout.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Make width / resize / collapsible real (sidebar + inspector) via the resolved split

**Files:**
- Modify: `native/platform/darwin/sidebar.m`
- Modify: `native/platform/darwin/inspector.m`

Depends on T1 = GO. Replace the probe + the remaining no-ops with a proper lazy resolver that populates the controller's `splitVC`/`item` fields, then runs the existing AppKit bodies.

- [ ] **Step 1: Add a lazy resolver in sidebar.m.** Add a helper that fills `c.splitVC` + `c.sidebarItem` (+ `cfgMin/MaxThickness`) from the window's embedded split, once:

```objc
// Lazily bind the SwiftUI-backed split to the controller so the AppKit bodies work.
// NavigationSplitView's NSSplitViewController only exists after layout, so resolve
// on first control op rather than at create. items: [sidebar, content, (inspector?)].
static BOOL zapp_sidebar_bind_swiftui(ZappSidebarController* c) {
    if (c.splitVC && c.sidebarItem) return YES;            // already bound
    if (!c.swiftPaneState) return NO;
    void* win_ptr = darwin_window_get_by_numeric_id(c.hostWindowId);
    NSWindow* win = (__bridge NSWindow*)win_ptr;
    NSSplitViewController* svc = zapp_find_split_vc(win.contentViewController);
    if (!svc || svc.splitViewItems.count == 0) return NO;  // not laid out yet / not found
    c.splitVC = svc;
    c.sidebarItem = svc.splitViewItems.firstObject;
    if (c.cfgMinThickness <= 0) c.cfgMinThickness = c.sidebarItem.minimumThickness;
    if (c.cfgMaxThickness <= 0) c.cfgMaxThickness = c.sidebarItem.maximumThickness;
    return YES;
}
```

- [ ] **Step 2: Replace the three sidebar no-ops with resolve-then-AppKit.** In `darwin_sidebar_set_width`, `darwin_sidebar_set_collapsible`, `darwin_sidebar_set_resizable`, replace the probe/no-op block (`if (c.swiftPaneState) { … return; }`) with:

```objc
    if (c.swiftPaneState && !zapp_sidebar_bind_swiftui(c)) {
        if (getenv("ZAPP_LOG")) NSLog(@"[zapp] sidebar: SwiftUI split not resolved yet — op skipped");
        return;
    }
    // falls through to the existing AppKit body, now operating on the resolved c.splitVC/c.sidebarItem
```

(The existing AppKit bodies — `setPosition:ofDividerAtIndex:0`, `canCollapse`, min/max thickness — are unchanged; they now run on the SwiftUI path too because `c.splitVC`/`c.sidebarItem` are bound.)

- [ ] **Step 3: Inspector resolver.** In `inspector.m`, add the inspector twin (the inspector is the LAST split item; its divider is the second-to-last divider):

```objc
static BOOL zapp_inspector_bind_swiftui(ZappInspectorController* c) {
    if (c.splitVC && c.inspectorItem) return YES;
    if (!c.swiftPaneState) return NO;
    void* win_ptr = darwin_window_get_by_numeric_id(c.hostWindowId);
    NSWindow* win = (__bridge NSWindow*)win_ptr;
    NSSplitViewController* svc = zapp_find_split_vc(win.contentViewController);
    if (!svc || svc.splitViewItems.count < 2) return NO;
    c.splitVC = svc;
    c.inspectorItem = svc.splitViewItems.lastObject;
    c.inspectorDividerIndex = svc.splitViewItems.count - 2;  // divider before the last item
    if (c.cfgMinThickness <= 0) c.cfgMinThickness = c.inspectorItem.minimumThickness;
    if (c.cfgMaxThickness <= 0) c.cfgMaxThickness = c.inspectorItem.maximumThickness;
    return YES;
}
```

Add the `@class NSSplitViewController; extern NSSplitViewController* zapp_find_split_vc(NSViewController*);` extern at the top of `inspector.m` too.

- [ ] **Step 4: Replace the three inspector no-ops** in `darwin_inspector_set_width`/`set_collapsible`/`set_resizable` with:

```objc
    if (c.swiftPaneState && !zapp_inspector_bind_swiftui(c)) {
        if (getenv("ZAPP_LOG")) NSLog(@"[zapp] inspector: SwiftUI split not resolved yet — op skipped");
        return;
    }
    // falls through to the existing AppKit body (setPosition uses c.inspectorDividerIndex)
```

- [ ] **Step 5: Build.**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run ../cli/src/zapp-cli.ts build 2>&1 | tail -20`
Expected: LAST line `[zapp] build complete: …`.

- [ ] **Step 6: Commit.**

```bash
git add native/platform/darwin/sidebar.m native/platform/darwin/inspector.m
git commit -m "$(cat <<'EOF'
feat(darwin): 2c — sidebar/inspector width/resize/collapsible on the SwiftUI path

Lazily bind the SwiftUI NavigationSplitView's NSSplitViewController to the
existing ZappSidebar/InspectorController (splitVC + item), then run the existing
AppKit primitives — un-no-op'ing darwin_sidebar/inspector_set_width/collapsible/
resizable on the SwiftUI path. True parity, reusing the AppKit bodies.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Create-time geometry + presentation (tile/overlay) + collapsible toggle removal

**Files:**
- Modify: `native/platform/darwin/swift/panes.swift`
- Modify: `native/platform/darwin/window.m`
- Modify: `native/platform/darwin/sidebar.m`

- [ ] **Step 1: PaneState create-time geometry + collapsible flag (panes.swift).** Extend `PaneState` with create-time fields (read by the layout; not the reverse-event `@Published` visibility ones):

```swift
  // Create-time geometry (Sub-cycle 2c) — drives the column bounds; not reverse-fired.
  let sidebarMinW: CGFloat
  let sidebarIdealW: CGFloat
  let sidebarMaxW: CGFloat
  let sidebarCollapsible: Bool
```

Thread them through `PaneState.init` and `zapp_swift_panes_state_create` (add `sidebarMinW/idealW/maxW: Double`, `sidebarCollapsible: Bool` params; cast to CGFloat). Update the `@_cdecl` signature + the window.m call site accordingly.

- [ ] **Step 2: Apply the create-time bounds + conditional toggle removal (panes.swift).** Replace the hardcoded modifier (line 69) and add the conditional toggle removal:

```swift
      PaneHost(view: sidebar).ignoresSafeArea()
        .navigationSplitViewColumnWidth(min: state.sidebarMinW, ideal: state.sidebarIdealW, max: state.sidebarMaxW)
```

And on the `NavigationSplitView` (after `.navigationSplitViewStyle(.balanced)`), when the sidebar is non-collapsible, remove the auto toggle so there's no dead button (Messages has none):

```swift
      .modifier(ConditionalSidebarToggleRemoval(remove: !state.sidebarCollapsible))
```

with the helper modifier (add near the bottom of panes.swift):

```swift
private struct ConditionalSidebarToggleRemoval: ViewModifier {
  let remove: Bool
  func body(content: Content) -> some View {
    if remove { content.toolbar(removing: .sidebarToggle) } else { content }
  }
}
```

- [ ] **Step 3: Pass wopts geometry + collapsible into the state (window.m).** At the SwiftUI `zapp_swift_panes_state_create` call (window.m ~line 1012), pass `wopts_sidebar_width/min_width/max_width(opts)` and `wopts_sidebar_collapsible(opts)`:

```c
  swiftPaneState = zapp_swift_panes_state_create((__bridge void*)window,
      zapp_swiftui_pane_changed, sidebarVisible, inspectorPresented,
      (double)wopts_sidebar_width(opts), (double)wopts_sidebar_min_width(opts),
      (double)wopts_sidebar_max_width(opts), wopts_sidebar_collapsible(opts));
```

(Keep the param order in lockstep with Step 1's `@_cdecl`.)

- [ ] **Step 4: Apply presentation (forced-tile) when the split resolves (sidebar.m).** In `zapp_sidebar_bind_swiftui` (Task 2 Step 1), after binding, apply the create-time presentation + collapsible from `wopts` cached on the controller. Add `BOOL cfgForcedTile;` + `BOOL cfgCollapsible;` to `ZappSidebarController`, set them in `zapp_sidebar_register_swiftui` (extend it to take `bool forced_tile, bool collapsible` — resolved in window.m from `wopts_sidebar_presentation(opts)` == "tile" and `wopts_sidebar_collapsible(opts)`), and apply on bind:

```objc
    // create-time presentation + collapsible (apply once on first bind)
    c.sidebarItem.canCollapse = c.cfgCollapsible ? YES : NO;
    if (@available(macOS 11.0, *)) c.sidebarItem.canCollapseFromWindowResize = c.cfgForcedTile ? NO : YES;
```

(`presentation: "tile"` ⇒ forced_tile=YES ⇒ `canCollapseFromWindowResize=NO` = Messages behavior; `"overlay"`/default ⇒ YES = SwiftUI default.)

- [ ] **Step 5: Build.**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run ../cli/src/zapp-cli.ts build 2>&1 | tail -20`
Expected: LAST line `[zapp] build complete: …`.

- [ ] **Step 6: Commit.**

```bash
git add native/platform/darwin/swift/panes.swift native/platform/darwin/window.m native/platform/darwin/sidebar.m
git commit -m "$(cat <<'EOF'
feat(darwin): 2c — create-time geometry + presentation(tile/overlay) + collapsible

PaneState carries create-time sidebar width/min/max + collapsible; the
NavigationSplitView column bounds read them (was hardcoded) and the auto sidebar
toggle is removed when non-collapsible (Messages-style). presentation:tile maps
to NSSplitViewItem.canCollapseFromWindowResize=NO via the resolved split.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Docs + kitchen-sink showcase + build matrix + human smoke

**Files:**
- Modify: `docs/native-ui-strategy.md`, `docs/api-reference.md`
- Modify: `kitchen-sink/zapp/app.nim` and/or `kitchen-sink/src/**`

- [ ] **Step 1: Kitchen-sink — SwiftUI shows a tiled sidebar + presentation showcase.** Ensure the kitchen-sink window declares `presentation: SidebarPresentation.Tile` (Nim, `app.nim`) so the SwiftUI sidebar tiles like AppKit. Add a Sidebar-section control (TS, `kitchen-sink/src/**`) that flips presentation/width/collapsible at runtime via the existing `Window.current().sidebar` API (`setWidth`, `setCollapsible`, `setResizable`) so both the Nim create-time path and the TS runtime path are exercised.

- [ ] **Step 2: Docs — parity matrix + deviations.** In `docs/native-ui-strategy.md`, update the 2c row to ✅ Done and record the reach-through approach (resolve the embedded `NSSplitViewController`, reuse AppKit primitives) + any deviation surfaced by T1/T5. In `docs/api-reference.md`, note that sidebar/inspector width/resize/collapsible/presentation behave identically on SwiftUI and AppKit (macOS), with the macOS-26 note if any presentation nuance applies.

- [ ] **Step 3: Build matrix.**

Run (each, expect `[zapp] build complete:` last / 0 failures):
- `cd /Users/zach/code/zapp/kitchen-sink && bun run ../cli/src/zapp-cli.ts build 2>&1 | tail -5` (Nim macOS, swiftui ON)
- temporarily set `native: { swiftui: false }` in `kitchen-sink/zapp.config.ts` → `bun run ../cli/src/zapp-cli.ts build 2>&1 | tail -5` (AppKit unchanged), then revert
- `cd /Users/zach/code/zapp/kitchen-sink && bun run ../cli/src/zapp-cli.ts build --platform ios 2>&1 | tail -5`
- `cd /Users/zach/code/zapp && bun test cli/src 2>&1 | tail -5`

- [ ] **Step 4: Commit.**

```bash
git add docs/native-ui-strategy.md docs/api-reference.md kitchen-sink/zapp/app.nim kitchen-sink/src
git commit -m "$(cat <<'EOF'
docs+kitchen-sink: 2c pane-control parity — tiled SwiftUI sidebar + presentation showcase

native-ui-strategy 2c row done (reach-through NSSplitViewController + AppKit
primitives); api-reference notes SwiftUI/AppKit pane-control parity. kitchen-sink
declares a tiled sidebar and exercises runtime presentation/width/collapsible via
the API (Nim create-time + TS runtime).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: HUMAN VISUAL SMOKE GATE (pause for the user).** Run `cd /Users/zach/code/zapp/kitchen-sink && bun run ../cli/src/zapp-cli.ts dev`. Ask the user to confirm, with swiftui ON: sidebar **tiles** (like AppKit), `setWidth` moves it exactly, lock/unlock works, non-collapsible hides the toggle + won't collapse on narrow (Messages), presentation modes switch via the API. Then flip `swiftui: false` and confirm **the same end result** on AppKit. Pause for confirmation before finishing the branch (which stays unmerged).

---

## Self-Review

**Spec coverage:** reach-through resolve+reuse (T1/T2) ✓; create-time geometry (T3) ✓; presentation tile/overlay via `canCollapseFromWindowResize` (T3) ✓; setCollapsible via `canCollapse` + toggle removal (T3) ✓; risk gate for SwiftUI clobber (T1) ✓; fallback noted (T1 Step 5) ✓; docs + kitchen-sink (Nim+TS) + matrix + smoke (T4) ✓; window.m/sidebar.m/inspector.m only, runtime/router/AppKit/iOS untouched (no task touches them) ✓.

**Placeholder scan:** none — exact helper code, no-op-replacement code, panes.swift modifier, and commands are spelled out. The one inherent unknown (does the split resolve + stick) is the explicit T1 gate, not a placeholder.

**Type consistency:** `zapp_find_split_vc(NSViewController*) -> NSSplitViewController*` used identically in window.m/sidebar.m/inspector.m; `zapp_sidebar_bind_swiftui`/`zapp_inspector_bind_swiftui` fill `c.splitVC`/`c.sidebarItem`/`c.inspectorItem`/`c.inspectorDividerIndex`/`cfg*` which the AppKit bodies already read; PaneState's new `sidebarMinW/idealW/maxW/sidebarCollapsible` are threaded through `zapp_swift_panes_state_create` in lockstep (Step 1 ↔ Step 3); `cfgForcedTile`/`cfgCollapsible` added to `ZappSidebarController` and set via the extended `zapp_sidebar_register_swiftui`.

**Note on `#ifdef ZAPP_HAS_SWIFTUI`:** `zapp_find_split_vc` is plain AppKit (no Swift symbols) so it needs no guard; the `swiftPaneState`-gated branches in sidebar.m/inspector.m only run when the SwiftUI path populated `swiftPaneState`, and call no Swift symbols — so no new guards required. (The `zapp_swift_panes_state_create` signature change in Step 1/3 is already inside the existing `#ifdef ZAPP_HAS_SWIFTUI` block.)
