# iOS sidebar via UISplitViewController Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The existing sidebar API (`app.window.create({ sidebar })`, `win.sidebar.toggle/collapse/expand/…`) drives a real native `UISplitViewController` on iOS — the first iOS native-chrome showcase.

**Architecture:** iOS `.m`-only (benefits zc + Nim). When a window has a `sidebar` option, the iOS window root becomes a `UISplitViewController` (sidebar = primary column, content = secondary), each column hosting a WKWebView via a ported `darwin_webview_create_ext`. The six `darwin_sidebar_*` symbols (today no-op stubs) map to `preferredDisplayMode`; events fire via `UISplitViewControllerDelegate`. Auto-adapts iPad (side-by-side) ↔ iPhone (drawer). A small `Platform` runtime API enables the kitchen-sink's iOS-conditional toggle.

**Tech Stack:** ObjC/UIKit (`UISplitViewController`, `WKWebView`), TypeScript (Bun, `bun:test`), the iOS Nim+zc build path.

**Spec:** `docs/superpowers/specs/2026-06-19-ios-sidebar-uisplitviewcontroller-design.md`.

**Reference (mirror these):** `native/platform/darwin/sidebar.m` (260 lines — controls + registry + events), `native/platform/darwin/window.m` ~744-975 (sidebar create-time + split build) & ~265-276 (event fan-out), `native/platform/darwin/webview.m` ~812-1166 (`darwin_webview_create_ext` + pane mount + markers). iOS current: `native/platform/ios/window.m` (deferred-window model: `ZappIOSDeferred` ~44-63, `darwin_window_create` ~338-371, `zapp_ios_materialize_pending_windows` ~90-166, `zapp_dispatch_event_to_js` ~293-331), `native/platform/ios/webview.m` (`darwin_webview_create` ~706-925, bootstrap inject ~742-797), `native/platform/ios/sidebar.m` (stubs ~8-13).

**Scope:** sidebar only. OUT: inspector/toolbar/popover, vibrancy/material, user-drag resize, multi-window.

**Verification reality:** iOS native behavior needs a **human Simulator smoke** (build+link is machine-checkable; "two panes render / toggle works" is human). T2 is a human-gated risk task.

---

### T0: `Platform` runtime API (TS-only, TDD)

**Files:**
- Create: `runtime/platform.ts`
- Test: `runtime/platform.test.ts`
- Modify: `runtime/index.ts` (export)

- [ ] **Step 1: Write the failing test.** `runtime/platform.test.ts`:

```ts
import { test, expect } from "bun:test";
import { Platform } from "./platform";

const BOOT = Symbol.for("zapp.bootstrapConfig");

test("Platform.current reads the injected bootstrap manifest platform", () => {
  (globalThis as any)[BOOT] = { permissions: { platform: "ios" } };
  expect(Platform.current()).toBe("ios");
  expect(Platform.isIOS).toBe(true);
  expect(Platform.isMacOS).toBe(false);
  expect(Platform.isWindows).toBe(false);
  delete (globalThis as any)[BOOT];
});

test("Platform.current defaults to macos when no manifest is present", () => {
  delete (globalThis as any)[BOOT];
  expect(Platform.current()).toBe("macos");
  expect(Platform.isMacOS).toBe(true);
});

test("Platform.isWindows for a windows manifest", () => {
  (globalThis as any)[BOOT] = { permissions: { platform: "windows" } };
  expect(Platform.current()).toBe("windows");
  expect(Platform.isWindows).toBe(true);
  delete (globalThis as any)[BOOT];
});
```

- [ ] **Step 2: Run → FAIL.** `cd /Users/zach/code/zapp && bun test runtime/platform.test.ts` → `cannot find module ./platform`.

- [ ] **Step 3: Implement `runtime/platform.ts`:**

```ts
/**
 * Runtime platform check for conditional app logic (e.g. rendering an in-page
 * sidebar toggle on iOS where there's no native toolbar button yet).
 *
 * Reads the platform baked into the per-webview bootstrap manifest
 * (`globalThis[Symbol.for("zapp.bootstrapConfig")].permissions.platform`) — the
 * same value `permissions.ts` reads. The native layer injects it target-correct
 * ("macos" | "ios" | "windows"); defaults to "macos" if absent (e.g. SSR/tests).
 */
export type PlatformName = "macos" | "ios" | "windows";

function read(): PlatformName {
  const p = (globalThis as any)[Symbol.for("zapp.bootstrapConfig")]?.permissions?.platform;
  return p === "ios" || p === "windows" ? p : "macos";
}

export const Platform = {
  current(): PlatformName { return read(); },
  get isMacOS(): boolean { return read() === "macos"; },
  get isIOS(): boolean { return read() === "ios"; },
  get isWindows(): boolean { return read() === "windows"; },
};
```

