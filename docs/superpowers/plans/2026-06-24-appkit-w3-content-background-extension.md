# AppKit W3 — Content Background Extension — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add a create-time, sidebar-edge `backgroundExtension` window option (`None`/`Extend`/`Mirror`) so content can flow under the floating Liquid Glass sidebar, with `NSBackgroundExtensionView` mirroring full-bleed content behind the glass — macOS 26-gated with a `None` fallback, plus a safe-area CSS-injection companion so web content lays out correctly.

**Architecture:** macOS chrome is AppKit (`NSSplitViewController`); the sidebar already renders native floating glass. This adds (a) a config enum threaded TS→Nim→native, (b) native content-pane wiring (`automaticallyAdjustsSafeAreaInsets` for Extend, `NSBackgroundExtensionView` for Mirror), and (c) safe-area/corner CSS vars injected into the content webview, re-injected on sidebar collapse/resize. Inspector out of scope by design.

**Tech Stack:** TypeScript (runtime), Nim + Objective-C (native macOS), `bun:test`. Spec: `docs/superpowers/specs/2026-06-24-appkit-w3-content-background-extension-design.md`.

**Branch:** `feat/nim-native` (keep UNMERGED). **Commit trailer:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

**CRITICAL — staging discipline:** the working tree has UNRELATED pre-existing changes (`assets/`, `benchmarks/`, `vendor/`, `spikes/`, `kitchen-sink/zapp/app.nim`, `native/worker/engines/zjs-cross-eval-test.c`, untracked files). **Never `git add -A`/`git add .`** — stage only the explicit files each task changes.

**Verify commands:**
- Unit: `cd /Users/zach/code/zapp && bun test runtime cli/src`
- macOS build: `cd /Users/zach/code/zapp/kitchen-sink && bun run build` — success = last line `[zapp] build complete: …` + fresh `bin/kitchen-sink` mtime (Vite `✓ built` is NOT success).
- iOS-sim build: `cd /Users/zach/code/zapp/kitchen-sink && bun run build --platform ios`
- Run (human smoke): `cd /Users/zach/code/zapp/kitchen-sink && bun run dev`

---

## Task 1: RISK GATE — `NSBackgroundExtensionView` + `WKWebView` viability (human visual)

**Goal:** Prove a live content `WKWebView` survives inside `NSBackgroundExtensionView` and the mirror renders behind the floating sidebar, BEFORE building the config surface. Scratch wiring — superseded by T3.

**Files:** Modify (scratch): `native/platform/darwin/window.m`

- [ ] **Step 1: Scratch-wire the content pane**

In `window.m`, in the content-pane construction (immediately before `contentItem = [NSSplitViewItem splitViewItemWithViewController:contentVC]` at ~`:887`), add a temporary unconditional spike:

```objc
// SPIKE (T1, remove after gate): prove NSBackgroundExtensionView hosts a live WKWebView.
if (useSidebar) {
    if (@available(macOS 26.0, *)) {
        NSBackgroundExtensionView* bev = [[NSBackgroundExtensionView alloc] initWithFrame:contentVC.view.bounds];
        bev.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        bev.contentView = contentVC.view;   // the mainContainer holding the webview
        NSViewController* wrap = [[NSViewController alloc] init];
        wrap.view = bev;
        contentVC = wrap;
    }
}
```
(If the exact `NSBackgroundExtensionView` API differs from the talk — `contentView` property / init — adjust to the macOS 26 SDK; the SDK header is the source of truth. Also set `contentItem.automaticallyAdjustsSafeAreaInsets = YES` after the item is created.)

- [ ] **Step 2: Point kitchen-sink at full-bleed content**

Temporarily give the kitchen-sink main content a full-bleed background (e.g. a CSS gradient or image filling the viewport) so the mirror is visible behind the sidebar. Note where you changed it (revert in Step 5).

- [ ] **Step 3: Build + human smoke (GATE)**

Run: `cd /Users/zach/code/zapp/kitchen-sink && bun run build` → `[zapp] build complete:`.
Then `bun run dev`. **Human confirms:**
1. Mirror/blur of the content appears behind the floating sidebar.
2. The content webview still renders, scrolls, and takes clicks/input.
3. Collapsing/resizing the sidebar changes the content's safe area (content shifts / mirror region changes).

- [ ] **Step 4: Record the verdict**

- **GO** → all three modes proceed (T2 includes `Mirror`).
- **NO-GO** (webview breaks or no mirror) → `Mirror` is dropped from the enum in T2/T3; ship `None`/`Extend` only; document the limitation + a follow-up. Record which.

