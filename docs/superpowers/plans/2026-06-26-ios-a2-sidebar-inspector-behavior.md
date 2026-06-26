# iOS A2 — Sidebar/Inspector Behavior Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the iOS sidebar/inspector behavior gaps (spec `docs/superpowers/specs/2026-06-26-ios-a2-sidebar-inspector-behavior-design.md`): sidebar width emit (#714), iPhone-landscape inspector-sheet dismiss, sidebar-pane safe-area, collapsible/resizable docs, presentation enum honesty + runtime `setPresentation`; then the risk-gated iPad split-presentation tail.

**Architecture:** Mechanical/low-risk fixes (T1–T5) land first — native ObjC in `native/platform/ios/` mirroring the existing inspector/macOS patterns, one CLI/runtime+router layer for `setPresentation`, one kitchen-sink CSS + demo change. T6 is a risk-gated sim-debug tail with three independently-deferrable items, ending in human smoke. macOS (`native/platform/darwin/`) is the parity reference — not modified except a no-op `darwin_sidebar_set_presentation` for cross-platform symbol parity.

**Tech Stack:** Objective-C (UIKit/WebKit), Nim (router + window opts), TypeScript (runtime + kitchen-sink), Bun.

## Global Constraints

- Branch `feat/nim-native`, kept **UNMERGED**.
- Commit trailer on every commit, EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- **Staging:** explicit per-file `git add <path>` only. NEVER `git add -A`/`.`. No `git commit --amend`.
- **Always Bun, never Node.**
- iOS native changes verified by **compile** (`cd kitchen-sink && bun run build --platform ios` → `[zapp] build complete:`); **no iOS simulator interaction in-session** — runtime behavior is the human smoke (T6).
- Gates: `bun run check` clean; `bun test cli/src` green; iOS-sim build green; default macOS build (`cd kitchen-sink && bun run build`) stays green.
- `bun run check 2>&1 | tail` swallows tsc's exit code — verify via real exit (`if bun run check; then …`).
- Default sidebar presentation stays `.automatic` (no behavior change to the default in T5; T5 only makes `tile`/`overlay`/`automatic` explicit + adds runtime switching).

---

### Task 1: sidebar `sidebar-resized` width emit (#714) — atomic native

**Files:**
- Modify: `native/platform/ios/sidebar.m` (add data-carrying emit + resize emit; refactor name-only emit; call from `darwin_sidebar_set_width`)

**Interfaces produced (file-local statics in sidebar.m):**
- `static void zapp_ios_sidebar_emit_data(ZappIOSSidebarController* c, const char* eventName, NSString* dataJson)`
- `static void zapp_ios_sidebar_emit_resize(ZappIOSSidebarController* c, int32_t width)`
- (existing, reused) `zapp_ios_sidebar_emit` now delegates to `_emit_data`; `extern int32_t zapp_ios_inspector_slot_for(int32_t)` is already declared/used in this file.

- [ ] **Step 1: Replace the name-only emit with a data-carrying emit + delegate**