- [ ] **Step 4: Export + run → PASS.** Add `export { Platform, type PlatformName } from "./platform";` to `runtime/index.ts` (match the existing export style). Run `bun test runtime/platform.test.ts && bunx tsc --noEmit` → green.

- [ ] **Step 5: Commit.**

```bash
cd /Users/zach/code/zapp
git add runtime/platform.ts runtime/platform.test.ts runtime/index.ts
git commit -m "feat(runtime): Platform API (current/isIOS/isMacOS/isWindows)

Reads the already-injected bootstrapConfig.permissions.platform (target-correct
after gap #5). Pure runtime, no native change — the primitive apps need for
platform-conditional rendering (e.g. the iOS in-page sidebar toggle).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### T1: Port `darwin_webview_create_ext` to iOS (`native/platform/ios/webview.m`)

The macOS extended webview entry mounts a WKWebView into an arbitrary container view with an identity-window-id override + a pane-role (for the sidebar/inspector panes). iOS has only the thin `darwin_webview_create` (mounts into `rootViewController.view`). Add `_ext` so T2 can mount two webviews into split columns.

**Files:**
- Modify: `native/platform/ios/webview.m`

- [ ] **Step 1: Read the macOS reference + iOS current.** Read `darwin/webview.m` `darwin_webview_create_ext` (signature, the `container_view` mount, `identity_window_id`, `pane_role`, and the pane-marker user scripts at ~949-979: `zapp.isSidebar` for role 1, `zapp.isInspector` for role 3, `zapp.hasSidebar`/`hasInspector` for all panes). Read `ios/webview.m` `darwin_webview_create` (~706-925) — note where it builds the WKWebView, injects bootstrap (~742-797), and mounts to `root.view` (~870-876), registers (~924).

- [ ] **Step 2: Add `darwin_webview_create_ext` to `ios/webview.m`** with the SAME signature as `darwin/webview.m`'s (match it exactly — params incl. `void* container_view`, `int32_t identity_window_id`, `int32_t pane_role`, plus the existing url/inspectable/numeric_id/transparent args). Behavior:
  - Build + configure the WKWebView exactly as `darwin_webview_create` does today (reuse/extract the shared body).
  - Mount into `container_view` (a `UIView*`) when non-NULL, else fall back to the window's `rootViewController.view` (preserves the thin path).
  - Use `identity_window_id` (when ≥ 0) for the injected JS `windowId` instead of the webview's own numeric id (so a sidebar pane reports the host's id — mirror macOS).
  - Inject the pane-role markers alongside the existing bootstrap scripts: `pane_role==1` → `globalThis[Symbol.for('zapp.isSidebar')]=true`; `pane_role==3` → `…isInspector…`; and `globalThis[Symbol.for('zapp.hasSidebar')]=true` when the host has a sidebar (pass a `host_has_sidebar` flag the same way macOS does — check the macOS signature for the exact param).
  - Register the webview under its numeric slot (existing `zapp_ios_register_webview`).
- [ ] **Step 3: Make the thin `darwin_webview_create` delegate to `_ext`** with `container_view=NULL, identity_window_id=-1, pane_role=0, host_has_sidebar=false` so existing single-pane windows are byte-for-byte unchanged.

- [ ] **Step 4: Builds (no behavior change yet).**

```bash
cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build            # macOS unaffected
cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build --platform ios  # iOS still links
```
Both end with `[zapp] build complete: …`. Run `bun test cli/src/ios-platform-parity.test.ts` (the extern lint) → green (the new `_ext` is a definition, not a new unmet extern). Quote both build lines.

- [ ] **Step 5: Commit.**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/webview.m
git commit -m "feat(ios): darwin_webview_create_ext — container-mount + identity + pane-role markers

Ports the macOS extended webview entry to iOS so panes (sidebar/inspector) can
mount into arbitrary container views with a host-identity windowId + isSidebar/
hasSidebar markers. Thin darwin_webview_create delegates to it (single-pane path
unchanged).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### T2 (RISK GATE): materialize builds the split + both pane webviews

Build the `UISplitViewController` at window materialization and mount both webviews. **The order is load-bearing** (re-parenting a WKWebView resets its content process and kills the bridge): split → columns → `window.rootViewController = split` → **then** create the webviews into the column views.

**Files:**
- Modify: `native/platform/ios/window.m`

- [ ] **Step 1: Extend `ZappIOSDeferred`** (~44-63) with sidebar fields mirroring the macOS create-time reads: `bool hasSidebar; const char* sidebarUrl; int32_t sidebarNumericId; bool sidebarCollapsed; int32_t sidebarWidth/minWidth/maxWidth; bool sidebarCollapsible; bool sidebarResizable;` (material/backgroundColor optional — vibrancy deferred). In `darwin_window_create` (~338-371) populate them from `wopts_sidebar_*` (same accessors macOS uses in `darwin/window.m` ~744-751; `wopts_sidebar_numeric_id` is the pre-allocated sidebar slot).

- [ ] **Step 2: Build the split in `zapp_ios_materialize_pending_windows`** (~90-166). When `d->hasSidebar`:
  1. `UISplitViewController* split = [[UISplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];`
  2. `UIViewController* sidebarVC = ...` (primary column) + `UIViewController* contentVC = ...` (secondary column); set each `view.backgroundColor`.
  3. `[split setViewController:sidebarVC forColumn:UISplitViewControllerColumnPrimary];` + `…contentVC forColumn:…Secondary];`
  4. `split.preferredDisplayMode = d->sidebarCollapsed ? UISplitViewControllerDisplayModeSecondaryOnly : UISplitViewControllerDisplayModeOneBesideSecondary;` (+ `preferredSupplementaryColumnWidth`/`preferredPrimaryColumnWidthFraction` from width as a hint).
  5. `window.rootViewController = split;`  ← **before any webview creation**
  6. Register the window + split in the sidebar registry (T3's `zapp_sidebar_register`, or stash on the deferred for T3 to register).
  7. **Then** create webviews: `darwin_webview_create_ext(window, …, mainUrl, host_numeric_id, …, contentVC.view, /*identity*/host_numeric_id, /*pane_role*/0, /*host_has_sidebar*/true)` and `darwin_webview_create_ext(window, …, d->sidebarUrl, d->sidebarNumericId, …, sidebarVC.view, /*identity*/host_numeric_id, /*pane_role*/1, true)`.
  When `!d->hasSidebar`: the existing single-VC + single-webview path, unchanged.

- [ ] **Step 3: Dual-slot event fan-out.** Confirm `zapp_dispatch_event_to_js` (~293-331) reaches BOTH the host slot and the sidebar slot for a logical window (mirror `darwin/window.m` ~265-276). If it currently assumes one webview per window, extend it to fan to the sidebar slot too. (Window events must reach both panes, as on macOS.)

- [ ] **Step 4: iOS build + macOS no-regression.**

```bash
cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build --platform ios   # links
cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build                   # macOS green
```
Both `[zapp] build complete`. (The kitchen-sink already declares a sidebar window on macOS — confirm the iOS build picks up the same `sidebar` option.)

- [ ] **Step 5: Commit.**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/window.m
git commit -m "feat(ios): materialize a UISplitViewController + dual-pane webviews for sidebar windows

ZappIOSDeferred carries sidebar opts; materialize builds the split (sidebar=
primary, content=secondary), attaches it as rootViewController BEFORE creating
the two pane webviews (avoids WKWebView reparent/bridge reset), and fans window
events to both slots. Non-sidebar windows unchanged.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 6: RISK GATE — human Simulator smoke.** `cd kitchen-sink && ZAPP_NATIVE_LANG=nim bun run dev --platform ios` → the window shows **two panes** (content + sidebar), both webviews load and their JS bridges work (the sidebar pane logs/renders). This de-risks webview-in-split-column + dual registry. **Pause for the user.** If a pane is blank or the bridge is dead, the materialize order or the `_ext` mount is wrong — fix before T3.

---

### T3: `ios/sidebar.m` controls + events

**Files:**
- Modify: `native/platform/ios/sidebar.m`
- (maybe) Modify: `native/platform/ios/window.m` (register hook / delegate plumbing)

- [ ] **Step 1: Replace the no-op stubs** (~8-13) with real impls + a per-window registry (keyed by `UIWindow*`/numeric id; resolve the window via the existing `darwin_window_get_by_numeric_id`). Mirror `darwin/sidebar.m`'s structure (registry + control + emit), adapting AppKit→UIKit:
  - `darwin_sidebar_toggle/collapse/expand` → set `split.preferredDisplayMode` (`.oneBesideSecondary` ↔ `.secondaryOnly`); on iOS 16+ also `[split show/hideColumn:UISplitViewControllerColumnPrimary]` (guard `@available(iOS 16, *)`, fall back to `preferredDisplayMode`).
  - `darwin_sidebar_set_width` → best-effort `preferredSupplementaryColumnWidth` / `preferredPrimaryColumnWidthFraction`.
  - `darwin_sidebar_set_collapsible` → store; gate hideability.
  - `darwin_sidebar_set_resizable` → **no-op** (documented; no divider drag on iOS).
  - Add the iOS `zapp_sidebar_register(void* window_ptr, void* splitVC, void* sidebarVC, int32_t host_id, int32_t sidebar_slot_id)` called from T2's materialize.

- [ ] **Step 2: Events via `UISplitViewControllerDelegate`.** Set the split's delegate (a small ObjC class in sidebar.m). On display-mode/column change, emit `window:sidebar-collapsed` / `window:sidebar-expanded` (and `-resized` with `{"width":…}` when the visible primary width changes) to **both** panes — reuse the macOS fan-out pattern (`darwin_window_eval_js` per slot, target `"win-<hostId>"`; mirror `darwin/sidebar.m`'s `zapp_sidebar_emit`/`zapp_pane_emit`). The runtime `createSidebarHandle` already listens for these and updates `handle.collapsed`/`width`.

- [ ] **Step 3: iOS build + parity lint.**

```bash
cd /Users/zach/code/zapp/kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build --platform ios
cd /Users/zach/code/zapp && bun test cli/src/ios-platform-parity.test.ts
```
Both green (the six `darwin_sidebar_*` are now real defs; any new cross-layer extern is caught by the lint).

- [ ] **Step 4: Commit.**

```bash
cd /Users/zach/code/zapp
git add native/platform/ios/sidebar.m native/platform/ios/window.m
git commit -m "feat(ios): sidebar controls + events via UISplitViewController