- [ ] **Step 5: Revert the scratch**

`git checkout native/platform/darwin/window.m` and revert the kitchen-sink content change. Nothing from T1 is committed (it's a spike). Confirm `git status` shows no T1 residue.

---

## Task 2: Config surface — `BackgroundExtension` enum (TS + Nim) + parse

**Files:**
- Modify: `runtime/window.ts` (const enum + `WindowOptions.backgroundExtension`)
- Modify: `native/nim/coretypes.nim` (Nim enum) — confirm this is where `Material` lives; if `Material` is elsewhere, co-locate.
- Modify: `native/nim/window.nim` (`WindowOptions` field + parse + string getter)
- Test: `native/nim/*` (zc-run/Nim unit if present) and/or `runtime` bun test for the type

**Naming note:** use `BackgroundExtension` (NOT `ContentBackground`) — `Material` already has a `ContentBackground` member (vibrancy material name); reusing it would collide/confuse.

- [ ] **Step 1: TS const enum + field (`runtime/window.ts`)**

After the `Material` const block, add:

```ts
/**
 * Content-pane background behavior relative to the floating sidebar (macOS 26+).
 * `None` = content beside the sidebar (default). `Extend` = content flows under the
 * floating sidebar; lay out with the injected `--zapp-safe-area-*` CSS vars. `Mirror`
 * = NSBackgroundExtensionView mirrors/blurs content behind the glass (full-bleed media).
 * Extend/Mirror fall back to `None` on macOS < 26. Sidebar-edge only.
 */
export const BackgroundExtension = {
  None: "none",
  Extend: "extend",
  Mirror: "mirror",
} as const;
export type BackgroundExtension = (typeof BackgroundExtension)[keyof typeof BackgroundExtension];
```

In `WindowOptions`, add (near the sidebar options):
```ts
  /** macOS 26+. How the content pane's background relates to the floating sidebar.
   *  Default `None`. Extend/Mirror fall back to `None` on older macOS. Create-time. */
  backgroundExtension?: BackgroundExtension;
```

- [ ] **Step 2: Nim enum (`coretypes.nim`)**

Add alongside the existing enums (match the string-valued style of `Material`):
```nim
type BackgroundExtension* {.pure.} = enum
  None = "none"
  Extend = "extend"
  Mirror = "mirror"
```

- [ ] **Step 3: Nim `WindowOptions` field + parse + getter (`window.nim`)**

Add field to the `WindowOptions` object: `backgroundExtension*: BackgroundExtension` (defaults to `BackgroundExtension.None`).

In `windowOptsApplyJson` (alongside the other `jHasStr` parses ~`:446+`):
```nim
if jHasStr(a, "backgroundExtension"):
  o.backgroundExtension = enumFromStr[BackgroundExtension](jStr(a, "backgroundExtension"), BackgroundExtension.None)
```

Add a persistent string table + getter mirroring the `materialStr` pattern (`:172`/`:225`) so the returned `cstring` isn't a dangling temporary:
```nim
let backgroundExtensionStr = [BackgroundExtension.None: "none", BackgroundExtension.Extend: "extend", BackgroundExtension.Mirror: "mirror"]
proc wopts_background_extension(p: pointer): cstring {.exportc, cdecl.} =
  backgroundExtensionStr[opt(p).backgroundExtension].cstring
```

- [ ] **Step 4: Unit coverage**

Add a parse test (follow the existing `windowOptsApplyJson` / toolbar parse tests): `backgroundExtension: "mirror"` → `BackgroundExtension.Mirror`; absent → `None`; unknown string → `None`.

- [ ] **Step 5: Verify + commit**

Run: `cd /Users/zach/code/zapp && bun test runtime cli/src` (+ the Nim unit if applicable) → pass.
Run the macOS build → `[zapp] build complete:` (getter compiles, unused-by-native is fine).

```bash
git add runtime/window.ts native/nim/coretypes.nim native/nim/window.nim
# + any added test file (stage it explicitly)
git commit -m "$(cat <<'EOF'
feat(window): BackgroundExtension option (None/Extend/Mirror) — TS+Nim surface

Add the backgroundExtension WindowOptions enum threaded TS→Nim with a
string getter for native. Pass-through only; native wiring lands in the
next task. Named BackgroundExtension to avoid the Material.ContentBackground
member collision.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Native wiring — content-pane Extend/Mirror (`window.m`)

**Files:** Modify: `native/platform/darwin/window.m`

- [ ] **Step 1: Read the resolved mode + gate**

In the content-pane construction (~`:828-888`), after `contentVC` is built and before `contentItem` is created, add:

```objc
extern const char* wopts_background_extension(void* opts);
const char* bgExt = wopts_background_extension(opts);   // "none" | "extend" | "mirror"
bool wantExtend = bgExt && (strcmp(bgExt, "extend") == 0 || strcmp(bgExt, "mirror") == 0);
bool wantMirror = bgExt && strcmp(bgExt, "mirror") == 0;
// NO-GO from T1: if Mirror was dropped, force wantMirror = false here + note it.
if ((wantExtend) && useSidebar) {
    if (@available(macOS 26.0, *)) {
        if (wantMirror) {
            NSBackgroundExtensionView* bev = [[NSBackgroundExtensionView alloc] initWithFrame:contentVC.view.bounds];
            bev.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            bev.contentView = contentVC.view;     // mainContainer (holds the webview)
            NSViewController* wrap = [[NSViewController alloc] init];
            wrap.view = bev;
            contentVC = wrap;
        }
        // (automaticallyAdjustsSafeAreaInsets set on contentItem in Step 2)
        clog(1, "[zapp] backgroundExtension: %s (macOS 26)", bgExt);
    } else {
        clog(1, "[zapp] backgroundExtension: %s requested, falling back to none (macOS < 26)", bgExt);
    }
}
```
(Use the exact `NSBackgroundExtensionView` API proven in T1.)

- [ ] **Step 2: Set the safe-area inset on the content item**

After `contentItem = [NSSplitViewItem splitViewItemWithViewController:contentVC];` (~`:887`):
```objc
if (wantExtend) {
    if (@available(macOS 26.0, *)) contentItem.automaticallyAdjustsSafeAreaInsets = YES;
}
```

- [ ] **Step 3: Build (macOS + iOS-sim)**

macOS build → `[zapp] build complete:`. iOS-sim build → success (this option is darwin-only; `wopts_background_extension` is consumed only in `window.m`, so no shared-symbol iOS gap — confirm the iOS build stays green).

- [ ] **Step 4: Commit**

```bash
git add native/platform/darwin/window.m
git commit -m "$(cat <<'EOF'
feat(macos): wire backgroundExtension content-pane (Extend/Mirror)

macOS 26: Extend sets contentItem.automaticallyAdjustsSafeAreaInsets so
content flows under the floating sidebar; Mirror additionally wraps the
content pane in NSBackgroundExtensionView. <26 → none (logged). Sidebar-edge.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Safe-area + corner CSS injection (`toolbar.m` + `sidebar.m`)

**Files:** Modify: `native/platform/darwin/toolbar.m` (extend the injected JS), `native/platform/darwin/sidebar.m` (re-inject trigger)

- [ ] **Step 1: Extend the injected CSS vars (`toolbar.m`)**

In `zapp_toolbar_inject_metrics` (~`:604`), measure the content webview's safe area + window corner inset and add vars. Source the content safe area from the host content webview's `safeAreaInsets` (populated by `automaticallyAdjustsSafeAreaInsets` from T3); corner inset from the window's corner radius (or a small constant matched to the Tahoe radius). Extend the JS:

```objc
NSWindow* w = (__bridge NSWindow*)window_ptr;
WKWebView* contentWv = zapp_webview_for_slot(host_slot);
NSEdgeInsets sa = contentWv ? contentWv.safeAreaInsets : NSEdgeInsetsZero;
CGFloat corner = 0.0;
if (@available(macOS 26.0, *)) { /* derive from window corner radius if available, else 0 */ }

NSString* js = [NSString stringWithFormat:
    @"(function(){try{var r=document.documentElement;"
    @"if(r){r.style.setProperty('--zapp-titlebar-height','%.0fpx');"
    @"r.style.setProperty('--zapp-toolbar-height','%.0fpx');"
    @"r.style.setProperty('--zapp-safe-area-top','%.0fpx');"
    @"r.style.setProperty('--zapp-safe-area-left','%.0fpx');"
    @"r.style.setProperty('--zapp-safe-area-right','%.0fpx');"
    @"r.style.setProperty('--zapp-safe-area-bottom','%.0fpx');"
    @"r.style.setProperty('--zapp-corner-inset','%.0fpx');}}catch(e){}})();",
    totalInset, toolbarH, sa.top, sa.left, sa.right, sa.bottom, corner];
```
Extend the no-op-skip cache check (`lastInjectedInset`/`lastInjectedToolbarH`) to also include the safe-area-left (the value that changes on sidebar collapse/resize) so re-injects aren't skipped when only the sidebar changes — add a `lastInjectedSafeLeft` field to `ZappToolbarController`.

- [ ] **Step 2: Re-inject on sidebar collapse/resize (`sidebar.m`)**

In the sidebar controller's `collapsed` KVO + `didResizeSubviews` handlers (where collapse/width changes are already observed), call `zapp_toolbar_inject_metrics((__bridge void*)window, host_slot, false)` (coalesced) so the safe-area vars track the live sidebar geometry. Reuse the host-slot lookup already available to the sidebar controller.

- [ ] **Step 3: Build + verify the vars update**

macOS build → `[zapp] build complete:`. (Visual confirmation of live update is part of T5's smoke.)

- [ ] **Step 4: Commit**

```bash
git add native/platform/darwin/toolbar.m native/platform/darwin/sidebar.m
git commit -m "$(cat <<'EOF'
feat(macos): inject safe-area + corner CSS vars for content-under-glass

Extend the chrome-metrics injection with --zapp-safe-area-{top,left,right,
bottom} (from the content webview safeAreaInsets) + --zapp-corner-inset, and
re-inject on sidebar collapse/resize so content under the floating sidebar
lays out correctly and tracks the live geometry.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Showcase + docs + gates + final review

**Files:** Modify: `kitchen-sink/src/sections/sidebar.ts`, `kitchen-sink/zapp.config.ts` (if needed to set `backgroundExtension`), `docs/api-reference.md`, `docs/native-ui-strategy.md`

- [ ] **Step 1: Kitchen-sink showcase**

In `sidebar.ts`, add a full-bleed media panel (image or rich gradient filling the content viewport, laid out with `padding-left: var(--zapp-safe-area-left)` etc. so foreground content stays clear of the sidebar while the background extends under it). Set the demo window's `backgroundExtension` (config or via the section) so the effect is visible. Show `Extend` vs `Mirror` if T1 was GO.

- [ ] **Step 2: Docs**

`docs/api-reference.md`: document `WindowOptions.backgroundExtension` (the three modes, macOS 26 + `None` fallback, sidebar-edge, the `--zapp-safe-area-*`/`--zapp-corner-inset` CSS vars). `docs/native-ui-strategy.md`: add the content-under-glass section + the **W1 material/version contract** (unspecified/`Sidebar` → native glass; other `material` → forced override; the new design is native on macOS 26). Note inspector is out of scope by design.

- [ ] **Step 3: Full build matrix**

`cd /Users/zach/code/zapp && bun test runtime cli/src` · macOS `bun run build` (`[zapp] build complete:`) · iOS-sim `bun run build --platform ios`. All green.

- [ ] **Step 4: Human visual smoke (GATE — pause for the user)**

`bun run dev`. Human confirms: `None` (default) unchanged; `Extend` flows content under the sidebar with correct safe-area layout (foreground clear, background under glass); `Mirror` shows the poster effect (if GO); collapsing/resizing the sidebar updates the layout live. **Do not finish until sign-off.**

- [ ] **Step 5: Commit + memory + final review**

```bash
git add kitchen-sink/src/sections/sidebar.ts kitchen-sink/zapp.config.ts docs/api-reference.md docs/native-ui-strategy.md
git commit -m "$(cat <<'EOF'
docs+demo: backgroundExtension showcase + content-under-glass docs (W3)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```
Then: update memory (AppKit new-design W3 shipped; reference the spec). Dispatch a final cross-impl review over `git diff` for the cycle (no orphaned refs, `@available` gating correct, iOS untouched, staging clean). Branch stays UNMERGED.

---

## Self-Review (plan vs spec)
- **Coverage:** enum TS+Nim+parse (T2) · native Extend/Mirror + gating/fallback (T3) · safe-area/corner CSS + live re-inject (T4) · risk gate (T1) · showcase + docs incl. W1 material/version (T5). Inspector out (by design).
- **Risk gate first:** T1 is scratch + human GO/NO-GO; NO-GO path threads into T2/T3 (drop `Mirror`). No throwaway committed.
- **Naming consistency:** `BackgroundExtension` / `None`/`Extend`/`Mirror` / `wopts_background_extension` / `--zapp-safe-area-*` used identically across tasks. Avoids the `Material.ContentBackground` collision (flagged in T2).
- **Staging:** every commit stages explicit files; no `git add -A` (unrelated WIP in tree).
- **Open detail deferred to impl (acceptable):** exact `NSBackgroundExtensionView` SDK API (proven in T1) and the precise corner-radius source (constant vs API) — both resolved against the macOS 26 SDK during T1/T4.
