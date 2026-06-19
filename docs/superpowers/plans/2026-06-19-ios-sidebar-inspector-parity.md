# iOS sidebar/inspector native parity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring iOS sidebar/inspector windows to native-convention parity — a `presentation` (tile/overlay) option, a collapsible sidebar on iPad-regular, drag regions disabled on iOS, and a real iOS inspector (trailing pane on iPad, sheet on iPhone).

**Architecture:** Two phases. Phase A threads a new `sidebar.presentation` option through TS → Nim/zc option parsing → iOS `UISplitViewController.preferredSplitBehavior`, makes the iOS sidebar control ops work on iPad-regular, and disables drag-region tracking on iOS. Phase B implements the iOS inspector natively (persistent VC owning the webview; trailing child on iPad-regular, presented sheet on iPhone-compact) and un-stubs `darwin_inspector_*`.

**Tech Stack:** TypeScript (runtime), Nim + Zen-C (`window.nim`/`window.zc` option parsing, parity), Objective-C (`native/platform/ios/*.m`, `native/platform/darwin/window.m`), bun:test for the Nim unit test, iOS-Simulator + iPad-Simulator + macOS builds as gates.

**Spec:** `docs/superpowers/specs/2026-06-19-sidebar-presentation-and-ios-drag-design.md`

**Standing constraints:** stay on `feat/nim-native` (do NOT merge to main without asking); commit trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; maintain Nim↔zc parity; iOS builds are Nim-only (`ZAPP_NATIVE_LANG=nim`).