darwin_sidebar_toggle/collapse/expand -> preferredDisplayMode (+ show/hideColumn
on iOS16+); set_width best-effort; set_resizable no-op (no iOS divider drag).
UISplitViewControllerDelegate fans window:sidebar-collapsed/expanded/resized to
both panes (mirrors macOS). Closes the v1 'planned v2' stub.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### T4: kitchen-sink conditional toggle + smoke + docs

**Files:**
- Modify: the kitchen-sink Sidebar section (`kitchen-sink/src/sections/*sidebar*` — locate it)
- Modify: docs (`docs/api-reference.md` + the native-chrome / platform doc)

- [ ] **Step 1: iOS conditional toggle.** In the kitchen-sink Sidebar section, render an in-page "Toggle sidebar" button when `Platform.isIOS` (import `Platform` from `@zappdev/runtime`), wired to `win.sidebar.toggle()`. macOS keeps using the native toolbar button (leave its behavior unchanged). Same sidebar content + API both platforms.

- [ ] **Step 2: tsc + tests + builds.**

```bash
cd /Users/zach/code/zapp && bunx tsc --noEmit && bun test
cd kitchen-sink && ZAPP_NATIVE_LANG=nim bun run build && ZAPP_NATIVE_LANG=nim bun run build --platform ios
```
All green / `[zapp] build complete`.

