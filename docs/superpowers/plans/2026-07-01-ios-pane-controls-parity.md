# iOS Pane Controls Parity (FU-3 + FU-1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the iOS inspector's control surface (create-time options + runtime setters) to full parity with what the native Inspector-column allows — warning once, never silently no-op'ing, where UIKit genuinely can't — and root-cause + fix the iPad content-bleed (FU-1).

**Architecture:** The runtime→router→Nim plumbing already exists for every control on both panes; all changes are in the iOS native layer (`native/platform/ios/window.m` + `inspector.m` + `sidebar.m`) plus a TS typing nit and Nim comment fixes. The iOS 26 SDK read (done at plan time, citations below) resolved the wireable-vs-warn map, so the wiring tasks are fully concrete. FU-1 remains genuinely unknown and gets an instrument→observe→fix pair of tasks with a human smoke between them.

**Tech Stack:** ObjC/UIKit (`native/platform/ios/*.m`), Nim accessors (already exist), TypeScript runtime typing, Bun.

## Global Constraints

- Branch `feat/ios-native-nav` (UNMERGED). NO worktree, NO `git commit --amend`, NO merge.
- **macOS MUST NOT regress.** `native/platform/darwin/*` untouched. Every native task verifies the macOS build still completes.
- **NO iOS-simulator interaction in-session.** The human runs every smoke. A build is complete only on a `[zapp] build complete:` line AND a fresh binary mtime — never Vite `✓ built` alone.
- **Per-file `git add` only** — never `-A`/`.`. Pre-existing unrelated WIP (`kitchen-sink/src/sections/multiwindow.ts`, `kitchen-sink/src/sections/sidebar.ts`, `native/nim/router.nim`, `native/platform/ios/toolbar.m`, `native/platform/ios/webview.m`, assets, spikes, vendor) stays UNSTAGED.
- **Commit trailer `<TRAILER>`** — every commit ends with EXACTLY these two lines (expand verbatim):
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01DZ9M515fEUqt9EE2oFDyyv
  ```
- Always Bun, never Node.
- iOS symbol-parity gate stays green: `cd /Users/zach/code/zapp && bun test cli/src/ios-platform-parity.test.ts`.
- Sidebar iOS ownership semantics are kept as-is; the `<26` modal-sheet behavior is unchanged; the no-sidebar+inspector edge stays deferred.

**Verification commands (used throughout):**
- iOS-sim build: `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios-simulator` → `[zapp] build complete:` + fresh `.app` binary mtime.
- macOS regression build: `cd /Users/zach/code/zapp/kitchen-sink && bun run build` → `[zapp] build complete:`.
- Parity: `cd /Users/zach/code/zapp && bun test cli/src/ios-platform-parity.test.ts`.
- TS: `cd /Users/zach/code/zapp && bun test runtime/window.test.ts` and `bun run check`.

---

## P0(a) — RESOLVED AT PLAN TIME: the wireable-vs-warn map

Read from `$(xcrun --sdk iphonesimulator --show-sdk-path)/System/Library/Frameworks/UIKit.framework/Headers/UISplitViewController.h` (SDK 26.5):

| Control | Classification | Mechanism (header line) |
|---|---|---|
| `width` | already wired | `preferredInspectorColumnWidth` (:201, ios 26.0; takes precedence over the Fraction variant :200) |
| `minWidth` | **WIREABLE-direct** | `minimumInspectorColumnWidth` (:204, ios 26.0, default `UISplitViewControllerAutomaticDimension`) |
| `maxWidth` | **WIREABLE-direct** | `maximumInspectorColumnWidth` (:207, ios 26.0, default `UISplitViewControllerAutomaticDimension`) |
| `resizable` | **WIREABLE-via-ownership** | no drag-gate knob exists; `false` = pin `minimumInspectorColumnWidth == maximumInspectorColumnWidth == live width` (the sidebar's proven pattern, `ios/sidebar.m:996-1035`); `true` = restore configured min/max |
| `collapsible` | **WARN** | no per-column user-collapse affordance in the header (`presentsWithGesture` :128 governs the primary column only); programmatic `expand`/`collapse`/`toggle` always work |

Also relevant: `minimumSecondaryColumnWidth` (:193, ios 26.0) — a content-width floor, a candidate lever for FU-1 Branch A.

Warn rules derived from Nim defaults (`native/nim/window.nim:145-155`: `minWidth=180`, `maxWidth=400` are ALWAYS materialized, so >0 cannot distinguish "app set it" from default): create-time warns fire only for the explicitly-non-default booleans (`collapsible:false`, `resizable:false`) on the unusable (`<26`/no-split) path; min/max never warn at create; runtime setter calls always warn on the unusable path (an explicit call is always intentional).

---

## File Structure

- `native/platform/ios/inspector.m` — warn helper (new fn), controller config props (new), register widening + option application, real `set_resizable`, warn-`set_collapsible`, warn-`set_width`-on-sheet. (Tasks 1–4)
- `native/platform/ios/window.m` — `ZappIOSDeferred` inspector fields, populate-block reads, register extern + call. (Task 3)
- `native/platform/ios/sidebar.m` — FU-1 fix (if Branch B) + stale comment fix at :733-735. (Task 2)
- `runtime/window.ts` + `runtime/window.test.ts` — `INSPECTOR_RESIZED` typed overload + test. (Task 5)
- `native/nim/window.nim` — two stale comment lines (:281, :294). (Task 5)
- `docs/api-reference.md` — inspector controls-on-iOS bullets. (Task 5)

---

## Phase A — FU-1 (instrument → observe → fix)

### Task 1: FU-1 instrumentation build (model: Sonnet 5)

**Files:**
- Modify: `native/platform/ios/inspector.m` (temporary instrumentation — removed in Task 2)

**Interfaces:**
- Consumes: `ZappIOSInspectorController` (`inspectorNav`, `contentVC`, `contentWebview` props, `inspector.m:64-78`); `darwin_inspector_expand`/`collapse`/`toggle` bodies.
- Produces: `[zapp-nav] FU1 ...` log lines the human smoke captures. No behavior change.

- [ ] **Step 1: Add the dump helper** (top of `inspector.m`, after the registry statics ~line 100):

```objc
// TEMPORARY FU-1 instrumentation (removed once the root cause lands).
// Frames logged in each view's own coordinate space — widths are what matter.
static void zapp_ios_fu1_dump(ZappIOSInspectorController* c, const char* tag) {
    UISplitViewController* split = c.contentVC.splitViewController;
    BOOL showing = NO;
    if (@available(iOS 26.0, *)) {
        if (split) showing = [split isShowingColumn:UISplitViewControllerColumnInspector];
    }
    fprintf(stderr,
        "[zapp-nav] FU1 %s: splitW=%.0f secondaryW=%.0f webviewW=%.0f inspNavW=%.0f showing=%d behavior=%ld mode=%ld\n",
        tag,
        split ? split.view.bounds.size.width : -1.0,
        c.contentVC.view.bounds.size.width,
        c.contentWebview ? c.contentWebview.bounds.size.width : -1.0,
        c.inspectorNav ? c.inspectorNav.view.bounds.size.width : -1.0,
        (int)showing,
        split ? (long)split.preferredSplitBehavior : -1L,
        split ? (long)split.displayMode : -1L);
}
```

- [ ] **Step 2: Call it around the 26+ show/hide transitions.** In `darwin_inspector_expand`'s 26+ `showColumn:` branch and `darwin_inspector_collapse`'s 26+ `hideColumn:` branch, immediately after the `showColumn:`/`hideColumn:` call add:

```objc
zapp_ios_fu1_dump(c, "immediate");
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
               dispatch_get_main_queue(), ^{ zapp_ios_fu1_dump(c, "settled"); });
