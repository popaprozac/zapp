# Native Sidebar Windows (macOS v1) — Design

**Date:** 2026-06-10
**Status:** Approved (brainstorm) → ready for implementation plan
**Branch:** `feat/native-sidebar`

## Context

No web-shell framework (Tauri, Wails, Electron, Electrobun, zero-native) can
render a real native macOS sidebar — they all fake it with CSS +
`backdrop-filter`, which cannot reproduce the actual sidebar material, the
full-height-under-titlebar layout, the traffic-light inset, or the system
collapse animation. With liquid glass (macOS 26 "Tahoe") the fake is even
further from the real thing. Zapp already has the building blocks: the
`vibrancy` window option maps `"sidebar"` → `NSVisualEffectMaterialSidebar`
with a working transparent-webview path (`darwin/window.m:481-505`,
`darwin/webview.m:1002-1012`), and the embedded-webview ("panel") cycle proved
multiple WKWebViews per window with per-webview message routing. The macOS
build uses the host SDK with no version-min pin (Xcode 26.4 today), so the
liquid-glass sidebar treatment comes from building against the macOS 26 SDK
with graceful classic-vibrancy fallback on older systems.

**The feature:** `Window.create({ sidebar: { url, ... } })` produces a window
whose root is an `NSSplitViewController` with a real `.sidebar`
`NSSplitViewItem` hosting a transparent, fully-trusted WKWebView. Web content
inside native sidebar chrome ("Model A" — chosen over a native
`NSOutlineView` source-list, which is a possible v2 mode).

## Decisions (locked in brainstorm)

1. **Model A** — the sidebar hosts a transparent WKWebView (the app's own web
   UI) inside the native sidebar chrome. Native rows (Model B) are out.
2. **API shape** — a `sidebar` options object on `Window.create` (like
   `vibrancy`/`asSheetOf`), carrying `url`, sizing, `material`, collapse opts.
3. **Identity: host-window twin.** The sidebar webview gets the FULL bootstrap
   (bridge, Services, Events, permissions manifest — trusted app code, unlike
   sandboxed `<zapp-webview>` embeds). `Window.current()` in sidebar context
   resolves to the **host** window handle — the sidebar is an accessory of the
   window, not its own window. The sidebar's own handle is
   `Window.current().sidebar` / `win.sidebar` — the same `SidebarHandle`
   reachable uniformly from both panes. `Window.isSidebar()` reports the
   context for branching.
4. **v1 lifecycle: create-time only + toggle API.** Declared at
   `Window.create`; lives for the window's life. Runtime control:
   `toggle()/collapse()/expand()/setWidth()` + collapse events + the native
   divider/system behaviors. No attach/detach-after-create, no destroy, no
   native toolbar in v1.

## API

```ts
// runtime/window.ts
export interface SidebarOptions {
  /** Entry URL/route for the sidebar webview (same origin rules as the window url). Required. */
  url: string;
  /** Initial width in points. Default 260. */
  width?: number;
  /** Divider drag limits. Defaults 180 / 400. */
  minWidth?: number;
  maxWidth?: number;
  /** User can collapse via system behaviors. Default true. */
  collapsible?: boolean;
  /** Start collapsed. Default false. */
  collapsed?: boolean;
  /**
   * Background material. Default "sidebar" — the system sidebar material
   * (liquid glass on macOS 26+, classic sidebar vibrancy earlier). Accepts the
   * same material names as the `vibrancy` window option.
   */
  material?: string;
}

export interface SidebarHandle {
  toggle(): void;
  collapse(): void;
  expand(): void;
  setWidth(px: number): void;
  /** Tracked from native collapse events, seeded by the create option. */
  readonly collapsed: boolean;
}

// WindowOptions gains:
//   sidebar?: SidebarOptions;
// WindowHandle gains:
//   readonly sidebar?: SidebarHandle;   // present iff created with one
// Window namespace gains:
//   Window.isSidebar(): boolean;        // true when running in a sidebar webview
// WindowEvent gains:
//   SIDEBAR_COLLAPSED, SIDEBAR_EXPANDED (payload: { windowId })
```

Usage:

```ts
const win = await Window.create({
  title: "Mail-ish",
  url: "/index.html",
  sidebar: { url: "/sidebar.html", width: 260, minWidth: 180, maxWidth: 400 },
});
win.sidebar!.toggle();
win.on(WindowEvent.SIDEBAR_COLLAPSED, () => ...);

// From code running IN the sidebar:
Window.isSidebar();                 // true
Window.current().setTitle("Inbox"); // acts on the HOST window
Window.current().sidebar!.collapse(); // the sidebar's own handle, same path
Events.emit("nav:select", { id });  // normal bus reaches the main pane
```