**Build/verify commands (reference):**
- Nim unit test: `cd /Users/zach/code/zapp && bun test native/nim/tests` (or the specific file via the existing nim test runner — see how `windowmanager_test.nim` is currently run).
- macOS Nim build: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build`
- iOS-sim Nim build: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build --platform ios`
- Parity lint: `cd /Users/zach/code/zapp && bun test cli/src`
- A build is successful ONLY when the final line is `[zapp] build complete: ...` (Vite's `✓ built` is not sufficient).

---

## File Structure

**Phase A (sidebar presentation + iPad-collapsible + drag-hiding):**
- `runtime/window.ts` — `SidebarOptions.presentation` field + handle doc comments (also the Part B InspectorOptions/Handle iOS doc comments, done upfront since it's all TS).
- `native/nim/window.nim` — `sidebarPresentation` field + default + JSON parse + accessor.
- `native/window/window.zc` — same (parity).
- `native/nim/tests/windowmanager_test.nim` — parse test.
- `native/platform/ios/window.m` — apply `preferredSplitBehavior` from the option.
- `native/platform/ios/sidebar.m` — control ops work on iPad-regular.
- `native/platform/darwin/window.m` — documented no-op read.
- `bootstrap/webview.ts` — iOS drag-tracking gate.
- `kitchen-sink/src/shell/*.ts` — hide drag strips on iOS.
- `kitchen-sink/zapp/app.nim` — `sidebarPresentation: "overlay"` + ensure `inspectorUrl`.
- `docs/api-reference.md` — Sidebar `presentation` + matrix + iOS notes.

**Phase B (inspector on iOS):**
- `native/platform/ios/inspector.m` — `zapp_ios_inspector_register` + un-stub `darwin_inspector_*`.
- `native/platform/ios/window.m` — materialize the persistent inspector VC + webview.
- `native/platform/ios/webview.m` — confirm `pane_role=inspector` mount path.

---

## Phase A — Sidebar presentation + iPad-collapsible + drag-hiding

### Task A1: TS surface — sidebar `presentation` + iOS doc comments

**Files:**
- Modify: `runtime/window.ts` (`SidebarOptions` ~236-258; `SidebarHandle` ~660-688; `InspectorOptions` ~261-283; `InspectorHandle` ~691-704)

- [ ] **Step 1: Add `presentation` to `SidebarOptions`**

In `runtime/window.ts`, inside `interface SidebarOptions` (after `material?: Material;`), add:

```ts
  /**
   * How the sidebar is presented when there's room for both columns.
   * Maps to UISplitViewController's split behavior.
   *
   * - "tile" (default): sidebar sits beside content (the classic split).
   * - "overlay": sidebar floats OVER content as a flyout; dims content
   *   behind it; tapping outside dismisses it.
   *
   * Platform behavior:
   * - iPad (regular width): fully honored — "overlay" is the native flyout.
   * - macOS: NO-OP. NSSplitViewController tiles only (slide-in collapse,
   *   never floats over content); the sidebar stays tiled-collapsible.
   * - iPhone (compact width): NO-OP. The split always collapses to a
   *   master-detail navigation stack regardless of this value.
   *
   * Create-time only. Default "tile".
   */
  presentation?: "tile" | "overlay";
```

- [ ] **Step 2: Update `SidebarHandle` doc comments for iPad-regular**

Replace the `showContent()` / `showSidebar()` doc comments in `interface SidebarHandle` so they describe iPad-regular collapse/reveal (not "no-op"):

```ts
  /**
   * Reveal the content (secondary) column / collapse the sidebar.
   * - iPhone (compact): drives the collapsed nav stack to the content pane.
   * - iPad (regular): hides the sidebar — `tile` collapses it beside content,
   *   `overlay` dismisses the flyout.
   * - macOS: collapses the tiled sidebar.
   * Only a true no-op when the window has no sidebar.
   */
  showContent(): void;
  /**
   * Reveal the sidebar (primary) column.
   * - iPhone (compact): pops the nav stack back to the sidebar ("back").
   * - iPad (regular): shows the sidebar — `tile` slides it beside content,
   *   `overlay` floats the flyout in.
   * - macOS: expands the tiled sidebar.
   */
  showSidebar(): void;
```

- [ ] **Step 3: Add iOS doc note to `InspectorOptions` and `InspectorHandle` (Part B labeling, done now)**

At the top of `interface InspectorOptions` (just under the opening `{`-line doc), and on `interface InspectorHandle`, add a doc comment describing cross-platform behavior. On `InspectorOptions`:

```ts
/** Options for a native inspector pane attached to a window.
 *  Platform behavior:
 *  - macOS / iPad (regular width): a trailing pane beside the content.
 *  - iPhone (compact width): presented as a sheet (summon-only; never shown
 *    at launch). Detents default to medium+large.
 *  Width/min/max/resizable apply to the pane; on the iPhone sheet they are
 *  ignored (the sheet is full-width with system detents). */
```

(Keep the existing per-field comments.) Add a one-line note on `InspectorHandle`: `/** Handle to a window's inspector. On iPhone the pane ops present/dismiss a sheet; on iPad/macOS they show/hide the trailing pane. */`

- [ ] **Step 4: Type-check**

Run: `cd /Users/zach/code/zapp && bun run check`
Expected: PASS (no new type errors; `presentation` is an optional string-union field on an existing interface).

- [ ] **Step 5: Commit**

```bash
git add runtime/window.ts
git commit -m "feat(window): SidebarOptions.presentation (tile/overlay) + iOS sidebar/inspector handle docs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task A2: Native option parsing — `sidebarPresentation` (Nim + zc parity, TDD)

**Files:**
- Modify: `native/nim/window.nim` (WindowOptions ~78-81; accessors ~157-159; parse ~340-343)
- Modify: `native/window/window.zc` (WindowOptions ~102-108; defaults ~230-236; accessors ~297-299; parse ~479)
- Test: `native/nim/tests/windowmanager_test.nim`

- [ ] **Step 1: Write the failing Nim test**

In `native/nim/tests/windowmanager_test.nim`, add a test that builds a sidebar JSON with `presentation` and asserts it parses (follow the existing test style that calls `windowOptsApplyJson`). Example (adapt to the file's existing helpers/imports):

```nim
block presentation_parse:
  var o = defaultWindowOptions()
  windowOptsApplyJson(addr o, """{"sidebar":{"url":"#sb","width":240,"presentation":"overlay"}}""")
  doAssert o.sidebarPresentation == "overlay", "presentation should parse to overlay"

block presentation_default_tile:
  var o = defaultWindowOptions()
  windowOptsApplyJson(addr o, """{"sidebar":{"url":"#sb"}}""")
  doAssert o.sidebarPresentation == "" or o.sidebarPresentation == "tile",
    "absent presentation defaults to tile/empty"
```

(Use the same `defaultWindowOptions`/`windowOptsApplyJson` entry points the existing tests use — check the top of the file. If the existing tests construct options differently, match them.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/zach/code/zapp && bun test native/nim/tests` (or the project's nim test invocation for this file)
Expected: FAIL — `sidebarPresentation` is not a field on `WindowOptions` yet (compile error) or the assert fails.

- [ ] **Step 3: Add the field + accessor + parse to `window.nim`**

In `native/nim/window.nim`:
- In the `WindowOptions` object (near `sidebarWidth*: int32 = 260`), add: `sidebarPresentation*: string` (defaults to `""` which the .m layer treats as tile).
- Add an accessor near `wopts_sidebar_width`:
  ```nim
  proc wopts_sidebar_presentation(p: pointer): cstring {.exportc, cdecl.} = opt(p).sidebarPresentation.cstring
  ```
- In `windowOptsApplyJson` where the `sb` sidebar object is parsed (near `if jHasStr(sb, "url")`), add:
  ```nim
  if jHasStr(sb, "presentation"): o.sidebarPresentation = jStr(sb, "presentation")
  ```

- [ ] **Step 4: Run the Nim test to verify it passes**

Run: `cd /Users/zach/code/zapp && bun test native/nim/tests`
Expected: PASS.

- [ ] **Step 5: Add the same field + accessor + parse to `window.zc` (parity)**

In `native/window/window.zc`:
- In `WindowOptions` (near `sidebarWidth: int;`), add: `sidebarPresentation: string;` and a heap flag if the struct's string convention requires it (mirror how `sidebarUrl`/`_sidebarUrl_heap` is handled; presentation is a short enum string — if other short strings are stored without heap dup, follow that; otherwise strdup it in the parse and free in destroy).
- In the defaults block (near `sidebarWidth: 260,`), add: `sidebarPresentation: "",`.
- Add accessor near `wopts_sidebar_width`:
  ```zig
  fn wopts_sidebar_presentation(opts: WindowOptions*) -> string { return opts.sidebarPresentation; }
  ```
- In `windowOptsApplyJson` where the sidebar `sb` object is parsed (near the `sw = (*sb).get_int("width")` line), add:
  ```zig
  let sp = (*sb).get_str("presentation"); if sp.is_some() { opts.sidebarPresentation = sp.unwrap(); }
  ```
  (If `get_str` returns a borrowed pointer that must outlive the call, strdup + set the heap flag + free in destroy, matching `sidebarUrl`.)

- [ ] **Step 6: Build macOS Nim to confirm both layers compile**

Run: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build`
Expected: ends with `[zapp] build complete: ...`. (zc still compiles for parity even though the build uses Nim — confirm `zc` isn't broken by running its own check if the repo has one; otherwise the parity is verified by review + the field matching.)

- [ ] **Step 7: Run parity lint**

Run: `cd /Users/zach/code/zapp && bun test cli/src`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add native/nim/window.nim native/window/window.zc native/nim/tests/windowmanager_test.nim
git commit -m "feat(window): parse sidebar.presentation into WindowOptions.sidebarPresentation (nim+zc parity)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task A3: iOS apply split behavior + iPad-collapsible sidebar ops + macOS no-op

**Files:**
- Modify: `native/platform/ios/window.m` (materialize, ~190-220; `ZappIOSDeferred` fields ~70-76; capture ~578-580; free ~609)
- Modify: `native/platform/ios/sidebar.m` (control ops `darwin_sidebar_show_content`/`show_sidebar`/`toggle`, ~250-310; `zapp_ios_sidebar_is_compact` helper ~104)
- Modify: `native/platform/darwin/window.m` (sidebar build ~744; add a documented no-op read)

- [ ] **Step 1: Thread `sidebarPresentation` into `ZappIOSDeferred`**

In `native/platform/ios/window.m`:
- Add a field to the deferred struct (near `int32_t sidebarWidth;`): `char* sidebarPresentation; // strdup'd; freed in destroy ("" / "tile" = tile, "overlay" = flyout)`.
- Where deferred fields are populated (near `d->sidebarWidth = wopts_sidebar_width(opts);`), add:
  ```objc
  extern const char* wopts_sidebar_presentation(void* opts);
  const char* sp = wopts_sidebar_presentation(opts);
  d->sidebarPresentation = (sp && sp[0]) ? strdup(sp) : NULL;
  ```
- In destroy (near `free(d->sidebarUrl);`), add: `free(d->sidebarPresentation);`.

- [ ] **Step 2: Apply `preferredSplitBehavior` in materialize**

In `native/platform/ios/window.m`, in the `if (d->hasSidebar)` materialize block, AFTER the `setViewController:...Primary/Secondary` calls and the existing `preferredDisplayMode`/`preferredPrimaryColumnWidth` setup, add:

```objc
// Split behavior from sidebar.presentation. "overlay" = the iPad flyout
// (sidebar floats over content, dims it, tap-out dismisses); start hidden
// so it reads as summon-able. Default/"tile" = side-by-side (unchanged).
// No-op on iPhone (the split always collapses to a nav stack) and on macOS
// (AppKit; this is the iOS layer).
if (d->sidebarPresentation && strcmp(d->sidebarPresentation, "overlay") == 0) {
    split.preferredSplitBehavior = UISplitViewControllerSplitBehaviorOverlay;
    split.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
}
```

- [ ] **Step 3: Make the sidebar control ops act on iPad-regular**

In `native/platform/ios/sidebar.m`, change the reveal/hide ops so they no longer early-return when the split is not compact. Replace the `if (!zapp_ios_sidebar_is_compact(c)) return;` guards in `darwin_sidebar_show_content` and `darwin_sidebar_show_sidebar` with use of `showColumn:`/`hideColumn:` that adapt:

```objc
void darwin_sidebar_show_content(int32_t window_id) {
    zapp_ios_sidebar_on_main(^{
        ZappIOSSidebarController* c = zapp_ios_sidebar_for_slot(window_id);
        if (!c || !c.splitVC) return;
        if (@available(iOS 16.0, *)) {
            // compact → pops to content; tile-regular → hides the sidebar
            // (more content width); overlay-regular → dismisses the flyout.
            [c.splitVC hideColumn:UISplitViewControllerColumnPrimary];
        } else if (zapp_ios_sidebar_is_compact(c)) {
            UINavigationController* nav = c.collapsedNav ?: zapp_ios_collapsed_nav(c.splitVC);
            if (nav && c.contentVC && nav.topViewController != c.contentVC)
                [nav pushViewController:c.contentVC animated:YES];
        } else {
            c.splitVC.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
        }
        zapp_ios_sidebar_sync_collapse(c, YES);
    });
}

void darwin_sidebar_show_sidebar(int32_t window_id) {
    zapp_ios_sidebar_on_main(^{
        ZappIOSSidebarController* c = zapp_ios_sidebar_for_slot(window_id);
        if (!c || !c.splitVC) return;
        if (@available(iOS 16.0, *)) {
            // compact → pops to sidebar; tile-regular → shows the sidebar;
            // overlay-regular → floats the flyout in.
            [c.splitVC showColumn:UISplitViewControllerColumnPrimary];
        } else if (zapp_ios_sidebar_is_compact(c)) {
            UINavigationController* nav = c.collapsedNav ?: zapp_ios_collapsed_nav(c.splitVC);
            if (nav && nav.viewControllers.count > 1)
                [nav popToRootViewControllerAnimated:YES];
        } else {
            c.splitVC.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
        }
        zapp_ios_sidebar_sync_collapse(c, NO);
    });
}
```

(Note: on `.overlay` behavior, `showColumn:`/`hideColumn:` present/dismiss the overlay; on `.tile` they slide the column in/out; on compact they push/pop. One code path, three adaptations. `darwin_sidebar_toggle` already flips on `lastCollapsedEmit` → it now works on iPad too with no change. `collapse`/`expand` already alias to these.)

- [ ] **Step 4: macOS documented no-op read**

In `native/platform/darwin/window.m`, near the sidebar build (`const char* sidebarUrl = wopts_sidebar_url(opts);`), add a read + comment so the field is acknowledged on macOS:

```objc
// sidebar.presentation is iOS-only (UISplitViewController split behavior).
// AppKit's NSSplitViewController tiles/collapses and never overlays content,
// so the value is intentionally ignored here. Read for documentation/symmetry.
(void)wopts_sidebar_presentation(opts);
```

Add the extern near the other `wopts_*` externs in this file if not already declared.

- [ ] **Step 5: Build iOS-sim (Nim) and macOS (Nim)**

Run: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build --platform ios`
Then: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build`
Expected: both end with `[zapp] build complete: ...`.

- [ ] **Step 6: Parity lint**

Run: `cd /Users/zach/code/zapp && bun test cli/src`
Expected: PASS (new `wopts_sidebar_presentation` is referenced from both `.zc`/`.nim` and the .m files; ensure it's defined in both platform layers if the lint flags it — it's an accessor in window.nim/window.zc, not a `darwin_*` symbol, so the parity lint shouldn't require an iOS stub; confirm green).

- [ ] **Step 7: Commit**

```bash
git add native/platform/ios/window.m native/platform/ios/sidebar.m native/platform/darwin/window.m
git commit -m "feat(ios): sidebar overlay presentation + collapsible sidebar on iPad-regular

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task A4: Disable drag-region tracking on iOS

**Files:**
- Modify: `bootstrap/webview.ts` (the `mousemove` drag tracker, ~278-316)
- Modify: `kitchen-sink/src/shell/*.ts` (the panes that render `data-zapp-drag-region` strips — grep for `data-zapp-drag-region`)

- [ ] **Step 1: Gate the drag tracker on iOS in the bootstrap**

In `bootstrap/webview.ts`, just before the `let inDrag = false; document.addEventListener("mousemove", ...)` block, read the platform from the bootstrap-config carrier and skip installing the listener on iOS:

```ts
  // iOS windows aren't user-draggable (no performWindowDragWithEvent), so
  // drag-region tracking is dead weight there. Skip it on iOS. Read the
  // platform from the bootstrap-config carrier the native webview injects.
  const _cfg = (globalThis as any)[Symbol.for("zapp.bootstrapConfig")];
  const _isIOS = _cfg?.permissions?.platform === "ios";
  if (!_isIOS) {
    let inDrag = false;
    document.addEventListener("mousemove", (e: MouseEvent) => {
      /* ...existing body unchanged... */
    });
  }
```

(Keep the existing handler body verbatim; only wrap it in the `if (!_isIOS)`.)

- [ ] **Step 2: Verify bootstrap-config availability ordering**

Confirm the bootstrap-config WKUserScript is injected before the bridge IIFE runs (so the symbol exists). Grep `native/platform/ios/webview.m` for where `zapp.bootstrapConfig` is set and the order it's added relative to the bridge script. If the config is NOT guaranteed first, instead compute `_isIOS` lazily inside the handler (read the symbol on first event, early-return) — but prefer the install-time gate if ordering is guaranteed. Document which form you used in the commit.

- [ ] **Step 3: Build iOS-sim to confirm the bootstrap still compiles/minifies**

Run: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build --platform ios`
Expected: `[zapp] build complete: ...` (the bootstrap is codegen'd + minified into the binary).

- [ ] **Step 4: Hide kitchen-sink drag strips on iOS**

Grep: `grep -rn "data-zapp-drag-region" kitchen-sink/src`. In each shell pane that renders a drag strip, guard its rendering with `Platform.isIOS` (import `Platform` from the runtime). Example pattern (adapt to each pane's render):

```ts
import { Platform } from "@zappdev/runtime"; // match the existing import path used in kitchen-sink
// ...
if (!Platform.isIOS) {
  // render the data-zapp-drag-region strip element
}
```

- [ ] **Step 5: Type-check kitchen-sink + build**

Run: `cd /Users/zach/code/zapp && bun run check`
Then: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build --platform ios`
Expected: check PASS; build ends `[zapp] build complete: ...`.

- [ ] **Step 6: Commit**

```bash
git add bootstrap/webview.ts kitchen-sink/src
git commit -m "feat(ios): disable drag-region tracking on iOS + hide kitchen-sink drag strips

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task A5: Kitchen-sink overlay showcase + docs + Phase-A smoke gate

**Files:**
- Modify: `kitchen-sink/zapp/app.nim` (first-window `WindowOptions`, ~29-33)
- Modify: `docs/api-reference.md` (Sidebar section)

- [ ] **Step 1: Set overlay + ensure an inspector on the kitchen-sink first window**

In `kitchen-sink/zapp/app.nim`, in the first window's `WindowOptions(...)`, add `sidebarPresentation: "overlay"` and confirm an `inspectorUrl` (+ `inspectorWidth`) is present (add one pointing at the existing inspector pane route if missing — needed for the Phase B smoke). Example:

```nim
  let win = app.window.create(WindowOptions(
    # ...existing fields...
    sidebarUrl: "#sidebar-pane", sidebarWidth: 240,
    sidebarPresentation: "overlay",
    inspectorUrl: "#inspector-pane", inspectorWidth: 280,
  ))
```

(Match the exact pane routes the kitchen-sink already uses; if `inspectorUrl` already exists, just add `sidebarPresentation`.)

- [ ] **Step 2: Document the option in api-reference**

In `docs/api-reference.md`, in the Sidebar section, document `presentation: "tile" | "overlay"` with the platform matrix (macOS no-op / iPad flyout / iPhone n/a), note that drag regions are inert on iOS, and (forward-looking) that the inspector renders as a trailing pane on iPad and a sheet on iPhone.

- [ ] **Step 3: Build macOS + iPhone-sim + confirm no regression**

Run: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build`
Then: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build --platform ios`
Expected: both `[zapp] build complete: ...`.

- [ ] **Step 4: Commit**

```bash
git add kitchen-sink/zapp/app.nim docs/api-reference.md
git commit -m "feat(kitchen-sink)+docs: sidebar overlay showcase + presentation/iOS docs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: PHASE-A HUMAN SMOKE (gate)**

Hand to the user. Install/launch on **iPad sim** (overlay flyout + edge-swipe + "‹ Menu" reveal/dismiss; sidebar collapsible; no drag strip), **iPhone sim** (unchanged master-detail; no drag strips), and **macOS** (unchanged tiled sidebar; drag strips still present). Do not start Phase B until this passes. Install/launch commands are printed by the iOS build (`xcrun simctl install/launch`); for a specific device use `xcrun simctl boot "iPad Pro 11-inch ..."` first.

---

## Phase B — Inspector on iOS (trailing pane on iPad, sheet on iPhone)

### Task B1: Materialize the persistent inspector VC + webview

**Files:**
- Modify: `native/platform/ios/inspector.m` (currently all stubs)
- Modify: `native/platform/ios/window.m` (materialize, after the sidebar/content build ~257-300; `ZappIOSDeferred` already carries `inspectorUrl`/`inspectorWidth` if present — confirm, else add like the sidebar fields)
- Reference: `native/platform/ios/webview.m` (`darwin_webview_create_ext` signature + `pane_role` for inspector)

- [ ] **Step 1: Confirm inspector option fields reach the deferred record**

In `native/platform/ios/window.m`, confirm `ZappIOSDeferred` has `inspectorUrl`/`inspectorWidth`/`inspectorNumericId` (mirror of the sidebar fields) and that they're populated from `wopts_inspector_url`/`wopts_inspector_width` (grep `wopts_inspector` in `window.nim`/`window.zc` for the accessor names). If absent, add them exactly like the sidebar fields (strdup url, free in destroy, allocate a numeric transport slot like `sidebarNumericId`).

- [ ] **Step 2: Add `zapp_ios_inspector_register` + a per-window registry to `inspector.m`**

Rewrite `native/platform/ios/inspector.m`: add a `ZappIOSInspectorController` (mirroring `ZappIOSSidebarController` in `sidebar.m`) holding: `UIViewController* inspectorVC` (persistent owner of the inspector webview), `UIViewController* contentVC` (the host content VC, for iPad trailing-child embedding), `BOOL compact` (launch size class), `int32_t hostWindowId`, `int32_t inspectorSlotId`, `int32_t width`, `BOOL shown`, layout constraint refs for the trailing pane. Add a per-window registry keyed by host UIWindow (mirror `zapp_ios_sidebars`). Add:

```objc
void zapp_ios_inspector_register(void* window, void* inspectorVC, void* contentVC,
                                 int32_t host_id, int32_t inspector_id,
                                 int32_t width, bool compact);
```

It stores the record and, when `!compact` (iPad/regular), embeds `inspectorVC` as a child of `contentVC` with its view pinned to the trailing edge at `width` (Auto Layout: top/bottom/trailing to contentVC.view, width constraint = `width`), and leaves the content webview's leading area filling the rest (constrain the content webview's trailing to the inspector's leading — or, simplest, the inspector overlays the trailing edge and content stays full-bleed behind it; prefer a real side-by-side: pin content webview trailing to inspector leading). Initial visibility = shown unless the inspector's `collapsed` option is true (read it like the sidebar's collapsed). When `compact`, do NOT add to the hierarchy (held for sheet presentation).

- [ ] **Step 3: Materialize the inspector in `window.m`**

In `native/platform/ios/window.m`, AFTER the sidebar/content webviews are created (end of the `if (d->hasSidebar)` block — and also handle the no-sidebar case where `inspectorUrl` is set), add: if `d->inspectorUrl` is non-empty, create the persistent inspector VC + webview:

```objc
if (d->inspectorUrl && d->inspectorUrl[0]) {
    UIViewController* inspectorVC = [[UIViewController alloc] init];
    inspectorVC.view.backgroundColor = [UIColor systemBackgroundColor];
    BOOL compact = window.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact;

    // Create the inspector webview INTO inspectorVC.view (pane_role=inspector).
    // It is born in its permanent owner and never re-parented.
    darwin_webview_create_ext((__bridge void*)window, d->inspectable, d->first_mouse,
                              d->inspectorUrl, d->inspectorNumericId, true,
                              (__bridge void*)inspectorVC.view, d->numeric_id, /*pane_role inspector*/3,
                              /*host_has_sidebar*/d->hasSidebar, /*host_has_inspector*/true);
    // _ext registers by UIWindow → it clobbered the host slot; pull the inspector
    // webview out and register it into its own transport slot (mirror the sidebar
    // re-slot dance below the sidebar create), then restore the content webview to
    // the host slot.
    // ... (re-slot exactly as the sidebar pane does) ...

    zapp_ios_inspector_register((__bridge void*)window, (__bridge void*)inspectorVC,
                                (__bridge void*)contentVC, d->numeric_id,
                                d->inspectorNumericId, d->inspectorWidth, compact);
}
```

(Reuse the exact re-slot pattern used for the sidebar webview at ~287-300 so transport routing is correct: the inspector webview gets its own slot, JS identity mirrors the host.)

- [ ] **Step 4: Verify `pane_role=inspector` in `webview.m`**

Confirm `native/platform/ios/webview.m`'s `darwin_webview_create_ext` handles `pane_role == 3` (inspector): sets the inspector identity marker (`zapp.isInspector` or equivalent) like it sets `zapp.isSidebar` for pane_role 1, and mounts into the passed `container_view`. If the iOS `_ext` doesn't yet branch pane_role 3, add it mirroring the sidebar (pane_role 1) branch.

- [ ] **Step 5: Build iOS-sim (Nim)**

Run: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build --platform ios`
Expected: `[zapp] build complete: ...`.

- [ ] **Step 6: Commit**

```bash
git add native/platform/ios/inspector.m native/platform/ios/window.m native/platform/ios/webview.m
git commit -m "feat(ios): materialize persistent inspector VC + webview (trailing-child on iPad, held on iPhone)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task B2: Un-stub `darwin_inspector_*` — pane on iPad, sheet on iPhone + events

**Files:**
- Modify: `native/platform/ios/inspector.m` (the six `darwin_inspector_*` functions + an event-emit helper)
- Reference: `native/platform/ios/window.m` `attach_modal` (~715-920) for the sheet-presentation pattern (modalPresentationStyle, `sheetPresentationController`, detents, grabber)
- Reference: `native/platform/ios/sidebar.m` `zapp_ios_sidebar_emit` for the event fan-out pattern

- [ ] **Step 1: Add an inspector event-emit helper**

In `inspector.m`, add `zapp_ios_inspector_emit(c, eventName)` mirroring `zapp_ios_sidebar_emit` (calls `b.dispatchWindowEvent('win-<hostId>','<eventName>')` via `darwin_window_eval_js` to both the host slot and the inspector slot), plus a `zapp_ios_inspector_sync(c, collapsed)` that emits `inspector-collapsed`/`inspector-expanded` once per transition.

- [ ] **Step 2: Implement toggle/collapse/expand**

Replace the stubs:

```objc
void darwin_inspector_expand(int32_t window_id) {   // show
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;
        if (c.compact) {
            // present the inspector VC as a sheet (medium+large detents + grabber)
            UIViewController* host = zapp_ios_topmost_presenter(c.hostWindowId); // walk like attach_modal
            if (!c.inspectorVC.presentingViewController) {
                c.inspectorVC.modalPresentationStyle = UIModalPresentationPageSheet;
                if (@available(iOS 15.0, *)) {
                    UISheetPresentationController* s = c.inspectorVC.sheetPresentationController;
                    s.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                                  UISheetPresentationControllerDetent.largeDetent];
                    s.prefersGrabberVisible = YES;
                    s.delegate = c; // for presentationControllerDidDismiss:
                }
                [host presentViewController:c.inspectorVC animated:YES completion:nil];
            }
        } else {
            // iPad/regular: animate the trailing pane in (width 0 -> width)
            c.widthConstraint.constant = c.width;
            [UIView animateWithDuration:0.2 animations:^{ [c.contentVC.view layoutIfNeeded]; }];
        }
        c.shown = YES;
        zapp_ios_inspector_sync(c, NO);
    });
}