```

- [ ] **Step 3: iOS-sim build.** Expect `[zapp] build complete:` + fresh mtime. Also run the macOS build (must complete — inspector.m is iOS-only, so this is a link sanity check) and the parity test.

- [ ] **Step 4: Commit.**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/inspector.m
git commit -m "chore(ios): temporary FU-1 frame instrumentation on inspector show/hide

<TRAILER>"
```

- [ ] **Step 5: GATE — hand the human the smoke sheet.** STOP. Ask the human to run on an **iPad** sim (`xcrun simctl install booted bin/ios/kitchen-sink.app && xcrun simctl launch --console booted com.zapp.kitchensink`), toggle the inspector open and closed in **landscape**, then in **portrait**, then (with the inspector open) tap the kitchen-sink sidebar **Tile** button and toggle once more — and paste all `[zapp-nav] FU1` lines plus whether the content visually reflowed or stayed cut off in each case.

### Task 2: FU-1 root-cause fix + de-instrument + stale comment (model: Fable 5)

**Files:**
- Modify: `native/platform/ios/inspector.m` (remove instrumentation; possibly the fix)
- Modify: `native/platform/ios/sidebar.m:733-735` (stale comment; possibly the fix)
- Possibly modify: `native/platform/ios/window.m` (only if the data demands a construction-order fix)