## Native architecture (macOS)

When `sidebar` is present in the options, window construction branches:

- **Root:** the window's `contentViewController` becomes an
  `NSSplitViewController` (instead of `contentView = webview`).
  - Item 1: `NSSplitViewItem(sidebarWithViewController:)` — `.behavior =
    .sidebar` supplies the material (liquid glass on macOS 26 when built
    against that SDK), full-height-under-titlebar layout, traffic-light
    inset, the system collapse animation, and divider behavior. Configure
    `minimumThickness`/`maximumThickness` from `minWidth`/`maxWidth`,
    `canCollapse` from `collapsible`, `isCollapsed` from `collapsed`, and the
    initial width from `width`. If `material` overrides the default, set it on
    the item's effect view where the API allows (fall back to the default
    sidebar behavior when it doesn't).
  - Item 2: a plain `NSViewController` whose view hosts the **main** webview
    (and the existing `vibrancy` NSVisualEffectView wrapper when that option
    is also set — `vibrancy` remains orthogonal and applies to the main pane
    only).
- **Window chrome:** sidebar windows get `NSWindowStyleMaskFullSizeContentView`
  + `titlebarAppearsTransparent` + hidden title (the standard sidebar-app
  look). An explicitly-set `titleBarStyle` option still wins.
- **Sidebar webview:** a second full-bootstrap WKWebView created through the
  same creation pipeline as the main one, made transparent via the existing
  `drawsBackground=NO` / clear-layer path so the native material shows
  through, and mounted as the sidebar view controller's view.