In `native/platform/ios/sidebar.m`, replace the current `zapp_ios_sidebar_emit` function (the block starting `static void zapp_ios_sidebar_emit(ZappIOSSidebarController* c, const char* eventName) {` ~line 154, ending at its closing brace ~line 170) with these two functions (mirrors `zapp_ios_inspector_emit_data` exactly, fanning out host + sidebar slot + inspector slot, deduped):
```objc
// Data-carrying fan-out (mirrors ios/inspector.m's zapp_ios_inspector_emit_data):
// host + sidebar slot + inspector slot. dataJson nil => third arg `undefined`.
static void zapp_ios_sidebar_emit_data(ZappIOSSidebarController* c,
                                       const char* eventName, NSString* dataJson) {
    if (!c || !eventName) return;
    NSString* dataArg = @"undefined";
    if (dataJson) {
        NSString* esc = [dataJson stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        esc = [esc stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        dataArg = [NSString stringWithFormat:@"'%@'", esc];
    }
    NSString* event = [NSString stringWithUTF8String:eventName];
    char js[256];
    snprintf(js, sizeof(js),
        "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&typeof b.dispatchWindowEvent==='function'){"
        "b.dispatchWindowEvent('win-%d','%s',%s);}})();",
        c.hostWindowId, event.UTF8String, dataArg.UTF8String);
    darwin_window_eval_js(c.hostWindowId, js);
    if (c.sidebarSlotId >= 0 && c.sidebarSlotId != c.hostWindowId) {
        darwin_window_eval_js(c.sidebarSlotId, js);
    }
    int32_t inspectorSlot = zapp_ios_inspector_slot_for(c.hostWindowId);
    if (inspectorSlot >= 0 && inspectorSlot != c.hostWindowId && inspectorSlot != c.sidebarSlotId) {
        darwin_window_eval_js(inspectorSlot, js);
    }
}

// Name-only emit (collapse/expand) — delegates to the data-carrying form.
static void zapp_ios_sidebar_emit(ZappIOSSidebarController* c, const char* eventName) {
    zapp_ios_sidebar_emit_data(c, eventName, nil);
}

// sidebar-resized carries {"width":N} (bare top-level width) — mirrors the
// inspector resize payload + macOS sidebar-resized + bootstrap/webview.ts's
// bareWidth branch.
static void zapp_ios_sidebar_emit_resize(ZappIOSSidebarController* c, int32_t width) {
    NSString* json = [NSString stringWithFormat:@"{\"width\":%d}", (int)width];
    zapp_ios_sidebar_emit_data(c, "sidebar-resized", json);
}
```
(Keep the existing doc-comment block above the function. The three functions must appear before `darwin_sidebar_set_width` ~line 392, which they do.)

- [ ] **Step 2: Emit on programmatic setWidth**