**Interfaces:**
- Consumes: the Task-1 gate data (the `settled` lines are authoritative — ignore `immediate` mid-animation values).
- Produces: content displaces (reflows) when the inspector column shows on iPad; instrumentation gone.

- [ ] **Step 1: Adjudicate with the decision table.** Compare the `settled` widths with the inspector SHOWING vs HIDDEN:

| Observation (settled) | Branch | Meaning |
|---|---|---|
| `secondaryW` UNCHANGED between hidden/showing | **A** — UIKit is overlaying, not displacing | split-level; Zapp's constraints are irrelevant |
| `secondaryW` shrinks but `webviewW` stays at the old (wider) value | **B** — the webview isn't following its container | Zapp constraint-level |
| both shrink and content still LOOKS cut off | **C** — native layout is correct; the bleed is CSS/viewport inside the webview | web-layer (report; fix is likely `viewport-fit`/CSS, coordinate with controller) |

- [ ] **Step 2: Apply exactly ONE branch fix.**

**Branch A (overlay):** first check the Tile-button data point — if forcing `preferredSplitBehavior=Tile` made it displace, the automatic behavior is choosing an overlay arrangement for the inspector at this width. Candidate fix (apply, then re-gate): give UIKit the content floor so it can justify displacing —

```objc
// In zapp_ios_inspector_register's 26+ split branch (inspector.m ~211-215),
// alongside preferredInspectorColumnWidth:
split.minimumSecondaryColumnWidth = 320.0;  // content floor: displace, don't overlay, while content fits
```