void darwin_inspector_collapse(int32_t window_id) {  // hide
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;
        if (c.compact) {
            if (c.inspectorVC.presentingViewController)
                [c.inspectorVC dismissViewControllerAnimated:YES completion:nil];
        } else {
            c.widthConstraint.constant = 0;
            [UIView animateWithDuration:0.2 animations:^{ [c.contentVC.view layoutIfNeeded]; }];
        }
        c.shown = NO;
        zapp_ios_inspector_sync(c, YES);
    });
}

void darwin_inspector_toggle(int32_t window_id) {
    ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
    if (!c) return;
    if (c.shown) darwin_inspector_collapse(window_id);
    else darwin_inspector_expand(window_id);
}
```

Add the `UISheetPresentationControllerDelegate`/`UIAdaptivePresentationControllerDelegate` `presentationControllerDidDismiss:` on `ZappIOSInspectorController` to set `shown=NO` + `zapp_ios_inspector_sync(c, YES)` when the user swipes the sheet away. (`zapp_ios_topmost_presenter` = walk presentedViewController from the window's rootVC, as `attach_modal` does.)

- [ ] **Step 3: Implement set_width + documented no-ops**

```objc
void darwin_inspector_set_width(int32_t window_id, int32_t width) {
    zapp_ios_inspector_on_main(^{
        ZappIOSInspectorController* c = zapp_ios_inspector_for_slot(window_id);
        if (!c) return;
        c.width = width;
        if (!c.compact) { if (c.shown) c.widthConstraint.constant = width; }
        // compact: full-width sheet — width is n/a (documented).
    });
}
// Divider-drag affordances aren't a UIKit thing; store-intent / no-op (mirror sidebar).
void darwin_inspector_set_collapsible(int32_t window_id, bool can_collapse) { (void)window_id; (void)can_collapse; }
void darwin_inspector_set_resizable(int32_t window_id, bool resizable) { (void)window_id; (void)resizable; }
```

- [ ] **Step 4: Build iOS-sim (Nim) + parity lint**

Run: `cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build --platform ios`
Then: `cd /Users/zach/code/zapp && bun test cli/src`
Expected: build `[zapp] build complete: ...`; lint PASS (the `darwin_inspector_*` symbols already exist on both platforms — now implemented on iOS).

- [ ] **Step 5: Commit**

```bash
git add native/platform/ios/inspector.m
git commit -m "feat(ios): inspector control ops — trailing pane (iPad) / sheet (iPhone) + collapse events

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task B3: Kitchen-sink inspector smoke + docs + final gates