In `darwin_sidebar_set_width` (~line 392), add the resize emit inside the `if (width > 0)` block, right after setting `preferredPrimaryColumnWidth`:
```objc
        c.configuredWidth = width;
        if (width > 0) {
            c.splitVC.preferredPrimaryColumnWidth = (CGFloat)width;
            zapp_ios_sidebar_emit_resize(c, width);
        }
```
(Emits the requested width — same as `darwin_inspector_set_width` emits its passed width. Runs inside the existing `zapp_ios_sidebar_on_main` block, so it's on the main thread.)

- [ ] **Step 3: Build-verify (iOS-sim compile + macOS)**

```bash
cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios
cd /Users/zach/code/zapp/kitchen-sink && bun run build
```
Expected: both end with `[zapp] build complete: …`. (The TS/bootstrap/kitchen-sink layers already consume `SIDEBAR_RESIZED` — no change there; runtime behavior is the T6 smoke.)

- [ ] **Step 4: Confirm the consumer chain is unchanged (read-only)**

Verify (no edits): `bootstrap/webview.ts` `bareWidth` branch lists `"sidebar-resized"`; `runtime/window.ts` SidebarHandle updates `width` on `SIDEBAR_RESIZED` (~1195); `kitchen-sink/src/sections/sidebar.ts` renders `width ${d.width}` on `SIDEBAR_RESIZED` (~57). If any is absent, STOP and report (the spec assumes they exist). Quick check:
```bash
cd /Users/zach/code/zapp
grep -n "sidebar-resized" bootstrap/webview.ts
grep -n "SIDEBAR_RESIZED" runtime/window.ts kitchen-sink/src/sections/sidebar.ts
```

- [ ] **Step 5: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/sidebar.m
git commit -m "fix(ios): sidebar emits sidebar-resized width event (#714)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: iPhone-landscape inspector sheet stays dismissable

**Files:**
- Modify: `native/platform/ios/inspector.m` (`darwin_inspector_expand` compact/sheet block, ~line 255)

- [ ] **Step 1: Keep the sheet edge-attached in compact height**

In `native/platform/ios/inspector.m`, inside `darwin_inspector_expand`'s `if (@available(iOS 15.0, *))` sheet block (the `if (sheet) { … }` that sets `detents`/`prefersGrabberVisible`/`delegate`, ~line 255), add two lines so the sheet stays a dismissable card instead of being promoted to fullscreen in landscape iPhone (compact height):
```objc
                if (sheet) {
                    sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                                      UISheetPresentationControllerDetent.largeDetent];
                    sheet.prefersGrabberVisible = YES;
                    sheet.prefersEdgeAttachedInCompactHeight = YES;
                    sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = YES;
                    sheet.delegate = c; // for swipe-dismiss sync (presentationControllerDidDismiss:)
                }
```
Both properties are iOS 15+ (already inside the `@available(iOS 15.0, *)` guard). The existing `presentationControllerDidDismiss:` (~line 61) keeps `shown`/event state in sync on swipe-dismiss — unchanged.

- [ ] **Step 2: Build-verify**

```bash
cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios
```
Expected: `[zapp] build complete:`.

- [ ] **Step 3: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/inspector.m
git commit -m "fix(ios): keep iPhone-landscape inspector sheet edge-attached + dismissable

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

> **Smoke-contingent fallback (do NOT build now):** if the T6 human smoke shows the sheet still can't be dismissed in landscape, add an explicit close affordance (a "Done"/✕ button in the inspector chrome when compact). Tracked as a follow-up; only implement if the primary fix proves insufficient on the device/sim.

---

### Task 3: sidebar-pane top safe-area CSS

**Files:**
- Modify: `kitchen-sink/src/style.css` (`.sidebar-pane` rule, ~line 40)

- [ ] **Step 1: Clear the iOS safe area on the sidebar pane**

In `kitchen-sink/src/style.css`, the `.sidebar-pane` rule is currently:
```css
.sidebar-pane { padding: var(--zapp-titlebar-height, 52px) 8px 8px; }
```
Change the top padding so macOS keeps using the injected titlebar height while iOS (no titlebar injected) falls through to the real safe-area inset:
```css
/* Top: macOS uses the injected toolbar height; iOS has no toolbar injected, so
   fall through to the status-bar safe area (A1 idiom: var, env() fallback). */
.sidebar-pane { padding: var(--zapp-titlebar-height, env(safe-area-inset-top, 8px)) 8px 8px; }
```
(macOS injects `--zapp-titlebar-height` → unchanged ~52px; iOS leaves it unset → `env(safe-area-inset-top)` ≈ the notch/status-bar inset, with `8px` as the no-notch floor. No macOS regression; no `calc` double-count.)

- [ ] **Step 2: Build-verify (both platforms)**

```bash
cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios
cd /Users/zach/code/zapp/kitchen-sink && bun run build
```
Expected: both `[zapp] build complete:`. (Exact spacing is the T6 smoke; this is a CSS-only change.)

- [ ] **Step 3: Commit**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src/style.css
git commit -m "fix(kitchen-sink): sidebar-pane top clears iOS safe area (macOS unchanged)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: document `setCollapsible`/`setResizable` as macOS-only on iOS

**Files:**
- Modify: `docs/api-reference.md` (sidebar/inspector handle sections)

- [ ] **Step 1: Find the documented handle methods**

```bash
cd /Users/zach/code/zapp
grep -n "setCollapsible\|setResizable" docs/api-reference.md
```
Locate the `setCollapsible` / `setResizable` descriptions for both the sidebar and inspector handles.

- [ ] **Step 2: Add the iOS no-op note**

For each of `setCollapsible` and `setResizable` (sidebar + inspector) in `docs/api-reference.md`, append a platform note, e.g.:
```markdown
> **iOS:** no-op. iOS sidebar/inspector collapse is size-class–driven and there is no divider-drag affordance to gate, so these are macOS-only. `setWidth()` still works programmatically on iOS.
```
Match the file's existing note/callout style (check how other macOS-only items are flagged nearby and mirror it). Keep it tight and factual.

- [ ] **Step 3: Verify + commit**

`bun run check` (docs change shouldn't affect it, but confirm exit 0).
```bash
cd /Users/zach/code/zapp
git add docs/api-reference.md
git commit -m "docs: setCollapsible/setResizable are macOS-only (iOS no-op)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: presentation enum honesty + runtime `setPresentation`

Multi-layer: native (iOS honest mapping + new op; macOS no-op parity), router route, TS handle, kitchen-sink toggle.

**Files:**
- Modify: `native/platform/ios/window.m` (split-setup presentation mapping, ~line 277)
- Modify: `native/platform/ios/sidebar.m` (new `darwin_sidebar_set_presentation`)
- Modify: `native/platform/darwin/sidebar.m` (no-op `darwin_sidebar_set_presentation` for symbol parity)
- Modify: `native/nim/router.nim` (importc decl + `sidebar:setPresentation` arm + read `mode`)
- Modify: `runtime/window.ts` (SidebarHandle `setPresentation` + interface)
- Modify: `kitchen-sink/src/sections/sidebar.ts` (presentation toggle buttons)

**Interfaces produced:**
- `void darwin_sidebar_set_presentation(int32_t window_id, const char* mode)` — `mode` ∈ `"automatic"|"tile"|"overlay"`. iOS sets `preferredSplitBehavior` (+ `preferredDisplayMode`) + relayout; macOS no-op.
- TS: `SidebarHandle.setPresentation(mode: "automatic" | "tile" | "overlay"): void` → `windowAction("sidebar:setPresentation", { windowId, mode })`.
- Router: `"sidebar:setPresentation"` arm reading `a{"mode"}.getStr("automatic")`.

- [ ] **Step 1: Make the create-time presentation mapping honest (iOS)**

In `native/platform/ios/window.m`, the split-setup currently only branches `"overlay"` (~line 277):
```objc
            if (d->sidebarPresentation && strcmp(d->sidebarPresentation, "overlay") == 0) {
                split.preferredSplitBehavior = UISplitViewControllerSplitBehaviorOverlay;
                split.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
            }
```
Replace with an explicit three-way mapping (`Default`/empty → `.automatic`, `tile` → `.tile`, `overlay` → `.overlay`):
```objc
            // Sidebar presentation → UISplitViewController split behavior.
            // Default/"" => .automatic (Apple adapts by size). "tile" forces
            // side-by-side; "overlay" floats over content (dims, tap-out dismiss).
            const char* sp = d->sidebarPresentation;
            if (sp && strcmp(sp, "overlay") == 0) {
                split.preferredSplitBehavior = UISplitViewControllerSplitBehaviorOverlay;
                split.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
            } else if (sp && strcmp(sp, "tile") == 0) {
                split.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
            } else {
                split.preferredSplitBehavior = UISplitViewControllerSplitBehaviorAutomatic;
            }
```
(Leaves the existing `preferredDisplayMode` set for the non-collapsed/tile case above this block intact; only the overlay branch overrides it.)

- [ ] **Step 2: Add `darwin_sidebar_set_presentation` (iOS)**

In `native/platform/ios/sidebar.m`, add a runtime op next to the other control ops (e.g. after `darwin_sidebar_set_width`). It resolves the controller, maps the mode string, sets `preferredSplitBehavior` (+ displayMode for overlay), and forces a relayout:
```objc
// Runtime sidebar presentation switch (A2). mode: "automatic" | "tile" | "overlay".
void darwin_sidebar_set_presentation(int32_t window_id, const char* mode) {
    zapp_ios_sidebar_on_main(^{
        ZappIOSSidebarController* c = zapp_ios_sidebar_for_slot(window_id);
        if (!c || !c.splitVC || !mode) return;
        if (strcmp(mode, "overlay") == 0) {
            c.splitVC.preferredSplitBehavior = UISplitViewControllerSplitBehaviorOverlay;
        } else if (strcmp(mode, "tile") == 0) {
            c.splitVC.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
        } else {
            c.splitVC.preferredSplitBehavior = UISplitViewControllerSplitBehaviorAutomatic;
        }
        [c.splitVC.view setNeedsLayout];
        [c.splitVC.view layoutIfNeeded];
    });
}
```
(Use the same controller-lookup + `zapp_ios_sidebar_on_main` pattern as `darwin_sidebar_set_width`. Do NOT force `preferredDisplayMode` here — let the behavior change drive layout, so a currently-shown sidebar isn't yanked closed.)

- [ ] **Step 3: Add the macOS no-op (symbol parity)**

In `native/platform/darwin/sidebar.m`, add a no-op so the symbol exists on both platforms (the iOS parity lint #637 + the shared router require it; macOS `NSSplitViewController` tiles/collapses and never overlays — presentation is iOS-only, already documented as ignored elsewhere):
```objc
// Presentation (tile/overlay/automatic) is an iOS UISplitViewController concept;
// AppKit's NSSplitViewController tiles and never overlays. No-op on macOS.
void darwin_sidebar_set_presentation(int32_t window_id, const char* mode) {
    (void)window_id; (void)mode;
}
```

- [ ] **Step 4: Router arm + importc decl (Nim)**

In `native/nim/router.nim`: add the importc declaration near the other sidebar importc decls (e.g. by `darwin_sidebar_set_width` ~line 127):
```nim
proc darwin_sidebar_set_presentation(windowId: int32, mode: cstring) {.importc, cdecl.}
```
Then in the sidebar action arm (the `case action` block, after `of "sidebar:setResizable": …` ~line 597), add:
```nim
    of "sidebar:setPresentation": darwin_sidebar_set_presentation(target, a{"mode"}.getStr("automatic").cstring)
```
(`a` is the action-args JsonNode already in scope — it's read for `width`/`value` just above. `getStr("automatic")` defaults to automatic for a missing/empty mode.)

- [ ] **Step 5: TS SidebarHandle method + interface**

In `runtime/window.ts`, add to the `SidebarHandle` interface (after `setResizable`, ~line 1046):
```ts
  /** Switch the iPad sidebar split presentation at runtime. iOS-only;
   *  no-op on macOS (AppKit tiles, never overlays). */
  setPresentation(mode: "automatic" | "tile" | "overlay"): void;
```
And to the handle implementation (after `setResizable`, ~line 1213):
```ts
    setPresentation(mode: "automatic" | "tile" | "overlay") { windowAction("sidebar:setPresentation", { windowId, mode }); },
```

- [ ] **Step 6: Kitchen-sink presentation toggle**

In `kitchen-sink/src/sections/sidebar.ts`, add three presentation buttons to the button list (alongside `Width 180`/`Width 320`/`Collapsible`/`Resizable`, ~line 19) and wire their handlers to `win.sidebar?.setPresentation(...)`. Read the exact button-list + handler shape first and match it; the buttons are:
```ts
          { act: "presAuto", label: "Auto" },
          { act: "presTile", label: "Tile" },
          { act: "presOverlay", label: "Overlay" },
```
with handlers (matching the existing `act` dispatch switch/handlers in the file):
```ts
      win.sidebar?.setPresentation("automatic"); // presAuto
      win.sidebar?.setPresentation("tile");      // presTile
      win.sidebar?.setPresentation("overlay");   // presOverlay
```
(Wire each into the file's existing action-dispatch structure exactly as the `w180`/`w320` buttons are wired.)

- [ ] **Step 7: Gates**

```bash
cd /Users/zach/code/zapp
bun run check
bun test cli/src
cd kitchen-sink && bun run build            # macOS
cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios
```
Expected: check exit 0; `bun test cli/src` all pass (incl. the iOS parity lint, now that `darwin_sidebar_set_presentation` exists on both platforms); both builds `[zapp] build complete:`. (No pure-function unit test is warranted — the change is passthrough plumbing; coverage is the parity lint + builds + the T6 smoke.)

- [ ] **Step 8: Commit**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/window.m native/platform/ios/sidebar.m native/platform/darwin/sidebar.m native/nim/router.nim runtime/window.ts kitchen-sink/src/sections/sidebar.ts
git commit -m "feat(ios): honest sidebar presentation enum + runtime setPresentation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: iPad split presentation (RISK GATE) + HUMAN SMOKE

**REQUIRED SUB-SKILL for the investigation:** superpowers:systematic-debugging (root-cause before any fix). This task is sim-dependent debugging, not pre-codeable — the three items are independently deferrable: if one is stubborn across a couple of smoke rounds, ship the rest and split it to a follow-up task; do not block the others.

**Files (expected, confirm during investigation):** `native/platform/ios/window.m` (split setup), `native/platform/ios/sidebar.m` (controller/ops), possibly `kitchen-sink/src/style.css` (overlay dim if CSS-side).

- [ ] **Step 1: T6a — landscape iPad won't tile under `.automatic`**

Ground truth (user smoke 2026-06-26): with `presentation: Default` (→ `.automatic`), the iPad sidebar is an **overlay in BOTH orientations**, not tile-in-landscape. Goal: `.automatic` actually adaptive (tile when wide / overlay when narrow). Investigate on sim (Phase 1 root cause before any fix): instrument/inspect the split's `preferredDisplayMode`, `preferredSplitBehavior`, and `displayMode` (resolved) at materialize and after rotation. Candidate causes to confirm or rule out: `preferredDisplayMode` left at `SecondaryOnly`; a startup collapse op; the `.doubleColumn` + `UINavigationController`-wrapped column composition forcing overlay; column-width math (300pt primary + secondary min) on the test device. Use `setPresentation("tile")` (Task 5) as the diagnostic: if forcing `.tile` produces side-by-side, the behavior plumbing works and the issue is automatic-resolution; if not, the issue is deeper (column composition). Fix at root cause; verify tile-in-landscape / overlay-in-portrait.

- [ ] **Step 2: T6b — overlay dim + tap-outside-dismiss (portrait)**

The portrait/overlay sidebar doesn't dim the content or collapse on tap-out (Apple's native overlay does). Root-cause (likely the full-bleed content WKWebView sitting above UIKit's dimming view and swallowing the tap, or the displayMode/behavior combo). Restore native dim + tap-out-collapse (may be a view-ordering fix, enabling the system dimming, or a tap-gesture on the content that calls `darwin_sidebar_show_content`). Verify the overlay dims + tap-out dismisses.

- [ ] **Step 3: T6c — `setWidth` re-assert after the reveal gesture**

After the swipe-reveal gesture, `setWidth` stops applying (matrix §2 "fails after a manual drag"). Re-assert `preferredPrimaryColumnWidth` + force layout (and/or clear the user-driven state) so `setWidth` holds post-gesture. May resolve as a side effect of T6a — verify after T6a lands; if already fixed, note it and skip.

- [ ] **Step 4: Build-verify each fix**

After each item that lands: `cd kitchen-sink && bun run build --platform ios` (+ macOS build green). Commit per item with a clear message + the trailer (per-file `git add`). For any item deferred, record it (ledger + a follow-up task) rather than leaving it half-done.

- [ ] **Step 5: Full gates**

```bash
cd /Users/zach/code/zapp
bun run check
bun test cli/src
cd kitchen-sink && bun run build
cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios
```
Expected: check exit 0; `bun test cli/src` pass; both builds `[zapp] build complete:`.

- [ ] **Step 6: HUMAN SMOKE (device/sim — pause)**

STOP. Ask the human to smoke on iPhone + iPad, **both orientations**, and confirm:
1. **#714 (T1):** Sidebar section → `Width 180` / `Width 320` updates the inspector pane's "width N" readout on iPad.
2. **Inspector sheet (T2):** iPhone landscape — the inspector sheet can still be dismissed (swipe or grabber).
3. **Sidebar-pane spacing (T3):** the sidebar header sits correctly under the status bar on iPhone; no top-gap on iPad.
4. **setPresentation (T5):** the Auto/Tile/Overlay toggle flips the iPad sidebar live.
5. **T6a:** landscape iPad tiles (side-by-side); portrait overlays.
6. **T6b:** portrait overlay dims the content + tap-outside dismisses.
7. **T6c:** `setWidth` holds after using the reveal gesture.

Do not consider A2 complete until 1–4 + whatever T6 items landed are confirmed. Any unmet T6 item → split to a follow-up task; ship the rest. After the gate: update the program matrix (mark the A2 rows), close #714, note any T6 follow-ups + what's next.

---

## Self-Review

**Spec coverage:** T1 #714 width emit → Task 1; T2 iPhone sheet dismiss → Task 2; T3 sidebar-pane safe-area → Task 3; T4 collapsible/resizable docs → Task 4; T5 presentation enum honesty + runtime `setPresentation` + KS toggle → Task 5; T6a/b/c risk gate + human smoke → Task 6. Non-goals (real collapsible-gating, safe-area seed, multi-window, macOS behavior) untouched. ✓

**Placeholder scan:** Tasks 1–5 carry exact before/after code. Task 6 is intentionally an investigation (systematic-debugging) with concrete starting hypotheses + diagnostic lever (`setPresentation("tile")`) + the smoke checklist — appropriate for a risk gate; it has no invented code. Task 5 Step 6 (KS buttons) instructs matching the file's exact existing dispatch shape rather than guessing it, since that structure wasn't quoted — flagged so the implementer reads it first.

**Type/signature consistency:** `darwin_sidebar_set_presentation(int32_t, const char*)` defined on iOS (Task 5 Step 2) + macOS (Step 3), declared in Nim `importc` (Step 4), consumed by router arm (Step 4) and the TS `setPresentation(mode)` → `windowAction("sidebar:setPresentation", { windowId, mode })` (Step 5) → router `a{"mode"}.getStr("automatic")` (Step 4). Mode values `"automatic"|"tile"|"overlay"` consistent across TS, router default, and both native switches. `zapp_ios_sidebar_emit_data`/`_emit_resize` (Task 1) reused only within sidebar.m. The `{"width":N}` payload matches the inspector + the `bareWidth` consumer (verified read-only in Task 1 Step 4).