If the re-gate still overlays, escalate to the controller with the data — do NOT stack further speculative fixes (that's a design conversation, possibly "overlay IS the correct adaptive behavior at this width" and FU-1 reduces to a docs note).

**Branch B (webview not following):** verify `zapp_ios_sidebar_set_content_webview` (`ios/sidebar.m:709-748`) actually ran for this window (add a one-shot log if needed): the known risk is ordering — it must run AFTER the webview exists and its constraints must be the active ones. The fix is to make the install unconditional and idempotent at the true call site in `window.m` (the `16c0d49` guard-drop was commit-verified but never smoke-verified under a visible inspector). Ensure `wv.translatesAutoresizingMaskIntoConstraints = NO` and the top/bottom/trailing/leading constraints from `sidebar.m:731-748` are active for the content webview on inspector windows.

**Branch C:** no native change; document findings in the report and surface to the controller (web-layer follow-up).

- [ ] **Step 3: Remove ALL Task-1 instrumentation** (`zapp_ios_fu1_dump` + both call sites + the `dispatch_after` blocks).

- [ ] **Step 4: Fix the stale comment** at `native/platform/ios/sidebar.m:733-735`. Replace:

```objc
        // Trailing stays at view.trailingAnchor — inspector.m will later
        // replace this constraint if an inspector is registered.
```

with:

```objc
        // Trailing stays at view.trailingAnchor. The Inspector column is a
        // SIBLING column of this (Secondary) container — UIKit resizes the
        // Secondary container itself when the Inspector column shows, and the
        // edge-pinned webview follows. inspector.m never touches these
        // constraints.
```

(If Branch A/B changed that mechanism, write what is actually true instead.)

- [ ] **Step 5: Builds + parity.** iOS-sim (`[zapp] build complete:` + fresh mtime), macOS, parity — all green.

- [ ] **Step 6: Commit** (`git add` exactly the files touched, per-file):

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/inspector.m native/platform/ios/sidebar.m   # + window.m only if touched
git commit -m "fix(ios): FU-1 — inspector column displaces content (root: <branch>); drop instrumentation

<TRAILER>"
```

- [ ] **Step 7: GATE — human re-smoke.** iPad landscape + portrait: open the inspector → content REFLOWS (text wraps narrower, nothing cut off at the divider); close → reflows back. Record PASS in the ledger before proceeding.

---

## Phase B — create-time parity + runtime setters

### Task 3: warn helper + create-time inspector parity (model: Sonnet 5)

**Files:**
- Modify: `native/platform/ios/inspector.m` (helper, controller props, register signature + application)
- Modify: `native/platform/ios/window.m` (`ZappIOSDeferred` fields ~:94-99, populate block :1002-1014, extern decl :323-327, call site :703-708, destroy — no new frees needed, all new fields are POD)

**Interfaces:**
- Consumes: existing Nim accessors `wopts_inspector_min_width` / `wopts_inspector_max_width` / `wopts_inspector_collapsible` / `wopts_inspector_can_resize` / `wopts_inspector_background_color` (`native/nim/window.nim:298-303`).
- Produces: `void zapp_ios_control_unsupported(const char* control, const char* reason)` (Task 4 reuses); widened `void zapp_ios_inspector_register(void* window, void* inspectorNav, void* contentVC, void* contentWebview, int32_t host_id, int32_t inspector_id, int32_t width, int32_t min_width, int32_t max_width, bool collapsed, bool collapsible, bool resizable)`; controller props `configuredMinWidth`/`configuredMaxWidth`/`resizable`/`collapsible` (Task 4 reads).

- [ ] **Step 1: Add the honesty helper** in `inspector.m` (above the registry section; exported, not static — future callers in other iOS files may extern it). All current call sites run on the main thread (inside `zapp_ios_inspector_on_main` blocks), so the bare `NSMutableSet` is safe; note that invariant in the comment:

```objc
// Honesty helper: a control that genuinely cannot work on iOS logs ONCE per
// control per process instead of silently no-op'ing. Callers still emit the
// usual parity event so JS-side state stays coherent. Main-thread only (all
// darwin_inspector_* ops hop through zapp_ios_inspector_on_main).
void zapp_ios_control_unsupported(const char* control, const char* reason) {
    static NSMutableSet<NSString*>* zapp_warned = nil;
    if (!zapp_warned) zapp_warned = [NSMutableSet set];
    NSString* key = [NSString stringWithUTF8String:control];
    if ([zapp_warned containsObject:key]) return;
    [zapp_warned addObject:key];
    NSLog(@"[zapp] %s is not supported on iOS: %s", control, reason);
}
```

- [ ] **Step 2: Widen `ZappIOSDeferred`** (window.m, after `inspectorCollapsed` :98):

```objc
    int32_t inspectorMinWidth;
    int32_t inspectorMaxWidth;
    bool    inspectorCollapsible;
    bool    inspectorResizable;
    bool    inspector_has_bg;
    int     inspector_bg_r, inspector_bg_g, inspector_bg_b;
```

- [ ] **Step 3: Read the dropped fields in the populate block** (window.m, extend :1002-1014 — mirrors the sidebar block :975-996 exactly; `material` is intentionally NOT read, matching the sidebar's iOS behavior where material is macOS-only):

```objc
        extern int32_t wopts_inspector_min_width(void* opts);
        extern int32_t wopts_inspector_max_width(void* opts);
        extern bool wopts_inspector_collapsible(void* opts);
        extern bool wopts_inspector_can_resize(void* opts);
        extern const char* wopts_inspector_background_color(void* opts);
        d->inspectorMinWidth   = wopts_inspector_min_width(opts);
        d->inspectorMaxWidth   = wopts_inspector_max_width(opts);
        d->inspectorCollapsible = wopts_inspector_collapsible(opts);
        d->inspectorResizable  = wopts_inspector_can_resize(opts);
        const char* ibg = wopts_inspector_background_color(opts);
        if (ibg && ibg[0] == '#' && strlen(ibg) >= 7 &&
            sscanf(ibg + 1, "%2x%2x%2x",
                   &d->inspector_bg_r, &d->inspector_bg_g, &d->inspector_bg_b) == 3) {
            d->inspector_has_bg = true;
        }
```

- [ ] **Step 4: Apply the backdrop at construction.** In the inspector pane block (window.m ~:648-651), replace `inspectorVC.view.backgroundColor = [UIColor systemBackgroundColor];` with the sidebar's pattern (:415-417):

```objc
            inspectorVC.view.backgroundColor = d->inspector_has_bg
                ? [UIColor colorWithRed:d->inspector_bg_r/255.0 green:d->inspector_bg_g/255.0
                                   blue:d->inspector_bg_b/255.0 alpha:1.0]
                : [UIColor systemBackgroundColor];
```

- [ ] **Step 5: Widen the register in LOCKSTEP** (all three sites in one edit pass; grep `zapp_ios_inspector_register` to confirm the single call site):
  - extern decl (window.m :323-327) and definition (inspector.m :188-191) become the `Produces:` signature above;
  - call site (window.m :703-708) passes `d->inspectorWidth, d->inspectorMinWidth, d->inspectorMaxWidth, d->inspectorCollapsed, d->inspectorCollapsible, d->inspectorResizable`.

- [ ] **Step 6: Store + apply in the register.** Add controller props (inspector.m, after `width` :74):

```objc
@property (nonatomic, assign) int32_t configuredMinWidth;  // minimumInspectorColumnWidth (0 = automatic)
@property (nonatomic, assign) int32_t configuredMaxWidth;  // maximumInspectorColumnWidth (0 = automatic)
@property (nonatomic, assign) BOOL resizable;              // divider-drag allowed (via min==max pin when NO)
@property (nonatomic, assign) BOOL collapsible;            // stored; no iOS user-collapse affordance to gate (WARN)
```

In `zapp_ios_inspector_register`'s body, after `c.width = ...`, store all four; then extend the existing 26+ `if (split)` branch (which already sets `preferredInspectorColumnWidth` and does the collapsed show/hide dance — keep both unchanged):

```objc
                if (!c.resizable && c.width > 0) {
                    // resizable:false at create — pin the column (ownership pattern,
                    // mirrors darwin_sidebar_set_width's frozen path).
                    split.minimumInspectorColumnWidth = (CGFloat)c.width;
                    split.maximumInspectorColumnWidth = (CGFloat)c.width;
                } else {
                    if (c.configuredMinWidth > 0)
                        split.minimumInspectorColumnWidth = (CGFloat)c.configuredMinWidth;
                    if (c.configuredMaxWidth > 0)
                        split.maximumInspectorColumnWidth = (CGFloat)c.configuredMaxWidth;
                }
                if (!c.collapsible) {
                    zapp_ios_control_unsupported("inspector.collapsible",
                        "the iOS Inspector column has no user-collapse affordance to gate; "
                        "programmatic collapse()/expand()/toggle() always work");
                }
```

On the `<26`/no-split path, warn ONLY for the explicitly-non-default booleans (min/max are always ≥ defaults and must stay silent — see the warn rules above):

```objc
            if (!c.resizable)
                zapp_ios_control_unsupported("inspector.resizable",
                    "below iOS 26 (or without a sidebar split) the inspector is a system modal sheet");
            if (!c.collapsible)
                zapp_ios_control_unsupported("inspector.collapsible",
                    "the iOS inspector sheet has no user-collapse affordance to gate; "
                    "programmatic collapse()/expand()/toggle() always work");
```

- [ ] **Step 7: Builds + parity.** iOS-sim + macOS + parity, all green. (No new Nim parse — no `test:native` change expected; run it anyway: `bun run test:native`.)

- [ ] **Step 8: Commit.**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/window.m native/platform/ios/inspector.m
git commit -m "feat(ios): inspector create-time parity — thread min/max/collapsible/resizable/backgroundColor; add zapp_ios_control_unsupported

<TRAILER>"
```

### Task 4: runtime setters — real setResizable, honest setCollapsible/setWidth (model: Sonnet 5)

**Files:**
- Modify: `native/platform/ios/inspector.m` (`darwin_inspector_set_width` :374-388, `set_collapsible` :390-395, `set_resizable` :397-402 — line numbers pre-Task-3; locate by symbol)

**Interfaces:**
- Consumes: Task 3's controller props + `zapp_ios_control_unsupported`; the sidebar live-width lock pattern (`ios/sidebar.m:996-1035`).
- Produces: `darwin_inspector_set_resizable`/`set_collapsible`/`set_width` final behavior (symbols unchanged — router.nim imports untouched).

- [ ] **Step 1: Replace `darwin_inspector_set_resizable`** (delete the no-op + its now-false "isn't a UIKit affordance" comment — the user drag-resizes the column seam today):

```objc
// Lock or unlock the inspector divider drag. resizable==false clamps
// minimumInspectorColumnWidth == maximumInspectorColumnWidth to the LIVE
// column width (a drag never updates c.width, so clamping to the configured
// value would snap the pane to a stale width — same rationale as
// darwin_sidebar_set_resizable). resizable==true restores the configured
// min/max (0 = UISplitViewControllerAutomaticDimension, the header default).
// <26 / no-split: the modal sheet has no divider — warn once, still store.
void darwin_inspector_set_resizable(int32_t window_id, bool resizable) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;
        c.resizable = (BOOL)resizable;

        if (@available(iOS 26.0, *)) {
            UISplitViewController* split = c.contentVC.splitViewController;
            if (split) {
                if (!resizable) {
                    CGFloat liveWidth = c.inspectorNav.view.bounds.size.width;
                    CGFloat lockWidth = (liveWidth > 0.0)
                        ? liveWidth
                        : ((c.width > 0) ? (CGFloat)c.width
                                         : split.preferredInspectorColumnWidth);
                    if (lockWidth > 0.0) {
                        split.minimumInspectorColumnWidth = lockWidth;
                        split.maximumInspectorColumnWidth = lockWidth;
                    }
                } else {
                    split.minimumInspectorColumnWidth = (c.configuredMinWidth > 0)
                        ? (CGFloat)c.configuredMinWidth
                        : UISplitViewControllerAutomaticDimension;
                    split.maximumInspectorColumnWidth = (c.configuredMaxWidth > 0)
                        ? (CGFloat)c.configuredMaxWidth
                        : UISplitViewControllerAutomaticDimension;
                }
                return;
            }
        }
        zapp_ios_control_unsupported("inspector.setResizable",
            "below iOS 26 (or without a sidebar split) the inspector is a system modal sheet");
    });
}
```

- [ ] **Step 2: Replace `darwin_inspector_set_collapsible`** (store + warn; programmatic ops keep working — sidebar semantics):

```objc
// There is no iOS user-collapse affordance on the Inspector column to gate
// (presentsWithGesture governs the primary column only — SDK header :128).
// Store the intent for state parity and warn once; darwin_inspector_toggle/
// collapse/expand ALWAYS keep working regardless (matches the sidebar's
// documented semantics).
void darwin_inspector_set_collapsible(int32_t window_id, bool can_collapse) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;
        c.collapsible = (BOOL)can_collapse;
        if (!can_collapse) {
            zapp_ios_control_unsupported("inspector.setCollapsible",
                "the iOS Inspector column has no user-collapse affordance to gate; "
                "programmatic collapse()/expand()/toggle() always work");
        }
    });
}
```

- [ ] **Step 3: Make `darwin_inspector_set_width` honest on the sheet path.** Keep the 26+ branch exactly as-is (including the emit); in the fall-through (`<26` or no split) case, add the warn BEFORE the existing `zapp_ios_inspector_emit_resize(c, width)` (the emit stays — JS state parity, spec decision):

```objc
        // (inside the on_main block, replacing the bare fall-through)
        bool applied = false;
        if (@available(iOS 26.0, *)) {
            UISplitViewController* split = c.contentVC.splitViewController;
            if (split && width > 0) {
                split.preferredInspectorColumnWidth = (CGFloat)width;
                applied = true;
            }
        }
        if (!applied) {
            zapp_ios_control_unsupported("inspector.setWidth",
                "below iOS 26 (or without a sidebar split) the inspector is a system modal sheet with no adjustable width");
        }
        zapp_ios_inspector_emit_resize(c, width);
```

- [ ] **Step 4: Builds + parity.** iOS-sim + macOS + parity green.

- [ ] **Step 5: Commit.**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/inspector.m
git commit -m "feat(ios): wire inspector setResizable (min==max pin); honest warns for setCollapsible + sheet-path setWidth

<TRAILER>"
```

### Task 5: free cleanups — TS typed overload, Nim comments, docs (model: Sonnet 5)

**Files:**
- Modify: `runtime/window.ts` (:21 import, :1186 overloads)
- Test: `runtime/window.test.ts`
- Modify: `native/nim/window.nim` (:281, :294 comments)
- Modify: `docs/api-reference.md` (inspector section)

**Interfaces:**
- Consumes: `InspectorResizedPayload` (`runtime/events.ts:182-186`, already exported).
- Produces: `win.on(WindowEvent.INSPECTOR_RESIZED, ...)` typed with `InspectorResizedPayload`.

- [ ] **Step 1: Failing-first check.** Add to `runtime/window.test.ts` (next to the :24 `SIDEBAR_RESIZED` assertion):

```ts
// INSPECTOR_RESIZED: wire name + typed on() overload (compile-level check).
expect(eventName(WindowEvent.INSPECTOR_RESIZED)).toBe("window:inspector-resized");
const _inspectorResizedTyped = (win: WindowHandle) =>
  win.on(WindowEvent.INSPECTOR_RESIZED, (p: InspectorResizedPayload) => void p.width);
void _inspectorResizedTyped;
```

(with `InspectorResizedPayload` + `WindowHandle` added to the test's imports). Run `bun run check` — expect FAIL: the handler parameter is not assignable because the call resolves to the generic `WindowPayload` overload.

- [ ] **Step 2: Add the overload.** In `runtime/window.ts`: add `InspectorResizedPayload` to the :21 type import, and after :1186 insert:

```ts
  on(event: WindowEvent.INSPECTOR_RESIZED, handler: (payload: InspectorResizedPayload) => void): () => void;
```

- [ ] **Step 3: Verify GREEN.** `bun test runtime/window.test.ts` + `bun run check` — both pass.

- [ ] **Step 4: Fix the stale Nim comments.** `native/nim/window.nim:281` → `# sidebar accessors — consumed by darwin/window.m + ios/window.m at create time; "" url short-circuits the sidebar branch.` and `:294` → `# inspector accessors — consumed by darwin/window.m + ios/window.m at create time; "" url short-circuits the branch.`

- [ ] **Step 5: Docs.** In `docs/api-reference.md`'s inspector section (the native-model table added in `bb21483`), add: on iOS 26+ the column honors `width`/`minWidth`/`maxWidth` and `resizable` (false locks the divider at the current width); `collapsible` has no user affordance to gate on iOS and logs a one-time console note (programmatic collapse/expand/toggle always work); below iOS 26 the inspector is a system modal sheet and width/resize/collapse knobs log the same one-time note.

- [ ] **Step 6: Full TS + native gates.** `bun test runtime/window.test.ts`, `bun run check`, `bun run test:native`, parity test — green.

- [ ] **Step 7: Commit.**

```bash
cd /Users/zach/code/zapp
git add runtime/window.ts runtime/window.test.ts native/nim/window.nim docs/api-reference.md
git commit -m "chore: INSPECTOR_RESIZED typed on() overload; fix stale accessor comments; document iOS inspector controls

<TRAILER>"
```

---

## Phase C — the matrix gate

### Task 6: full-matrix human smoke + macOS regression (verification only)

**Files:** none.

- [ ] **Step 1: Full build sweep.** iOS-sim build (`[zapp] build complete:` + fresh mtime), macOS build, parity test, `bun run test:native`, `bun test runtime/window.test.ts`, `bun run check` — all green.

- [ ] **Step 2: GATE — hand the human the matrix sheet.** iPhone + iPad sims, kitchen-sink (buttons already exist — sidebar section: Toggle / Width 180 / Width 320 / Collapsible / Resizable / Auto / Tile / Overlay; inspector section: Toggle / Width 360 / Collapsible / Resizable):
  - **iPad inspector:** Toggle shows/hides the column; Width 360 applies; **Resizable: off** → seam drag is locked at the current width, **on** → drag works again within min/max; **Collapsible** button → exactly ONE `[zapp] inspector.setCollapsible is not supported…` console line, toggle still works; create-time `collapsed:true` still starts hidden; FU-1: content REFLOWS when the column shows (both orientations).
  - **iPad sidebar (regression):** all eight buttons behave as before.
  - **iPhone:** inspector toggle → sheet with correct content; Width/Resizable/Collapsible buttons → one-time console notes (sheet path), no crashes; sidebar behaviors unchanged.
  - **Live-state readouts** (both sections' inspector panels) match what renders after every operation.
  - **macOS:** launch the macOS build; sidebar + inspector controls all still work (fully-wired platform — zero regression tolerance).
- [ ] **Step 3: Record.** On PASS append `FU-3/FU-1 MATRIX GATE: PASS` + per-item notes to `.superpowers/sdd/progress.md`. On FAIL, capture symptoms + `[zapp-nav]`/console lines and return to the relevant task.

---

## Self-Review

- **Spec coverage:** §2.1(a) map → resolved at plan time (recorded above with header citations); §2.1(b) FU-1 → Tasks 1-2; §2.2 create-time parity (6 fields; material explicitly follows the sidebar's macOS-only precedent) → Task 3; §2.3 setters + honesty helper + free cleanups → Tasks 4-5; §2.4 matrix gate + macOS regression → Task 6; spec §3 OUT-list respected (no darwin/* edits, no sheet-behavior change, no-sidebar edge untouched).
- **Placeholder scan:** none — the only conditional content is Task 2's branch fixes, each carrying complete code plus an explicit escalate-don't-stack rule (inherent to a root-cause task).
- **Type consistency:** the widened register signature is identical in Task 3's decl/call/definition steps; `configuredMinWidth`/`configuredMaxWidth`/`resizable`/`collapsible` names match between Task 3 (defines) and Task 4 (consumes); `zapp_ios_control_unsupported(const char*, const char*)` identical at every call site; `darwin_inspector_*` symbol names unchanged (router.nim imports untouched).
