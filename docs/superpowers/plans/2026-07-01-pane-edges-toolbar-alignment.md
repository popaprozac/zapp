# Pane Edges + Native Toolbar Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining iOS pane edges (sheet safe-area, collapsible affordance parity, no-sidebar inspector column, live resize emits, presentation animation, kitchen-sink state) and align toolbar item placement with native conventions on both platforms (+ #744/#745), per the approved spec `docs/superpowers/specs/2026-07-01-pane-edges-toolbar-alignment-design.md`.

**Architecture:** Phase 1 touches the iOS pane layer (`native/platform/ios/{window,sidebar,inspector,toolbar}.m`) with two discovery-gated items resolved by instrumented human smokes (FU-1 pattern) and one spike-gated port. Phase 2 centralizes toolbar placement in ONE pure-TS convention pass inside `normalizeToolbar` (the future per-pane config's insertion point), fixes the iOS double-toggle race by single-sourcing live split state, and fixes #744/#745 at their shared root cause (`menuFormRepresentation`). Three human gates: G1 (spike + instrumented readings), G2 (macOS toolbar visual), G3 (combined final matrix).

**Tech Stack:** ObjC/UIKit + AppKit, TypeScript runtime (bun:test TDD for the convention pass), Bun.

## Global Constraints

- Branch `feat/nim-native`. NO worktree, NO `git commit --amend`, NO merge.
- **macOS MUST NOT regress**: `native/platform/darwin/*` changes are limited to Task 10 (T3 menuFormRepresentation); macOS build verified per native task; placement verified at gate G2.
- **NO iOS-simulator interaction in-session** — the human runs every smoke. A build is complete only on `[zapp] build complete:` + fresh binary mtime (never Vite `✓ built` alone). Spike builds complete on `[splitref] build complete:`.
- **Per-file `git add` only** — never `-A`/`.`. Pre-existing unrelated WIP stays UNSTAGED, with ONE carve-out: `spikes/ios-splitview-reference/*` files MAY be committed by Task 1 (staging only spike files). The pre-existing spike WIP (width-probe instrumentation in `ContentViewController.m`/`InspectorViewController.m`) rides along in that commit — it is documented research tooling.
- Commit trailer `<TRAILER>` — every commit ends with EXACTLY these two lines (expand verbatim):
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01DZ9M515fEUqt9EE2oFDyyv
  ```
- Always Bun, never Node. iOS parity gate stays green: `cd /Users/zach/code/zapp && bun test cli/src/ios-platform-parity.test.ts`.
- Subagent models: Tasks 4, 5 = Fable 5 (judgment); all other implementers Sonnet 5; native-diff reviewers Fable 5; mechanical reviews/fixes Sonnet 5.

**Verification commands:**
- iOS-sim build: `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios-simulator`
- macOS build: `cd /Users/zach/code/zapp/kitchen-sink && bun run build`
- Spike build: `cd /Users/zach/code/zapp/spikes/ios-splitview-reference && ./build.sh`
- TS: `bun test runtime/window.test.ts` · `bun run check` (repo root)

---

## File Structure

- `spikes/ios-splitview-reference/src/AppDelegate.m` — Task 1 no-sidebar spike variant (compile-time flag).
- `kitchen-sink/src/shell/inspector-pane.ts` — Task 2 env() readout (temp), Task 3 fix/removal.
- `native/platform/ios/inspector.m` — Task 3 (sheet inset fix, branch B only).
- `native/platform/ios/sidebar.m` — Task 2 (temp side-effect logs), Task 4 (side-effect fix + `zapp_ios_sidebar_is_collapsible_for_window`), Task 6 (resize-note helpers), Task 7 (animated presentation), Task 11 (live-state call sites).
- `native/platform/ios/toolbar.m` — Task 4 (toggle disable wiring), Task 11 (T2 live-state read).
- `native/platform/ios/window.m` — Task 5 (hidden-Primary split port), Task 6 (pane-role on VCs).
- `runtime/window.ts` + `runtime/window.test.ts` — Task 9 (T1 convention pass, TDD), Task 10 (T3 TS warn + test).
- `native/platform/darwin/toolbar.m` — Task 10 ONLY (menuFormRepresentation).
- `kitchen-sink/src/sections/{sidebar,inspector}.ts` + shell — Task 8 (E6 state map).
- `docs/api-reference.md` — Task 12.

---

## Phase 1 — iOS pane edges

### Task 1: E3a — spike no-sidebar hidden-Primary variant

**Files:**
- Modify: `spikes/ios-splitview-reference/src/AppDelegate.m`

**Interfaces:**
- Produces: a `SPLITREF_NO_SIDEBAR` compile flag variant proving the hidden-Primary recipe Task 5 ports: `doubleColumn` split, empty Primary held hidden (`preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly`, `presentsWithGesture = NO`), Inspector column attached on 26+.

- [ ] **Step 1: Add the variant.** In `AppDelegate.m`'s split construction, add a compile-time switch (default OFF so the normal spike still builds identically):

```objc
// ── E3a hidden-Primary variant (no-sidebar window shape) ──────────────────
// Build with:  EXTRA_CFLAGS=-DSPLITREF_NO_SIDEBAR=1 ./build.sh   (or edit the
// default below). Proves a doubleColumn split whose Primary is an EMPTY VC
// held permanently hidden, so the iOS-26 Inspector column has a split to
// attach to on windows that declare no sidebar.
#ifndef SPLITREF_NO_SIDEBAR
#define SPLITREF_NO_SIDEBAR 0
#endif
```

When the flag is set: Primary = `[[UIViewController alloc] init]` (empty, clear background, NO nav wrap, no content); immediately after split configuration apply

```objc
    split.preferredDisplayMode  = UISplitViewControllerDisplayModeSecondaryOnly;
    split.presentsWithGesture   = NO;
    if (@available(iOS 14.0, *)) {
        split.showsSecondaryOnlyButton = NO;
    }
```

Keep: Secondary = ContentViewController (unchanged), Inspector column attach (unchanged 26+ block), the inspector toolbar button. Skip: SidebarViewController creation, land-on-content sidebar wiring (guard those lines with `#if !SPLITREF_NO_SIDEBAR`). If `build.sh` has no EXTRA_CFLAGS passthrough, add one line: `CFLAGS="$CFLAGS ${EXTRA_CFLAGS:-}"` (read the script first and match its variable names).

- [ ] **Step 2: Build BOTH variants.** `./build.sh` (flag off) → `[splitref] build complete:`; then `EXTRA_CFLAGS=-DSPLITREF_NO_SIDEBAR=1 ./build.sh` → complete. The flag-off binary must be the shipping artifact left in `build/` last if the human smokes the normal spike later — note in the report which variant is installed.

- [ ] **Step 3: Commit** (spike files only; the pre-existing width-probe WIP in `ContentViewController.m`/`InspectorViewController.m` rides along — stage those two files plus `AppDelegate.m` and `build.sh` if touched):

```bash
cd /Users/zach/code/zapp
git add spikes/ios-splitview-reference/src/AppDelegate.m spikes/ios-splitview-reference/src/ContentViewController.m spikes/ios-splitview-reference/src/InspectorViewController.m spikes/ios-splitview-reference/build.sh spikes/ios-splitview-reference/INSPECTOR_COLUMN_SPIKE.md
git commit -m "spike(ios): hidden-Primary no-sidebar variant + width-probe research tooling

<TRAILER>"
```

(Drop any path from the `git add` that has no changes.)

- [ ] **Step 4: GATE G1 input.** Report the exact build+install commands for the human (this smoke is combined with Task 2's — one sim session).

### Task 2: E1+E2 instrumentation build (temporary)

**Files:**
- Modify: `kitchen-sink/src/shell/inspector-pane.ts` (env() readout)
- Modify: `native/platform/ios/sidebar.m` (side-effect logs)

**Interfaces:**
- Produces: human-readable diagnostics — env() safe-area values rendered INSIDE the inspector pane, and `[zapp-nav] E2` logs around `darwin_sidebar_set_collapsible`.

- [ ] **Step 1: env() readout in the inspector pane.** In `kitchen-sink/src/shell/inspector-pane.ts`, append a fixed-position readout element to the pane's rendered content (temporary, marked `// TEMP E1 instrumentation`):

```ts
// TEMP E1 instrumentation: print env(safe-area-inset-*) as resolved inside
// this webview. Uses a probe element because env() is CSS-only.
function renderSafeAreaProbe(): void {
  const probe = document.createElement("div");
  probe.style.cssText =
    "position:fixed;top:env(safe-area-inset-top);left:env(safe-area-inset-left);" +
    "right:env(safe-area-inset-right);bottom:env(safe-area-inset-bottom);pointer-events:none;";
  document.body.appendChild(probe);
  const r = probe.getBoundingClientRect();
  const out = document.getElementById("e1-probe") ?? (() => {
    const el = document.createElement("pre");
    el.id = "e1-probe";
    el.style.cssText = "position:fixed;bottom:0;left:50%;transform:translateX(-50%);background:#000c;color:#0f0;padding:4px 8px;font-size:11px;z-index:9999;";
    document.body.appendChild(el);
    return el;
  })();
  out.textContent = `E1 env(): top=${Math.round(r.top)} left=${Math.round(r.left)} ` +
    `right=${Math.round(window.innerWidth - r.right)} bottom=${Math.round(window.innerHeight - r.bottom)}`;
  probe.remove();
}
window.addEventListener("resize", renderSafeAreaProbe);
setInterval(renderSafeAreaProbe, 1000);
renderSafeAreaProbe();
```

Call it once from the pane's init path (wherever the pane bootstraps — read the file and hook after the initial render).

- [ ] **Step 2: E2 side-effect logs.** In `native/platform/ios/sidebar.m`'s `darwin_sidebar_set_collapsible`, add temporary logs (marked `// TEMP E2 instrumentation`) BEFORE and AFTER the `presentsWithGesture` assignment:

```objc
        fprintf(stderr, "[zapp-nav] E2 before: canCollapse=%d displayMode=%ld behavior=%ld gesture=%d\n",
                (int)can_collapse, (long)c.splitVC.displayMode,
                (long)c.splitVC.preferredSplitBehavior, (int)c.splitVC.presentsWithGesture);
        // ... existing assignments ...
        dispatch_async(dispatch_get_main_queue(), ^{
            fprintf(stderr, "[zapp-nav] E2 settled: displayMode=%ld\n", (long)c.splitVC.displayMode);
        });
```

- [ ] **Step 3: Builds.** iOS-sim (`[zapp] build complete:` + fresh mtime) + macOS + parity.

- [ ] **Step 4: Commit.**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/shell/inspector-pane.ts native/platform/ios/sidebar.m
git commit -m "chore(ios): temporary E1 env-probe + E2 collapsible instrumentation

<TRAILER>"
```

- [ ] **Step 5: 🚦 GATE G1 (human, one sim session).** Hand the human:
  1. **Spike (Task 1 variant, iPad + iPhone):** install `EXTRA_CFLAGS=-DSPLITREF_NO_SIDEBAR=1` build. Verify: NO sidebar artifacts (no left-edge swipe reveal, no system reveal button in the nav bar, no flicker on rotation); inspector toggles as a column on iPad; auto-sheet on iPhone. PASS/FAIL per item.
  2. **Kitchen-sink E1 (iPhone, LANDSCAPE):** open the inspector sheet; read the green `E1 env():` line — paste the four numbers (the notch-side value is the verdict: real inset → CSS fix; 0 → framework fix).
  3. **Kitchen-sink E2 (iPad):** sidebar visible in overlay mode → press the sidebar section's Collapsible button → paste the `[zapp-nav] E2` lines + whether the sidebar visually collapsed. Repeat once from tiled mode.

### Task 3: E1 fix per discovery + de-instrument

**Files:**
- Modify: `kitchen-sink/src/shell/inspector-pane.ts` (remove probe; branch A adds CSS)
- Modify (branch B only): `native/platform/ios/inspector.m`

**Interfaces:**
- Consumes: G1's env() numbers.

- [ ] **Step 1: Apply exactly ONE branch.**
  - **Branch A (env() reported real insets):** the framework is correct; the pane CSS just doesn't consume it. Add to the inspector pane's container styles: `padding-left: env(safe-area-inset-left); padding-right: env(safe-area-inset-right);` (match the pane's existing style block idiom) and note the requirement in Task 12's docs list.
  - **Branch B (env() reported 0 on the notch side):** the sheet-presented nav swallows the inset. In `ios/inspector.m`'s sheet-affordance path (`zapp_ios_inspector_apply_sheet_affordances`), when presented, propagate the window's safe insets:

```objc
        // Sheet inset propagation: the auto-presented sheet does not inherit
        // the scene window's horizontal safe-area insets, so env() inside the
        // webview reads 0 on the notch side in landscape. Mirror the window's
        // left/right insets onto the presented nav.
        UIWindow* win = c.inspectorNav.view.window;
        if (win) {
            UIEdgeInsets wi = win.safeAreaInsets;
            UIEdgeInsets cur = c.inspectorNav.additionalSafeAreaInsets;
            if (cur.left != wi.left || cur.right != wi.right) {
                c.inspectorNav.additionalSafeAreaInsets =
                    UIEdgeInsetsMake(cur.top, wi.left, cur.bottom, wi.right);
            }
        }
```

  and reset `additionalSafeAreaInsets` left/right to 0 on the not-presented (column) branch.
- [ ] **Step 2: Remove the Task-2 probe** from `inspector-pane.ts` (all `TEMP E1` code).
- [ ] **Step 3: Builds** (iOS-sim + macOS + parity) green.
- [ ] **Step 4: Commit** (`git add` exactly the touched files):

```bash
git commit -m "fix(ios): inspector sheet honors landscape safe-area insets (E1, branch <A|B>); drop env probe

<TRAILER>"
```

### Task 4: E2 — collapsible affordance parity + side-effect fix (model: Fable 5)

**Files:**
- Modify: `native/platform/ios/sidebar.m` (`darwin_sidebar_set_collapsible`, new query fn, remove TEMP E2 logs)
- Modify: `native/platform/ios/toolbar.m` (toggle enabled wiring)

**Interfaces:**
- Consumes: G1's E2 log lines (the side-effect evidence); `ZappIOSSidebarController.collapsible` (stored today); `ZappIOSToolbarEntry.leadingItems` (contains Zapp's toggle button).
- Produces: `bool zapp_ios_sidebar_is_collapsible_for_window(void* window_ptr)` (exported from sidebar.m, consumed by toolbar.m at apply time; returns `true` when no sidebar controller exists).

- [ ] **Step 1: Export the query** in `sidebar.m` (next to the other `_for_window` helpers):

```objc
// Toolbar affordance query: is the sidebar user-collapsible? Drives the
// enabled state of Zapp's toggleSidebar toolbar button (macOS parity: the
// disabled-not-hidden affordance). true when no sidebar is registered.
bool zapp_ios_sidebar_is_collapsible_for_window(void* window_ptr) {
    if (!window_ptr || !zapp_ios_sidebars) return true;
    ZappIOSSidebarController* c = zapp_ios_sidebars[[NSValue valueWithPointer:window_ptr]];
    return c ? (bool)c.collapsible : true;
}
```

- [ ] **Step 2: Store the toggle button on the entry.** In `ios/toolbar.m`, add `@property (nonatomic, strong) UIBarButtonItem* toggleSidebarButton;` to `ZappIOSToolbarEntry`; set it where the manual toggleSidebar bar button is built (the item that goes into `leadingItems` but not `leadingNoToggle`).
- [ ] **Step 3: Apply enabled state.** In BOTH apply paths (`zapp_ios_toolbar_apply_to_nav` and the collapsed branch of `zapp_ios_toolbar_apply_for_window_hidden`), after items are assigned:

```objc
        extern bool zapp_ios_sidebar_is_collapsible_for_window(void*);
        entry.toggleSidebarButton.enabled =
            zapp_ios_sidebar_is_collapsible_for_window(window_ptr);
```

  and in `sidebar.m`'s `darwin_sidebar_set_collapsible`, after storing the new value, re-run the toolbar apply (call `zapp_ios_toolbar_apply_for_window_hidden(winPtr, <current hidden state>)` the same way the transition hook does) so the button greys immediately.
- [ ] **Step 4: Side-effect root cause + fix.** Adjudicate from the G1 E2 logs: the suspect is `presentsWithGesture = NO` forcing the overlay-presented Primary to dismiss (displayMode snapping to `SecondaryOnly`). If confirmed: gate the gesture assignment so it does not dismiss a currently-visible sidebar —

```objc
        // presentsWithGesture=NO dismisses an overlay-VISIBLE sidebar as a
        // side-effect (G1-diagnosed). Defer the gesture change until the
        // sidebar is not overlay-presented: collapsible gates AFFORDANCES,
        // never current visibility.
```

  concretely: capture `displayMode` before, apply `presentsWithGesture`, and if the mode changed as a side-effect restore it via the presentation helper (`zapp_ios_apply_presentation(c.splitVC, c.presentation)` + `showColumn:Primary` if it was visible). If the logs show a DIFFERENT mechanism, fix that mechanism; if the logs show no reproduction, document as not-reproducible in the report and keep only Steps 1-3.
- [ ] **Step 5: Remove TEMP E2 logs.** `grep -c "TEMP E2\|E2 before\|E2 settled" native/platform/ios/sidebar.m` → 0.
- [ ] **Step 6: Builds + parity green.**
- [ ] **Step 7: Commit:**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/sidebar.m native/platform/ios/toolbar.m
git commit -m "fix(ios): collapsible:false greys Zapp's sidebar toggle (macOS parity) + <side-effect fix per G1>; drop E2 instrumentation

<TRAILER>"
```

### Task 5: E3b — port hidden-Primary split to window.m (model: Fable 5)

**Files:**
- Modify: `native/platform/ios/window.m` (the `!d->hasSidebar` materialize branch, ~line 400 `if (d->hasSidebar) {` / ~line 468 `ZappIOSRootViewController` path; the inspector-block guard at ~line 706)

**Interfaces:**
- Consumes: Task 1's proven recipe (read the spike diff — `git show` the Task-1 commit — as the template); the existing sidebar-path split construction (window.m:400-466) for nav-wrap and webview-mount idioms; `zapp_ios_inspector_register` (12-param, unchanged).
- Produces: no-sidebar+inspector windows on iOS get a real split → the Inspector column on 26+; plain no-sidebar/no-inspector windows keep `ZappIOSRootViewController` EXACTLY as today.

- [ ] **Step 1: Branch the materialize.** The no-sidebar path splits in two: `(!d->hasSidebar && d->hasInspector)` → build a `UISplitViewControllerStyleDoubleColumn` split with Primary = empty plain `UIViewController` (clear background, never nav-wrapped, no webview) and Secondary = the SAME content construction the root path uses today (`ZappIOSPaneViewController` content VC + content nav + content webview mount + re-slot dance — reuse the existing code by restructuring, do not duplicate the webview-mount block); apply the spike recipe immediately after construction: `preferredDisplayMode = SecondaryOnly`, `presentsWithGesture = NO`, `showsSecondaryOnlyButton = NO`. `(!d->hasSidebar && !d->hasInspector)` → unchanged root path.
- [ ] **Step 2: Un-gate the inspector block.** The inspector pane block's split check (~:706 comment "no-sidebar windows take the ZappIOSRootViewController path") now finds a real split for no-sidebar windows — update the comment; `setViewController:forColumn:Inspector` + `zapp_ios_inspector_register` run as-is. Do NOT register a sidebar controller (no `zapp_ios_sidebar_register` call on this path) — verify toolbar behavior relies on the TS lacks-pane drop (`runtime/window.ts:880-908`), so no toggleSidebar item can exist for these windows.
- [ ] **Step 3: Trailing/leading content-webview constraints.** `zapp_ios_sidebar_set_content_webview` is sidebar-registry-coupled — check whether the no-sidebar path mounts the content webview with its own edge pins (the root path does today). The inspector's trailing safe-area displacement (FU-1 fix) lives in the sidebar controller's constraint pair; for the no-sidebar split, pin the content webview with the SAME trailingSafe-on-regular pattern — extract or replicate the minimal constraint logic WITHOUT registering a sidebar controller (a small static helper in window.m is acceptable; name it `zapp_ios_pin_content_webview_no_sidebar` and document why it mirrors sidebar.m's edge model).
- [ ] **Step 4: Builds + parity green** (iOS-sim + macOS).
- [ ] **Step 5: Commit:**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/window.m
git commit -m "feat(ios): no-sidebar+inspector windows get a hidden-Primary split -> native Inspector column on 26+ (E3)

<TRAILER>"
```

  (If Step 3 required touching `sidebar.m`, stage it too and say so in the report.)

### Task 6: E4 — live resize emits during divider drag (#720)

**Files:**
- Modify: `native/platform/ios/window.m` (`ZappIOSPaneViewController` gains `paneRole`; sidebarVC becomes a `ZappIOSPaneViewController`)
- Modify: `native/platform/ios/sidebar.m` + `native/platform/ios/inspector.m` (note-layout helpers)

**Interfaces:**
- Consumes: `zapp_ios_sidebar_emit_resize(ZappIOSSidebarController*, int32_t)` and `zapp_ios_inspector_emit_resize(...)` (existing emit helpers).
- Produces: `void zapp_ios_sidebar_note_layout_width(void* window_ptr, CGFloat width)` (sidebar.m) and `void zapp_ios_inspector_note_layout_width(void* window_ptr, CGFloat width)` (inspector.m), called from `ZappIOSPaneViewController.viewDidLayoutSubviews`.

- [ ] **Step 1: Pane role.** Add to `ZappIOSPaneViewController` (window.m:228-231): `@property (nonatomic, assign) int paneRole; // 0 content, 1 sidebar, 3 inspector` (default 0). Change the sidebar VC construction (window.m ~:406 `sidebarVC = [[UIViewController alloc] init]`) to a `ZappIOSPaneViewController` with `paneRole = 1` (windowPtr/hostSlot wired the same place contentVC's are; its safe-area/metrics hooks are guarded by `hostSlot < 0` semantics — set hostSlot only if the sidebar slot participates in metrics today, otherwise leave -1 and rely on windowPtr for the resize hook: adjust the guards in the resize hook to require only `windowPtr`). Set `paneRole = 3` on the inspector VC construction.
- [ ] **Step 2: Layout hook.** Add to `ZappIOSPaneViewController`:

```objc
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!_windowPtr || _paneRole == 0) return;
    CGFloat w = self.view.bounds.size.width;
    extern void zapp_ios_sidebar_note_layout_width(void*, CGFloat);
    extern void zapp_ios_inspector_note_layout_width(void*, CGFloat);
    if (_paneRole == 1) zapp_ios_sidebar_note_layout_width(_windowPtr, w);
    else if (_paneRole == 3) zapp_ios_inspector_note_layout_width(_windowPtr, w);
}
```

- [ ] **Step 3: Note-layout helpers (identical pattern in both files).** Sidebar version (inspector's mirrors it with its controller/emit):

```objc
// Live divider-drag resize emits (#720). viewDidLayoutSubviews fires per
// frame during a seam drag (probe-proven); this coalesces to at most one
// emit per runloop tick and dedupes on the rounded width. Guards: no split /
// collapsed(compact) / hidden pane / width<=1 (collapse-expand transitions)
// emit nothing — this reports regular-width divider geometry only.
void zapp_ios_sidebar_note_layout_width(void* window_ptr, CGFloat width) {
    if (!window_ptr || !zapp_ios_sidebars) return;
    ZappIOSSidebarController* c = zapp_ios_sidebars[[NSValue valueWithPointer:window_ptr]];
    if (!c || !c.splitVC || c.splitVC.isCollapsed) return;
    int32_t w = (int32_t)lround(width);
    if (w <= 1 || w == c.lastLayoutEmitWidth) return;
    c.lastLayoutEmitWidth = w;
    if (c.layoutEmitScheduled) return;
    c.layoutEmitScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        c.layoutEmitScheduled = NO;
        zapp_ios_sidebar_emit_resize(c, c.lastLayoutEmitWidth);
    });
}
```

with two new controller properties per pane controller: `@property (nonatomic, assign) int32_t lastLayoutEmitWidth;` (init to -1 at register) and `@property (nonatomic, assign) BOOL layoutEmitScheduled;`. Inspector guard additionally: skip when the nav is sheet-presented (`c.inspectorNav.presentingViewController != nil` → sheet, not a column) and (26+) when `![split isShowingColumn:UISplitViewControllerColumnInspector]`.
- [ ] **Step 4: Seed to avoid a launch emit.** At each register, set `lastLayoutEmitWidth` to the configured width so the first layout pass does not fire a spurious resize event.
- [ ] **Step 5: Builds + parity green.**
- [ ] **Step 6: Commit:**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/window.m native/platform/ios/sidebar.m native/platform/ios/inspector.m
git commit -m "feat(ios): live sidebar/inspector resize emits during divider drag (#720)

<TRAILER>"
```

### Task 7: E5 — animate presentation changes (#721)

**Files:**
- Modify: `native/platform/ios/sidebar.m` (`zapp_ios_apply_presentation`, :154-170 region)

- [ ] **Step 1: Wrap the pair application.** UIKit animates `preferredDisplayMode` changes itself when they occur inside an animation block; the current helper applies them cold. Wrap the body:

```objc
static void zapp_ios_apply_presentation(UISplitViewController* svc, NSString* mode) {
    if (!svc) return;
    // Animate the presentation change (#721): applying the behavior/display
    // pair inside an animation block makes UIKit animate the column
    // transition (tile<->overlay) instead of snapping. showColumn: calls are
    // already animated by UIKit and are left OUTSIDE the block to avoid
    // double-animation.
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        if ([mode isEqualToString:@"overlay"]) {
            svc.preferredSplitBehavior = UISplitViewControllerSplitBehaviorOverlay;
            svc.preferredDisplayMode  = UISplitViewControllerDisplayModeSecondaryOnly;
        } else if ([mode isEqualToString:@"tile"]) {
            svc.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
            svc.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
        } else {
            svc.preferredSplitBehavior = UISplitViewControllerSplitBehaviorAutomatic;
            svc.preferredDisplayMode  = UISplitViewControllerDisplayModeAutomatic;
        }
        [svc.view layoutIfNeeded];
    } completion:nil];
    // (keep the existing iOS16+ showColumn:Primary tile-recipe call OUTSIDE
    //  the animation block, exactly where it is today)
}
```

Preserve the existing else/automatic semantics exactly (read the current full body first — the snippet above must carry over every existing branch, including the `showColumn:Primary` tile recipe outside the block).
- [ ] **Step 2: Builds + parity green.**
- [ ] **Step 3: Commit** (`git add native/platform/ios/sidebar.m`), message `feat(ios): animate tile<->overlay presentation changes (#721)` + `<TRAILER>`.

### Task 8: E6 — kitchen-sink pane-button state (#666)

**Files:**
- Modify: `kitchen-sink/src/sections/sidebar.ts`, `kitchen-sink/src/sections/inspector.ts` (read state from the store)
- Create: `kitchen-sink/src/shell/pane-state.ts`
- NOTE: `sections/sidebar.ts` has pre-existing uncommitted WIP — read the working-tree version, integrate WITHOUT reverting existing modifications, and stage the file (its WIP becomes part of this commit; call that out in the report).

**Interfaces:**
- Produces: `paneState.get(windowId): { sidebar: { collapsible: boolean; resizable: boolean }, inspector: { collapsible: boolean; resizable: boolean } }` + `paneState.set(windowId, patch)` — a module-level map the sections read at render and write on button press.

- [ ] **Step 1: Create the store** (`kitchen-sink/src/shell/pane-state.ts`):

```ts
// #666: pane-section toggle state survives route navs. The sections fully
// re-render per route; native has no getters for collapsible/resizable, so
// the demo mirrors what it last SET (defaults = create-time config).
type PaneFlags = { collapsible: boolean; resizable: boolean };
type WindowPaneState = { sidebar: PaneFlags; inspector: PaneFlags };
const state = new Map<string, WindowPaneState>();
const defaults = (): WindowPaneState => ({
  sidebar: { collapsible: true, resizable: true },
  inspector: { collapsible: true, resizable: true },
});
export const paneState = {
  get(windowId: string): WindowPaneState {
    let s = state.get(windowId);
    if (!s) { s = defaults(); state.set(windowId, s); }
    return s;
  },
};
```

- [ ] **Step 2: Wire the sections.** In both section files, replace the render-local `let collapsible = true` style locals with reads from `paneState.get(win.id)`, and flip the stored value in each button handler (keep the existing native calls unchanged). Labels render from the stored value.
- [ ] **Step 3: Verify with `bun run check`** (kitchen-sink is not type-gated — see backlog #763 — so also run the kitchen-sink build: `cd kitchen-sink && bun run build` → complete).
- [ ] **Step 4: Commit** (`git add kitchen-sink/src/shell/pane-state.ts kitchen-sink/src/sections/sidebar.ts kitchen-sink/src/sections/inspector.ts`), message `fix(kitchen-sink): pane-section toggle state survives route navs (#666)` + `<TRAILER>`.

---

## Phase 2 — native toolbar alignment

### Task 9: T1 — convention-ordering pass in normalizeToolbar (TDD)

**Files:**
- Modify: `runtime/window.ts` (new exported pure fn + one call site at :1001)
- Test: `runtime/window.test.ts`

**Interfaces:**
- Produces: `export function applyToolbarConventions(items: Record<string, unknown>[]): Record<string, unknown>[]` — THE centralized placement point (the future per-pane placement config feeds overrides into exactly this function; nothing else reorders). Consumed by `normalizeToolbar` immediately before `JSON.stringify`.

**Semantics (pin these in tests):**
1. All occurrences of the three system anchors are EXTRACTED wherever declared: `toggleSidebar`, `trackingSeparator` (per `pane`), `toggleInspector`. Duplicates collapse to one (first wins) — this also closes the latent TS gap where duplicate system items reached native unchecked.
2. Rebuild: leading prefix = `[{type:"flexibleSpace",placement:"leading"}, toggleSidebar, trackingSeparator(pane:"sidebar")]` — the flexibleSpace is injected ONLY when BOTH toggleSidebar and the sidebar trackingSeparator are present (it right-aligns the toggle inside the sidebar region; on collapse the separator collapses and the toggle lands leading-main statically). toggleSidebar without a separator → anchored leading-first, no flex. Separator without toggle → anchored leading-first alone.
3. Trailing suffix = `[..., trackingSeparator(pane:"inspector"), toggleInspector]` appended after all app trailing items (either alone if only one present).
4. If the app's first remaining leading item is a `flexibleSpace` AND the full sidebar prefix was injected, drop that app flex (it was serving the convention the pass now owns).
5. Anchored items get their `placement` forced (`"leading"` / `"trailing"`); the `pane` field on tracking separators is preserved verbatim. All other items keep their relative order and placements untouched.
6. Pure function: no mutation of the input array or its objects.

- [ ] **Step 1: Write the failing tests** (`runtime/window.test.ts`, one `test()` block per semantic):

```ts
import { applyToolbarConventions } from "./window";

const ts = (pane: string) => ({ type: "trackingSeparator", pane, placement: "leading" });
const tgl = { type: "toggleSidebar", placement: "leading" };
const insp = { type: "toggleInspector", placement: "trailing" };
const btn = (id: string, placement = "leading") => ({ type: "button", id, placement });

test("T1: anchors sidebar prefix with injected flex", () => {
  const out = applyToolbarConventions([btn("a"), tgl, ts("sidebar"), btn("b", "trailing")]);
  expect(out.slice(0, 3).map((i) => i.type)).toEqual(["flexibleSpace", "toggleSidebar", "trackingSeparator"]);
  expect(out[3]).toMatchObject({ id: "a" });
});

test("T1: toggleSidebar declared trailing is still anchored leading", () => {
  const out = applyToolbarConventions([btn("a"), { type: "toggleSidebar", placement: "trailing" }, ts("sidebar")]);
  expect(out[1]).toMatchObject({ type: "toggleSidebar", placement: "leading" });
});

test("T1: inspector suffix anchored trailing-most", () => {
  const out = applyToolbarConventions([insp, ts("inspector"), btn("z", "trailing")]);
  const types = out.map((i) => i.type);
  expect(types.slice(-2)).toEqual(["trackingSeparator", "toggleInspector"]);
  expect((out.at(-2) as any).pane).toBe("inspector");
});

test("T1: no flex without the separator; toggle anchored leading-first", () => {
  const out = applyToolbarConventions([btn("a"), tgl]);
  expect(out[0]).toMatchObject({ type: "toggleSidebar" });
  expect(out.some((i) => i.type === "flexibleSpace")).toBe(false);
});

test("T1: app-declared adjacent flex collapses into the injected one", () => {
  const out = applyToolbarConventions([{ type: "flexibleSpace", placement: "leading" }, tgl, ts("sidebar"), btn("a")]);
  expect(out.filter((i) => i.type === "flexibleSpace").length).toBe(1);
});

test("T1: duplicate system items collapse to one", () => {
  const out = applyToolbarConventions([tgl, btn("a"), { ...tgl }]);
  expect(out.filter((i) => i.type === "toggleSidebar").length).toBe(1);
});

test("T1: app items keep relative order and input is not mutated", () => {
  const input = [btn("a"), tgl, btn("b"), ts("sidebar"), btn("c", "trailing")];
  const snapshot = JSON.parse(JSON.stringify(input));
  const out = applyToolbarConventions(input);
  expect(out.filter((i: any) => i.type === "button").map((i: any) => i.id)).toEqual(["a", "b", "c"]);
  expect(input).toEqual(snapshot);
});

test("T1: normalizeToolbar output is conventionalized end-to-end", () => {
  const { json } = normalizeToolbar(
    { items: [ { id: "x", label: "X" } as any, { type: "toggleSidebar" } as any, { type: "trackingSeparator" } as any ] },
    true, false,
  );
  const wire = JSON.parse(json);
  expect(wire.items.slice(0, 3).map((i: any) => i.type)).toEqual(["flexibleSpace", "toggleSidebar", "trackingSeparator"]);
});
```

(`normalizeToolbar` is already imported by the test file's siblings — match the file's existing import style.)
- [ ] **Step 2: Run to verify FAIL** — `bun test runtime/window.test.ts` fails on the missing export.
- [ ] **Step 3: Implement** in `runtime/window.ts` (above `normalizeToolbar`):

```ts
/** T1 convention pass — THE single placement-resolution point. The future
 *  per-pane placement config feeds overrides into this function; nothing
 *  else in the pipeline reorders items. Anchors (native convention):
 *  leading = [flexibleSpace, toggleSidebar, trackingSeparator(sidebar)],
 *  trailing tail = [trackingSeparator(inspector), toggleInspector].
 *  App items keep declared order. Documented behavior change (pre-1.0). */
export function applyToolbarConventions(
  items: Record<string, unknown>[],
): Record<string, unknown>[] {
  let toggleSidebar: Record<string, unknown> | undefined;
  let sepSidebar: Record<string, unknown> | undefined;
  let sepInspector: Record<string, unknown> | undefined;
  let toggleInspector: Record<string, unknown> | undefined;
  const rest: Record<string, unknown>[] = [];
  for (const item of items) {
    const t = item.type;
    if (t === "toggleSidebar") { toggleSidebar ??= { ...item, placement: "leading" }; continue; }
    if (t === "toggleInspector") { toggleInspector ??= { ...item, placement: "trailing" }; continue; }
    if (t === "trackingSeparator") {
      if (item.pane === "inspector") sepInspector ??= { ...item, placement: "trailing" };
      else sepSidebar ??= { ...item, placement: "leading" };
      continue;
    }
    rest.push(item);
  }
  const prefix: Record<string, unknown>[] = [];
  if (toggleSidebar && sepSidebar) {
    prefix.push({ type: "flexibleSpace", placement: "leading" }, toggleSidebar, sepSidebar);
    // Collapse an app-declared leading flex that duplicated the convention.
    if (rest[0]?.type === "flexibleSpace" && rest[0]?.placement === "leading") rest.shift();
  } else if (toggleSidebar) prefix.push(toggleSidebar);
  else if (sepSidebar) prefix.push(sepSidebar);
  const suffix: Record<string, unknown>[] = [];
  if (sepInspector) suffix.push(sepInspector);
  if (toggleInspector) suffix.push(toggleInspector);
  return [...prefix, ...rest, ...suffix];
}
```

  Call site — `normalizeToolbar`'s return (:1001) becomes:

```ts
  return { json: JSON.stringify({ style: toolbar.style ?? "unified", items: applyToolbarConventions(items) }), actions, menuActions, menuIdsByItem, menuTrees };
```

- [ ] **Step 4: Run to verify PASS** — `bun test runtime/window.test.ts` + `bun run check` green; also `bun test runtime/` (no sibling regressions) + parity test.
- [ ] **Step 5: Commit** (`git add runtime/window.ts runtime/window.test.ts`), message `feat(toolbar): native-convention placement pass in normalizeToolbar (centralized; behavior change)` + `<TRAILER>`.

### Task 10: T3 — menuFormRepresentation for #744 + #745 (+ TS warn)

**Files:**
- Modify: `native/platform/darwin/toolbar.m` (`:371-396` label items; `:262-302` segmented groups)
- Modify: `runtime/window.ts` (icon-only-segment warn) · Test: `runtime/window.test.ts`

- [ ] **Step 1 (TDD for the warn): failing test** —

```ts
test("T3: warns when an icon-only segment omits label", () => {
  const warnings: string[] = [];
  const orig = console.warn;
  console.warn = (msg: string) => { warnings.push(String(msg)); };
  try {
    normalizeToolbar({ items: [ { type: "segmented", id: "seg", segments: [{ icon: "sf:star" }] } as any ] }, false, false);
  } finally { console.warn = orig; }
  expect(warnings.some((w) => w.includes("icon-only segment"))).toBe(true);
});
```

- [ ] **Step 2: Run FAIL, then implement the warn** in `normalizeToolbar`'s segmented branch (inside the `wireSegs` map, runtime/window.ts:932-940):

```ts
        if (s.icon && !s.label) {
          console.warn(`[zapp] toolbar: icon-only segment in "${it.id}" has no "label" — AppKit uses labels for the collapsed/overflow menu (add one to avoid a blank menu entry)`);
        }
```

- [ ] **Step 3: #745 — label items.** In `darwin/toolbar.m`'s label branch (:371-396), after `labelItem.enabled = YES;`:

```objc
        // #745: without an explicit menuFormRepresentation, AppKit synthesizes
        // an ENABLED NSMenuItem for the >> overflow menu, which looks
        // clickable. Represent the label as disabled text.
        NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle:(text.length ? text : identifier)
                                                     action:NULL keyEquivalent:@""];
        mi.enabled = NO;
        labelItem.menuFormRepresentation = mi;
```

- [ ] **Step 4: #744 — segmented labels fallback.** In the segmented branch (:262-302), where the `labels` array is populated (:272), fall back so no empty string ever reaches AppKit's overflow representation:

```objc
            NSString* segLabel = [s[@"label"] isKindOfClass:[NSString class]] && ((NSString*)s[@"label"]).length
                ? s[@"label"]
                : ([s[@"id"] isKindOfClass:[NSString class]] && ((NSString*)s[@"id"]).length ? s[@"id"] : [NSString stringWithFormat:@"%lu", (unsigned long)idx]);
            [labels addObject:segLabel];
```

  (adapt variable names to the existing loop; the invariant: `labels` never contains `@""`).
- [ ] **Step 5: Gates.** `bun test runtime/window.test.ts` + `bun run check` + macOS build (`[zapp] build complete:`) + iOS-sim build + parity.
- [ ] **Step 6: Commit** (`git add native/platform/darwin/toolbar.m runtime/window.ts runtime/window.test.ts`), message `fix(macos): toolbar overflow honesty — label menuFormRepresentation (#745) + non-empty segment labels (#744) + TS icon-only warn` + `<TRAILER>`.

- [ ] **Step 7: 🚦 GATE G2 (human, macOS only).** Launch `kitchen-sink/bin/kitchen-sink`: (1) sidebar toggle sits at the RIGHT edge of the sidebar region (against the divider); (2) collapse the sidebar → the toggle lands at the leading edge of the main toolbar (native migration); (3) inspector toggle trailing-most, after its separator; (4) narrow the window until items overflow → the ≫ menu shows the label item as non-clickable grey text and segmented entries with real labels; (5) full toolbar regression (buttons, menus, groups all work).

### Task 11: T2 — iOS double-toggle race fix

**Files:**
- Modify: `native/platform/ios/toolbar.m` (`zapp_ios_toolbar_apply_for_window_hidden`, :863-930)
- Modify: `native/platform/ios/sidebar.m` (caller at :552 + the willChangeToDisplayMode hook that computes `targetHidden` at :527-552)

**Interfaces:**
- Consumes: the existing live-state helpers used elsewhere in sidebar.m (`zapp_ios_sidebar_is_hidden_for_window` or the displayMode read backing it — read the file for the exact helper).
- Produces: unchanged symbol `zapp_ios_toolbar_apply_for_window_hidden(void*, BOOL)` — but the BOOL becomes advisory-only: the expanded path re-reads LIVE state at apply time.

- [ ] **Step 1: Live read at apply time.** In the expanded branch (:920-928), replace the parameter-trusting decision:

```objc
        // T2: the sidebarHidden PARAMETER may be a transition TARGET passed
        // from willChangeToDisplayMode: (pre-settle). UIKit adds its system
        // reveal button based on the split's ACTUAL state — so decide from a
        // live read; the settled re-apply (Step 2) issues the final word.
        extern bool zapp_ios_split_display_mode_is_secondary_only(void*);
        BOOL includeToggle = !zapp_ios_split_display_mode_is_secondary_only(window_ptr);
        (void)sidebarHidden; // advisory only — kept for ABI/site compatibility
```

  — implement `zapp_ios_split_display_mode_is_secondary_only(void*)` in sidebar.m (exported): resolve the controller from the window pointer and return `c.splitVC.displayMode == UISplitViewControllerDisplayModeSecondaryOnly` (false when no controller/split).
- [ ] **Step 2: Settled re-apply.** Verify (and add if missing) that the SETTLED transition path re-applies the toolbar: the `willChangeToDisplayMode:` hook at sidebar.m:527-552 currently applies synchronously with the target; keep that call (pre-settle apply is fine — it now reads live state and may briefly keep the old toggle) AND add a completion re-apply via the transition coordinator or a main-queue hop after the transition (match how sidebar.m already handles settled work — e.g. the `dispatch_async` pattern used in its other hooks) so the settled state always gets a final apply.
- [ ] **Step 3: Acceptance reasoning in the report:** enumerate the four states (collapsed / expanded+visible / expanded+hidden / mid-transition) and argue exactly-one-of {system reveal button, Zapp toggle} for each settled state.
- [ ] **Step 4: Builds + parity green.**
- [ ] **Step 5: Commit** (`git add native/platform/ios/toolbar.m native/platform/ios/sidebar.m`), message `fix(ios): toolbar toggle inclusion reads live split state (kills double sidebar-toggle race)` + `<TRAILER>`.

### Task 12: Docs

**Files:**
- Modify: `docs/api-reference.md`

- [ ] **Step 1:** Update, in the existing sections' style: (a) `presentation: "overlay"` is iOS/iPadOS-only — macOS always tiles (closes #646 as by-design) — plus a compact per-platform defaults table (#621: macOS=tile-always; iOS=automatic default, tile/overlay preferences); (b) the toolbar convention pass — system items are auto-anchored (leading `[flex, toggleSidebar, separator]`, trailing `[separator, toggleInspector]`) regardless of declared position, a pre-1.0 behavior change, with the note that per-pane placement config will layer on this pass; (c) live `SIDEBAR_RESIZED`/`INSPECTOR_RESIZED` emits stream during divider drags on iPadOS (#720); (d) `collapsible: false` on iOS greys Zapp's toolbar toggle (macOS parity) while UIKit's system reveal affordances stay hidden; (e) no-sidebar windows with an inspector get the native Inspector column on iOS 26+ (hidden-Primary split; `<26` modal sheet unchanged); (f) E1's outcome (env() requirement note if branch A, nothing if branch B).
- [ ] **Step 2:** `bun run check` (docs don't compile, but run the standard gate set anyway: parity + `bun test runtime/window.test.ts`).
- [ ] **Step 3: Commit** (`git add docs/api-reference.md`), message `docs: pane presentation platform matrix, toolbar conventions, live resize emits, collapsible semantics` + `<TRAILER>`.

- [ ] **Step 4: 🚦 GATE G3 (human, combined final matrix).** Fresh iOS-sim + macOS builds at HEAD, then:
  - **iPad:** live-resize events stream during seam drags (both panes, watch the section readouts); tile↔overlay animates; collapsible:false greys the toolbar toggle (and no longer collapses the sidebar); inspector edges regression (toggle/width/min-max/resizable, FU-1 reflow intact).
  - **iPhone:** inspector sheet in LANDSCAPE honors the notch inset (E1); Close+grabber intact; portrait regression.
  - **No-sidebar+inspector window** (kitchen-sink Multi-window section or a temporary config — the task before G3 should confirm a reachable demo path and note it): iPad shows the native column, iPhone the sheet; no sidebar artifacts.
  - **Toolbar (both platforms):** conventions hold on iOS (toggle placement, no double-toggle across sidebar hide/show/rotate cycles), macOS G2 items still good.
  - **Kitchen-sink:** pane-section labels survive route navs (#666).
  - **Verify-and-close:** FU-2 (route /detail → back → per-route toolbar restored?) — confirm-or-close; #718 (iPad Split View/Slide Over with inspector open, cross regular↔compact) — expected PASS → close #718.
  - **macOS full pane regression** (zero tolerance).

---

## Self-Review

- **Spec coverage:** E1→T2+T3+T12(f) via Tasks 2/3; E2→2/4; E3→1/5; E4→6; E5→7; E6→8; T1→9; T2→11; T3→10; docs→12; verify-and-close + gates G1/G2/G3 embedded at Tasks 2, 10, 12. OUT-list respected (darwin/* only in Task 10; no config surface; `<26` untouched).
- **Placeholder scan:** discovery items (Tasks 3/4) carry complete code per branch + explicit adjudication rules; Task 5 is judgment-ported from the Task-1 spike template with concrete requirements (Fable 5 assigned). No TBDs.
- **Type consistency:** `applyToolbarConventions(items: Record<string, unknown>[])` matches Task 9 tests and the :1001 call site; `zapp_ios_sidebar_is_collapsible_for_window(void*)` (Task 4) and `zapp_ios_{sidebar,inspector}_note_layout_width(void*, CGFloat)` (Task 6) declared once and externed at their single consumers; `zapp_ios_toolbar_apply_for_window_hidden` symbol unchanged (Task 11).