- **New file `native/platform/darwin/sidebar.m`:** per-window split registry
  (keyed by the host's numeric window id), `darwin_sidebar_toggle/collapse/
  expand/set_width`, and the split-view delegate/observation that detects
  collapse state changes and emits the two window events. Window-construction
  branching lives in `window.m`; `sidebar.m` owns everything after.
- **iOS stubs `native/platform/ios/sidebar.m`:** every `darwin_sidebar_*`
  referenced from shared `.zc` needs an iOS definition (the #281 parity rule).
  On iOS the `sidebar` option is **ignored with a log** (`[zapp] sidebar: not
  supported on iOS yet — rendering main url only`); `UISplitViewController`
  is the natural v2. Windows likewise ignores it.

**The one required refactor:** `darwin_webview_create` today mounts the
webview itself (`setContentView` / vibrancy-subview). It must learn to mount
into a **caller-provided container view** (the split item's view) — or return
unmounted and let `window.m` mount. This touches the most central native
path; the plan must keep the no-sidebar path byte-for-byte equivalent.

## Identity & routing (host-window twin mechanics)

- The sidebar webview registers at its **own slot** in the per-webview
  dispatch table (`zapp_webviews[]`) with its own pre-allocated numeric id, so
  invoke request/response transport routes to/from the sidebar webview
  correctly with zero changes.
- **Window actions resolve to the host for free:** macOS resolves a numeric id
  to a window via `zapp_webviews[id].window` — and the sidebar webview's
  `.window` IS the host `NSWindow`. So `Window.current().setTitle(...)` from
  sidebar code acts on the host window mechanically.
- **`Window.current()` returns the host handle:** the sidebar bootstrap
  injects the HOST's `Symbol.for('zapp.windowId')` value (`win-<host>`)
  plus `Symbol.for('zapp.isSidebar') = true`. The runtime's existing
  current() machinery then produces a host-window handle; `Window.isSidebar()`
  reads the flag. (Transport replies don't depend on the injected windowId —
  they route by the message's slot id — so injecting the host id is safe; the
  plan must verify the one place the injected id IS used for transport, the
  subscribe action, and route sidebar subscriptions to the host id.)
- **Window events forward to the sidebar:** native window-event emission for
  window N additionally evals into N's sidebar slot when one exists (small
  addition at the existing emit helper), so `win.on(WindowEvent.RESIZE)` works
  in sidebar code.
- **Events bus:** broadcasts already reach every registered webview — the
  sidebar participates with no changes. Sidebar↔main communication is the
  normal `Events` bus; no new channel.
- **`SidebarHandle` state:** `collapsed` is tracked in the runtime from the
  two window events, seeded by the create option — no native query route in
  v1. Control methods post t:4 actions `sidebar:toggle | sidebar:collapse |
  sidebar:expand | sidebar:setWidth` routed in `router.zc` →
  `darwin_sidebar_*`.
- **Teardown:** window close tears the sidebar webview down through the same
  per-webview WKWebView teardown path as the main one (stopLoading, handlers,
  delegates), and clears its dispatch slot.

## Permissions / security

- The sidebar is **trusted app UI** — full bridge, same posture as the main
  webview. (Untrusted content still belongs in `<zapp-webview>` embeds; a
  sidebar wanting to show third-party content embeds a `<zapp-webview>`
  inside itself.)
- No new permission id: sidebar control ops are window-ops-on-an-existing
  window (never gated, by the permissions-v1 design); creating a sidebar
  window already rides `window:create`. `permission_id_for_action` returns
  `""` for `sidebar:*` actions — the plan should add them to the
  ungated-by-design list in `docs/security.md`.
- The permissions manifest reaches the sidebar via its bootstrapConfig like
  any webview; `ensurePermission` mirrors work unchanged.

## Known limitations (v1, documented)

- A `<zapp-webview>` embed created from either pane overlays at the window
  level (flat z-order, the documented embed limitation) — an embed positioned
  in the main pane will cover the sidebar if scrolled under it. Deferred with
  the other embed leak mitigations.
- No native toolbar (the unified toolbar + the standard sidebar-toggle
  button). v1 apps toggle from their own UI or shortcuts. Follow-up.
- No attach/detach after create; no Model B native rows; no per-sidebar
  devtools special-casing (inspect via the normal inspectable flag — both
  webviews honor it).
- `width` after user drag is not queryable in v1 (no getState route);
  `setWidth` is fire-and-forget.

## Verification

- bun tests: options plumbing (TS types compile; any pure helpers).
- Builds: macOS + ios-sim both ending `[zapp] build complete:`; #281 parity
  lint passes (new `darwin_sidebar_*` get iOS stubs).
- Headless smoke: a sidebar window boots BOTH webviews (sidebar console.log
  visible? webview logs aren't piped headless — assert via Events round-trip:
  sidebar emits, main pane receives, service logs), toggle/collapse actions
  don't crash, collapse events arrive.
- Regression: windows WITHOUT `sidebar` construct exactly as before (the
  refactor gate) — existing hello-world demo unaffected.
- **Visual smoke (user):** hello-world gains a "New Window (sidebar)" demo —
  liquid glass material, full-height under titlebar, traffic-light inset,
  native collapse animation, divider drag with min/max. The look is the
  feature; it needs eyeballs on macOS 26.

## Follow-ups (out of scope)

- Native toolbar (NSToolbar unified style + standard sidebar-toggle item).
- iOS `UISplitViewController` implementation.
- Model B: native source-list rows (declarative list API like menus/tray).
- Attach/detach sidebar at runtime; width/state query route; trailing
  (inspector) split item — `NSSplitViewItem` inspector behavior is the same
  machinery and a cheap v2 once this lands.

## File inventory

| File | Change |
|---|---|
| `runtime/window.ts` | `SidebarOptions`, `SidebarHandle`, `WindowOptions.sidebar`, `WindowHandle.sidebar`, `Window.isSidebar()`, 2 new `WindowEvent`s, collapsed-state tracking |
| `native/window/window.zc` | sidebar fields on `WindowOptions` + `window_opts_apply_json` parsing |
| `native/app/router.zc` | t:4 `sidebar:*` action routing → `darwin_sidebar_*` |
| `native/platform/darwin/window.m` | construction branch: NSSplitViewController root when sidebar opts present; chrome defaults |
| `native/platform/darwin/webview.m` | mount-into-container refactor (no-sidebar path unchanged); host-windowId + isSidebar bootstrap injection for sidebar webviews; window-event forward to sidebar slot |
| `native/platform/darwin/sidebar.m` (new) | split registry, `darwin_sidebar_*` ops, collapse observation → events |
| `native/platform/ios/sidebar.m` (new) | stubs (parity rule); iOS ignores the option with a log |
| `native/window/callbacks.zc` / events plumbing | 2 new window-event ids end-to-end |
| `docs/api-reference.md`, `docs/security.md`, `README.md` | sidebar docs; ungated-by-design note; feature bullet + platform-table row |
| `hello-world/src/*` (user WIP — never staged) | sidebar demo window + sidebar.html route as the smoke vehicle |