**Files:**
- Modify: `docs/api-reference.md` (Inspector section — iOS behavior)
- Verify: kitchen-sink already exposes an inspector toggle affordance (the Inspector section / a toolbar or button) — ensure there's a way to call `win.inspector?.toggle()` from the UI on iOS.

- [ ] **Step 1: Ensure a UI affordance toggles the inspector on iOS**

Confirm the kitchen-sink has a button/menu calling `Window.current().inspector?.toggle()`. If the existing affordance is macOS-toolbar-only, add a small in-content button (rendered when `Platform.isIOS`) that calls `inspector?.toggle()` so the iOS inspector is reachable in the smoke.

- [ ] **Step 2: Document iOS inspector in api-reference**

In `docs/api-reference.md` Inspector section, document: trailing pane on iPad/macOS-regular; sheet (medium+large detents, grabber, summon-only) on iPhone; `setWidth` ignored on the iPhone sheet; adaptivity across size classes is a known limitation (built for the launch size class).

- [ ] **Step 3: Build macOS + iOS-sim + type-check + parity lint**

Run:
```bash
cd /Users/zach/code/zapp && bun run check && bun test cli/src
cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build
cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build --platform ios
```
Expected: check PASS; lint PASS; both builds `[zapp] build complete: ...`.

- [ ] **Step 4: Commit**

