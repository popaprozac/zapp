# SwiftUI-backed accessories — Sub-cycle 2b (per-world toolbar, macOS) — Design

**Date:** 2026-06-21 · **Branch:** `feat/nim-native` (do not merge to main) · **Track:** Apple-only (macOS-first; iOS reuses this in a later sub-cycle)

## Where this sits

Sub-cycle 2a shipped the runtime pane **control** bridge (visibility) on the SwiftUI path. It left two toolbar problems (Sub-cycle-1/2a known limitations): the **collision** (an `NSToolbar` is attached to the window in *both* fork branches, and on the SwiftUI path `NavigationSplitView`/`.inspector` auto-inject their own toggles + reflow it → app items flicker/vanish) and the **dead sidebar toggle** (the system `toggleSidebar` item auto-wires to an `NSSplitViewController`, which doesn't exist on the SwiftUI path).

**Decision (user-affirmed): Strategy B — render the toolbar in whichever world owns the content.** On the SwiftUI pane path, render the window toolbar via SwiftUI **`.toolbar`** (no `NSToolbar`); on the AppKit path, keep `NSToolbar` unchanged. Rationale: lean into SwiftUI on the SwiftUI path, and — decisively — modern **iPadOS** toolbars converge on the macOS/SwiftUI model, so a SwiftUI `.toolbar` renderer built now is the foundation the iOS sub-cycle reuses (iOS has no `NSToolbar`; `NavigationSplitView` + `.toolbar` is the only coherent placement). One app-facing toolbar spec drives both worlds; only the native renderer forks.

**Toggle authorship: Strategy A — faithful to the app spec.** The app declares its toolbar items (`toggleSidebar`/`toggleInspector` with positions, plus custom buttons); the SwiftUI renderer maps them faithfully (toggles bound to `PaneState`, in declared order) and **suppresses** SwiftUI's auto sidebar toggle (`.toolbar(removing: .sidebarToggle)`). SwiftUI does the *rendering*; the app keeps *authorship* — consistent with the AppKit path. (A pinned, optional exploration of letting SwiftUI own the sidebar toggle — Strategy B-for-toggles — runs only if the A renderer is stable; see Testing.)

## The generic ObjC↔Swift↔Nim bridge (this is how 2b communicates)

2b does **not** invent toolbar-specific bridge functions. It grows the generic, key-routed native-module channel that 2a started — the same seam that will let app devs wire up their own native modules ([[BYO #622]]):

- **`ZappNativeModule` Swift protocol:** `func applyScalar(key: Int32, value: Int64)` + `func applyString(key: Int32, value: String)`. Module state objects conform. `ToolbarState` conforms in 2b; `PaneState` can adopt later (unification = #622, **not** retrofitted here).
- **Scalar channel (2a, unchanged):** forward scalar setters + reverse `ZappSwiftStateCallback(ctx, int32 key, int64 value)`. Used by `PaneState` (pane visibility). Stays for hot/simple state — perf tenet.
- **String channel (NEW in 2b):** forward `@_cdecl zapp_swift_module_set_string(void* state, int32_t key, const char* value)` (protocol-dispatched → `applyString`); reverse `typedef void (*ZappSwiftStringCallback)(void* ctx, int32_t key, const char* value)`. For structured/cold-path data. The toolbar is its first consumer.
- **Keys (toolbar module's namespace):** forward — `ZAPP_TB_SET_ITEMS=1` (full `toolbarJson`), `ZAPP_TB_UPDATE_ITEM=2` (one `itemJson`), `ZAPP_TB_CLEAR=3`. reverse — `ZAPP_TB_EVT_CLICK=1` (value=itemId), `ZAPP_TB_EVT_MENU_CLICK=2` (value=menuId).

Per perf/size tenet: the string channel carries JSON only on **cold paths** (toolbar set/update — app config + occasional updates), reusing the existing `toolbarJson` wire (no new marshaling format); the scalar channel remains for anything hot. Nothing bundled.

## The hosting pivot + risk gate (Task 1)

SwiftUI `.toolbar` only surfaces in the window's title bar when the SwiftUI tree is hosted via **`NSHostingController` set as the window's `contentViewController`** — the bare **`NSHostingView`** set as `contentView` (what Sub-cycle 1/2a uses) generally does **not** bridge `.toolbar` to the `NSWindow`'s toolbar. So 2b **leads with a risk gate**: switch the SwiftUI-path hosting from `NSHostingView`→`NSHostingController`, apply a trivial `.toolbar` (one button + the sidebar + inspector toggles), and confirm:

1. the toolbar renders in the **title bar**, items are tappable, and a click routes (`window:toolbar-clicked`);
2. the panes + **real webviews** + bridge + **all 2a control/visibility** still work unregressed under `NSHostingController`;
3. **chrome metrics** still measure (does an `NSToolbar` get created under the hood so the existing `contentLayoutRect` KVO still fires, or do we measure the hosting view's safe-area?).

If `.toolbar` won't bridge even via `NSHostingController`, that's a Task-1 finding that reshapes the approach (e.g. a titlebar-accessory `NSHostingController`) — better surfaced first than late. The pivot affects the proven 2a render path, so the gate explicitly re-smokes panes + 2a control.

## Components

### `native/platform/darwin/swift/toolbar.swift` (new — one file per SwiftUI surface)

- `struct ZappToolbarItem` mirroring the wire model: `id, type (button|toggleSidebar|toggleInspector|trackingSeparator|space|flexibleSpace), label, icon, enabled, indicator, menu: [ZappMenuItem]`.
- `final class ToolbarState: ObservableObject, ZappNativeModule` — `@Published var items: [ZappToolbarItem]`, `@Published var style`; stored `ctx` + reverse `ZappSwiftStringCallback`. `applyString(key,value)`: `SET_ITEMS` → parse full `toolbarJson` (Foundation JSON) → replace `items`; `UPDATE_ITEM` → merge one; `CLEAR` → empty. (`applyScalar` unused → empty.)
- A `ToolbarContent` builder mapping `items` → SwiftUI `ToolbarItem`s: `button` → `Button` (label/SF-or-asset icon; disabled when `!enabled`; `menu` → `Menu`); `toggleSidebar`/`toggleInspector` → `Button` whose action flips the bound `PaneState` (in-tree, no round-trip); `space`/`flexibleSpace` → spacers; `trackingSeparator` → no-op (NavigationSplitView auto-aligns toolbar sections to columns — documented). Button taps fire the reverse `ZappSwiftStringCallback(ctx, CLICK, id)`; menu taps fire `MENU_CLICK`.
- The `@_cdecl` surface (generic, not toolbar-named): `zapp_swift_toolbar_state_create(ctx, ZappSwiftStringCallback) -> handle`, `zapp_swift_toolbar_state_release(handle)`, and reuse the generic `zapp_swift_module_set_string(state, key, value)` for set/update/clear. (`state_create` stays toolbar-named for the typed ctor; the *channel* entry is generic.)

### `native/platform/darwin/swift/panes.swift` (modify)

- `PaneLayout` gains `@ObservedObject var toolbar: ToolbarState` (so `zapp_swift_panes_create` gains a `toolbarState` param, passed through to `PaneLayout`'s init) and applies `.toolbar { ToolbarContent(items: toolbar.items, pane: state) } .toolbar(removing: .sidebarToggle) .toolbarStyle(…from toolbar.style…)`. The toolbar toggle buttons bind to the existing `PaneState` (`state`), so toggles drive the panes directly.
- The `@_cdecl` create entry returns an **`NSHostingController`** (or window.m wraps the hosting view in one) so `.toolbar` bridges — the Task-1 pivot. (`ToolbarState` is created first via `zapp_swift_toolbar_state_create`, then handed to `zapp_swift_panes_create` alongside the existing `PaneState`.)

### `native/platform/darwin/toolbar.m` (modify)

- Factor the existing `zappToolbarItemClicked:` emit (`window:toolbar-clicked` `{windowId,id}` via `darwin_webview_eval_all` + `worker_broadcast_eval_js`) into a shared `void zapp_toolbar_emit_click(int32_t host_id, const char* item_id)`; same for the menu path → `zapp_toolbar_emit_menu_click`. The SwiftUI reverse dispatcher calls these, so SwiftUI clicks route through the **identical** `window:toolbar-clicked` → `TOOLBAR_CLICKED(15)` → existing TS action map. **No runtime/TS changes.**

### `native/platform/darwin/window.m` (modify)

- Host the SwiftUI tree via `NSHostingController` (Task 1).
- On the SwiftUI path: **skip `darwin_toolbar_attach`**; create the `ToolbarState` (ctx = host `NSWindow*`, cb = a file-static `zapp_swiftui_toolbar_event` string-dispatcher that routes `CLICK`/`MENU_CLICK` → the shared emit helpers); push any **initial** `toolbarJson` from window config into it via `zapp_swift_module_set_string(…, SET_ITEMS, json)`; register a window-keyed SwiftUI-toolbar entry; pass the `ToolbarState` into `PaneLayout`. The delegate owns the `ToolbarState` handle and releases it once at teardown (same ownership pattern as `PaneState`).
- AppKit path: `darwin_toolbar_attach` unchanged.

### Router fork (`native/nim/router.nim` `toolbar:*` arm)

- A small ObjC resolver `bool zapp_window_uses_swiftui_toolbar(void* handle)` (true when the window has a SwiftUI-toolbar registration). The `toolbar:setItems`/`updateItem`/`remove` arm forks: SwiftUI-backed → `zapp_swift_module_set_string(state, SET_ITEMS|UPDATE_ITEM|CLEAR, json)`; else the existing `darwin_toolbar_*`.

### Runtime / TS

No changes. `ToolbarItemDef` / `normalizeToolbar` / the `toolbar:*` wire / the `window:toolbar-clicked` action map all work identically; only the native renderer forks.

## Data flow

`win.toolbar.setItems([...])` → `normalizeToolbar` (unchanged) → `toolbar:setItems {windowId, toolbarJson}` → router fork → **SwiftUI:** `zapp_swift_module_set_string(toolbarState, SET_ITEMS, toolbarJson)` → `applyString` parses → `@Published items` → `.toolbar` re-renders in the title bar. Button tap → `ZappSwiftStringCallback(ctx, CLICK, id)` → `zapp_swiftui_toolbar_event` → `zapp_toolbar_emit_click` → `window:toolbar-clicked` → TS action map fires the handler. Toggle tap → `PaneState` binding → pane animates (2a). **AppKit:** unchanged.

## Error handling / fallback

- Opted out (`native.swiftui:false`) or macOS<14 → AppKit `NSToolbar` (unchanged); the SwiftUI toolbar code is `#ifdef ZAPP_HAS_SWIFTUI`-gated (lesson from 2a — guard every Swift-symbol ref).
- Plain (non-accessory) window → AppKit path (unchanged).
- `.toolbar` bridge failure under `NSHostingController` → caught by Task 1 before the renderer is built.

## Testing

- **Task 1 (RISK GATE, human visual):** hosting pivot + trivial `.toolbar` proof (titlebar render, tappable, action routes, panes/webviews/2a-control unregressed, chrome metrics OK).
- Renderer tasks (each build + human-visual gated; the kitchen-sink Toolbar section already exercises `setItems`/`updateItem`/toggles): item types → `ToolbarContent` (button/menu/enabled/indicator/spacers); toggle items bound to `PaneState` + `.toolbar(removing: .sidebarToggle)`; the generic string channel + reverse dispatcher + shared emit; window.m fork + router fork; chrome-metrics/style/trackingSeparator.
- **Build matrix:** macOS enabled (links + builds), opted-out (`swiftui:false`) → AppKit `NSToolbar` path unchanged, iOS-sim builds, `bun test cli/src` green.
- **Final task — pinned B-for-toggles exploration (only if the A renderer is stable):** spike letting `NavigationSplitView` own the sidebar toggle (drop `.toolbar(removing:)` for it), capture placement/behavior differences vs A in a short findings note — info for a future A-vs-B decision, no commitment.

## Non-goals

- **iOS toolbar** — a later sub-cycle reuses this `.toolbar` renderer via `UIHostingController`.
- **Full BYO-native-module registration** (#622) — 2b ships the generic string channel + `ZappNativeModule` protocol (the seam), not the app-facing registration/discovery API, and does not retrofit `PaneState` onto the protocol.
- **`native/nim` → `native/` promotion + zc removal** (#628) — a separate structural cleanup cycle; 2b uses current paths.
- **Cross-pane event fan-out** (#627) — unrelated, separate.