- [ ] **Step 3: Docs.** Update `docs/api-reference.md` (Sidebar section): iOS support via `UISplitViewController`, the new `Platform` API, and the explicit macOS↔iOS degradations (vibrancy/material deferred, `setResizable` no-op, `setWidth` best-effort, iPad side-by-side vs iPhone drawer).

- [ ] **Step 4: Commit.**

```bash
cd /Users/zach/code/zapp
git add kitchen-sink/src docs/
git commit -m "docs+demo: kitchen-sink iOS sidebar toggle (Platform.isIOS) + iOS sidebar docs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Human smoke (GATE).** `ZAPP_NATIVE_LANG=nim bun run dev --platform ios` on an **iPad** sim (side-by-side panes; toggle collapses/expands; `window:sidebar-*` events fire) AND an **iPhone** sim (sidebar as drawer; toggle shows/hides it). Pause for the user.

---

## After all tasks

- **Final cross-impl review** (subagent): macOS sidebar untouched (no regression in `darwin/*.m`); the iOS `darwin_sidebar_*` semantics match the runtime API contract + the macOS event names/fan-out; the materialize order is correct (split before webviews); dual-slot fan-out reaches both panes; degradations are documented, not silent; `Platform` reads the same manifest as `permissions.ts`.
- **Docs/roadmap:** record iOS sidebar as the first iOS native-chrome element; note inspector/toolbar/popover as the follow-on cycles.
- **Parked:** the human iPad + iPhone smokes (T2 gate + T4 gate).

## Self-Review notes (author)

- **Spec coverage:** Platform API (T0), `_ext` port (T1), split materialize risk-gate (T2), controls+events (T3), kitchen-sink+docs (T4). All spec components mapped.
- **No new API/C-ABI:** T1–T3 fill iOS `.m` against the existing `darwin_sidebar_*` + `darwin_webview_create_ext` surface; T0 is the only new (TS) public API and it's additive.
- **macOS no-regression** is gated in every native task (the macOS build is re-run; iOS changes are in `ios/*.m` only).
- **Risk isolation:** the WKWebView-reparent + dual-registry risk is a dedicated human-gated task (T2 Step 6) before controls are built.
- **No placeholders:** T0 is exact; T1–T3 give API mappings + the authoritative macOS reference lines to mirror (transcribing 150+ lines of iOS ObjC here would be less accurate than pointing at the working macOS source).