```bash
git add docs/api-reference.md kitchen-sink/src
git commit -m "docs+kitchen-sink: iOS inspector (pane/sheet) docs + toggle affordance

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: PHASE-B HUMAN SMOKE (gate)**

Hand to the user. **iPad sim:** inspector shows as a trailing pane; `inspector.toggle()` animates it in/out; sidebar (overlay) + content + inspector compose. **iPhone sim:** `inspector.toggle()` presents a sheet (medium/large detents + grabber); swipe-down dismisses; no sheet at launch. **macOS:** inspector unchanged.

---

## Final cross-implementation review

- [ ] After both phases pass smoke, dispatch a code-reviewer over the full diff (`git diff main...feat/nim-native` scoped to this cycle's commits) checking: Nim↔zc parity for `sidebarPresentation`; no `darwin_*` symbol added without both-platform defs (parity lint covers `.zc`-referenced ones; the inspector ops are `.m`-internal); no WKWebView re-parenting in the inspector materialize; memory hygiene (strdup/free pairing for `sidebarPresentation`, inspector url); the drag-gate ordering decision is sound; doc comments match actual platform behavior.

---

## Self-review notes (plan author)

- **Spec coverage:** §1→A1; §2→A2; §3→A3; §4→A3 step 4; §5→A4; §6→A5; §7→B1/B2/B3. All spec sections map to tasks.
- **Type consistency:** accessor name `wopts_sidebar_presentation` used identically in window.nim, window.zc, ios/window.m, darwin/window.m. Field `sidebarPresentation` consistent. Inspector register signature `zapp_ios_inspector_register(window, inspectorVC, contentVC, host_id, inspector_id, width, compact)` defined in B1 and used in B1 step 3.
- **Known soft spots flagged for the implementer (not placeholders — real "verify X in the codebase" steps):** the zc string-storage convention for `sidebarPresentation` (A2 step 5), the bootstrap-config injection ordering (A4 step 2), whether `ZappIOSDeferred` already carries inspector fields (B1 step 1), and whether iOS `_ext` already branches `pane_role 3` (B1 step 4). Each step says what to check and the fallback.
