# iOS sidebar via UISplitViewController — design

**Date:** 2026-06-19
**Branch:** `feat/nim-native`
**Context:** first native-chrome showcase on iOS (follows gap #5 / M1 — Nim build runs on the iOS Simulator).
**Status:** approved, ready for implementation plan

## Background

The macOS sidebar is shipped ("Model A"): `NSWindow.contentViewController =
NSSplitViewController`, with the sidebar and content each a separate
`NSSplitViewItem` hosting its **own** WKWebView, mounted via
`darwin_webview_create_ext(..., container_view, identity_window_id, pane_role)`
(`darwin/window.m` ~744-975, `darwin/webview.m` ~812-1166, `darwin/sidebar.m`).

Everything **above** the native layer is already platform-agnostic and used by
macOS today:
- runtime `SidebarOptions` + `SidebarHandle` + `app.window.create({ sidebar })`
  + `createSidebarHandle` (`runtime/window.ts` ~235-258, ~660-675, ~877-927);
- the `sidebar:*` router actions;
- the six `darwin_sidebar_*` C-ABI symbols (toggle/collapse/expand/set_width/
  set_collapsible/set_resizable);
- the `window:sidebar-collapsed/expanded/resized` events.

On iOS these are **deliberate no-op stubs** (`ios/sidebar.m` is 13 lines of
`(void)` no-ops; its comment: *"macOS-only in v1; UISplitViewController is the
planned v2"*), and the iOS window hosts a single WKWebView (no split). This
design implements the iOS native sidebar against the **same** API + C-ABI — no
new surface.

## Goal

`app.window.create({ sidebar: { url, … } })` produces a real native
`UISplitViewController` on iOS; `win.sidebar.toggle/collapse/expand/…` drive it;
`window:sidebar-*` events fire. Auto-adapts iPad (side-by-side columns) ↔ iPhone
(overlay/drawer). It's an iOS `.m`-only change, so it benefits **both** the zc
and Nim builds and advances the "native chrome you can't fake in CSS" family on
a new platform.

## Architecture (mirrors the macOS Model A)

When a window's options carry a `sidebar`, the iOS window's `rootViewController`
becomes a modern column-style **`UISplitViewController`** (`.doubleColumn`,
iOS 15+ — already the M1 deployment-min):

- **primary (sidebar) column** → a `UIViewController` hosting the **sidebar
  WKWebView** (loads `sidebar.url`).
- **secondary (content) column** → a `UIViewController` hosting the **content
  WKWebView**.

Both webviews are created through a **ported `darwin_webview_create_ext`** (the
macOS extended entry, currently iOS has only the thin `darwin_webview_create`):
`container_view` = the column VC's `view`; `identity_window_id` = the *host*
window id (so the sidebar's JS reports the host `windowId`, matching macOS);
`pane_role` = 0 (content) / 1 (sidebar). The sidebar pane gets the
`globalThis[Symbol.for('zapp.isSidebar')]=true` marker and both panes get
`zapp.hasSidebar` — the **same markers the kitchen-sink shell already branches
on** (from the macOS sidebar cycle), so the web layer needs no changes.

The six `darwin_sidebar_*` symbols map to `UISplitViewController`:

| Runtime API | iOS mapping |
|---|---|
| `toggle` / `collapse` / `expand` | `preferredDisplayMode` (`.oneBesideSecondary` ↔ `.secondaryOnly`) + `show/hideColumn:` (iOS 16+) |
| events `sidebar-collapsed` / `expanded` (+ `resized`) | `UISplitViewControllerDelegate` display-mode / column-change callbacks → emit `window:sidebar-*` to **both** panes (via `darwin_window_eval_js` per slot) |
| `setWidth` | best-effort: `preferredSupplementaryColumnWidth` / `preferredPrimaryColumnWidthFraction` (iOS manages column widths; not a free pixel set) |
| `setCollapsible` | drives whether the column can hide |
| `setResizable` | **degrade — no-op** (iOS has no user divider-drag) |

**iPad ↔ iPhone is automatic:** `UISplitViewController` lays out side-by-side on
regular width (iPad) and collapses to an overlay/drawer on compact width
(iPhone). Same code, both behaviors; `toggle/collapse/expand` remain meaningful
in each mode.

**Toggle trigger — web-driven on iOS (for now):** on macOS the usual collapse
trigger is the native `NSToolbar` `toggleSidebar` button. iOS has no native
toolbar yet (a later cycle = `UINavigationBar`), so the app drives
`win.sidebar.toggle()` from its **own web UI** (plus `UISplitViewController`'s
built-in edge-swipe gesture for free). So an app conditionally renders an
in-page toggle on iOS. That conditional needs a runtime platform check — see the
**Platform runtime API** component below.

## Components / decomposition

### T0 — `Platform` runtime API (TS-only, no native change)

Apps need a runtime platform check for conditional rendering (the iOS in-page
sidebar toggle, and beyond). The value already exists per-webview — the
bootstrap config injects `globalThis[Symbol.for("zapp.bootstrapConfig")]
.permissions.platform` (`"macos"|"ios"|"windows"`, target-correct after gap #5
T2 made the Nim build's manifest platform target-derived; the zc path already
emits it). It's read **internally** by `permissions.ts` (`bootstrapManifest()`)
but has **no public API**.

Add a small public `Platform` (new `runtime/platform.ts`, exported from
`runtime/index.ts`):
```ts
Platform.current(): "macos" | "ios" | "windows"   // reads the manifest; defaults "macos"
Platform.isMacOS / isIOS / isWindows              // boolean conveniences
```
Reads the same `Symbol.for("zapp.bootstrapConfig")?.permissions?.platform` that
`permissions.ts` uses (factor a shared read or import it). Pure runtime,
unit-testable by mocking the global (same pattern as `worker.test.ts` /
`events.test.ts`). No native or C-ABI change. (Alternative shape considered:
`App.platform` — chose a dedicated `Platform` namespace for discoverability +
the boolean conveniences; not blocking.)

### T1 — port `darwin_webview_create_ext` to iOS (`native/platform/ios/webview.m`)

Add the extended webview entry mirroring `darwin/webview.m`: parameters
`container_view` (a `UIView*` to mount into, vs today's implicit
`rootViewController.view`), `identity_window_id` (JS `windowId` override),
`pane_role` (0/1/3). Inject the pane-role bootstrap markers (`isSidebar` for
role 1, `hasSidebar` into both panes) alongside the existing bootstrap scripts
(`ios/webview.m` ~742-797). Keep the thin `darwin_webview_create` working
(single-pane path) — it can delegate to `_ext` with `container_view = nil`
(root view) + `pane_role = 0`. **macOS untouched.**

### T2 (RISK GATE) — materialize builds the split + both pane webviews

- Extend `ZappIOSDeferred` (`ios/window.m` ~44-63) with the sidebar fields, read
  from `wopts_sidebar_*` in `darwin_window_create` (~338-371): `hasSidebar`,
  `sidebarUrl`, `sidebarNumericId` (pre-allocated, like macOS), `collapsed`,
  `width`/`minWidth`/`maxWidth`, `collapsible`, `resizable`,
  `material`/`backgroundColor` (stored; vibrancy deferred).
- In `zapp_ios_materialize_pending_windows` (~90-166), when `hasSidebar`, build
  in **this exact order** (risk #1): allocate `UISplitViewController` →
  allocate the two column `UIViewController`s → `setViewController:forColumn:`
  → `window.rootViewController = split` → **then** call
  `darwin_webview_create_ext` for content (role 0, host id) and sidebar
  (role 1, sidebar slot, host identity) into the column views. Register both
  webview slots; ensure `zapp_dispatch_event_to_js` fans to both (risk #2).
- **Gate (human Sim smoke):** a window with a sidebar shows two panes, both
  webviews load and their bridges work. De-risks webview-in-split-column +
  dual-registry before building controls.

### T3 — `ios/sidebar.m` controls + events

Replace the no-op stubs with real impls + a per-window registry (keyed by
`UIWindow*`/numeric id, resolved via the existing `darwin_window_get_by_numeric_id`):
- `toggle/collapse/expand` → set `preferredDisplayMode` (+ `show/hideColumn:` on
  iOS 16+);
- `set_width` best-effort; `set_collapsible` → column hideability;
  `set_resizable` no-op (documented);
- a `UISplitViewControllerDelegate` detects display-mode/column changes and
  emits `window:sidebar-collapsed/expanded` (and `-resized` with `{width}` when
  the visible width changes) to **both** panes — matching macOS's `zapp_pane_emit`
  fan-out.
- Add the create-time `zapp_sidebar_register` (iOS variant: `UIWindow*` +
  `UISplitViewController*` + sidebar `UIViewController*` + host/sidebar ids).

### T4 — kitchen-sink smoke + docs

The kitchen-sink Sidebar section is web UI that already branches on the pane
markers, so it should render natively once T1–T3 land. Add the **iOS conditional
toggle**: the section renders an in-page "Toggle sidebar" button when
`Platform.isIOS` (driving `win.sidebar.toggle()`), since iOS has no native
toolbar button yet — same sidebar content + API as macOS, just the extra trigger
on iOS. Verify on an **iPad** sim (side-by-side) and an **iPhone** sim (drawer):
the toggle button collapses/expands the native split, and `window:sidebar-*`
events fire. Update docs (api-reference / the native-chrome doc) to record iOS
sidebar support, the `Platform` API, and the explicit macOS↔iOS degradations.

## C-ABI / parity constraints

- iOS must define the same six `darwin_sidebar_*` symbols (today's stubs become
  real) + the iOS `zapp_sidebar_register`. The last cycle's extended
  `ios-platform-parity.test.ts` (scans `ios/*.m` externs ↔ Nim `{.exportc.}` /
  `.m` defs) covers any new cross-layer extern automatically.
- No `.zc` changes, no runtime API changes, no new C-ABI — pure iOS `.m` fill +
  iOS window construction.

## macOS ↔ iOS divergences (intrinsic platform gaps — documented, not silent)

- **Sidebar vibrancy/material** — macOS `NSVisualEffectView`; iOS deferred
  (UIBlurEffect later). The `material`/`backgroundColor` options are accepted but
  the iOS pane renders solid in v1.
- **User-drag resize** (`setResizable`) — no iOS analog (no divider drag); no-op.
- **`setWidth`** — best-effort via the `UISplitViewController` width hints, not a
  guaranteed pixel width.
These are recorded in docs as expected platform differences (per the
surface-every-divergence principle), and the runtime API stays identical.

## Testing

- **macOS no-regression:** the `_ext` port + the iOS window changes are iOS-only;
  the macOS build + sidebar are untouched. Gate: macOS `bun run build` green.
- **iOS build gate:** `ZAPP_NATIVE_LANG=nim bun run build --platform ios`
  produces an arm64 iOS-sim Mach-O; the parity lint stays green.
- **Human Sim smoke (the real proof):** kitchen-sink with the sidebar section —
  iPad sim shows side-by-side panes (content + sidebar), `toggle/collapse/expand`
  work, `window:sidebar-*` events fire in both panes; iPhone sim shows the
  adaptive drawer.
- `bun test` + `bunx tsc --noEmit` green (no TS changes expected; the runtime
  API already exists).

## Out of scope

- Inspector / toolbar / popover on iOS (later cycles).
- Sidebar vibrancy/material + user-drag resize (degradations above).
- Multi-window / iPad multi-scene.
- Any change to the macOS sidebar or the runtime API.

## Risks

1. **Webview creation order** — re-parenting a WKWebView resets its content
   process and breaks the bridge (macOS's own comment warns this). Mitigated by
   the explicit materialize order in T2 (split + columns + attach **before**
   webview creation) and the T2 human gate.
2. **Dual-webview registry / event fan-out** — two webview slots per logical
   window; `zapp_dispatch_event_to_js` must reach both (macOS already does).
   Covered in T2 + verified by the sidebar-event smoke in T3/T4.
3. **iOS version API drift** — `show/hideColumn:` is iOS 16+; `preferredDisplayMode`
   is the 15+ baseline. Guard the 16+ calls; fall back to `preferredDisplayMode`.
