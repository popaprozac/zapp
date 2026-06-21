# SwiftUI-backed accessories — Sub-cycle 2a (runtime pane control bridge, macOS) — Design

**Date:** 2026-06-21 · **Branch:** `feat/nim-native` (do not merge to main) · **Track:** Apple-only (macOS-first; iOS is Sub-cycle 3)

## Where this sits

Sub-cycle 1 shipped the SwiftUI pane **render** on macOS — `native/platform/darwin/swift/panes.swift` (`PaneHost` representable + `PaneLayout` `NavigationSplitView`/`.inspector`) plus the `window.m` construction fork, AppKit `NSSplitViewController` fallback. It left four known limitations (see `docs/native-ui-strategy.md`): toolbar glitch, sidebar-presents-as-overlay, **runtime pane control not wired**, per-platform sidebar default docs.

Sub-cycle 2 ("pane chrome + control") splits into three specs, built in order:

- **2a (THIS spec) — runtime pane control bridge (visibility).** The enabling primitive: an ObjC↔Swift state bridge so Zapp's existing runtime sidebar/inspector **visibility** APIs drive the SwiftUI panes, and SwiftUI-originated visibility changes emit the same window events as the AppKit path. Closes the dead-inspector-toggle limitation (the inspector finally renders + toggles).
- **2b — per-world toolbar.** SwiftUI `.toolbar` renderer behind one app-facing toolbar spec; toggle items call this 2a bridge.
- **2c — presentation styles + width/lock parity.** tile/overlay styles, width control + width events, `setCollapsible`/`setResizable` parity, per-platform default docs.

## Goal (2a)

On the **SwiftUI pane path** (macOS 14+, accessory'd window, `native.swiftui != false`):

- the existing runtime visibility ops — `darwin_sidebar_toggle` / `darwin_sidebar_collapse` / `darwin_sidebar_expand` and `darwin_inspector_toggle` / `darwin_inspector_collapse` / `darwin_inspector_expand` — drive the SwiftUI panes (forward direction), and
- SwiftUI-originated visibility changes (the user toggling/dismissing a pane, or a programmatic op) emit the same `window:sidebar-collapsed`/`-expanded` and `window:inspector-collapsed`/`-expanded` events the AppKit path emits (reverse direction).

The user-visible payoff: the inspector **renders and toggles** (Sub-cycle 1 left it collapsed/untoggleable), and the kitchen-sink's in-content sidebar/inspector toggle buttons (which call these runtime APIs) now work on the SwiftUI path.

## Approach — `PaneState` ObservableObject + scalar C-ABI (Approach A, approved)

A `final class PaneState: ObservableObject` in `panes.swift` is the single piece of shared state crossing the boundary. `PaneLayout` observes it (`@ObservedObject`) and **derives** its bindings from it (the `NavigationSplitView` `columnVisibility` binding and the `.inspector(isPresented:)` binding). ObjC owns the `PaneState` lifetime: the `@_cdecl` create returns a `+1`-retained handle. **Ownership lives in one place — the window delegate** (`ZappWindowDelegate.swiftPaneState`), released exactly once at window teardown. The per-pane `ZappSidebarController` / `ZappInspectorController` hold a **non-owning** copy of the same handle purely to route forward calls (both may point at the same `PaneState`, so neither releases it).

The existing `ZappSidebarController` / `ZappInspectorController` gain a **SwiftUI backing**: a controller is backed by either its `NSSplitViewItem` (today) **or** a `swiftPaneState` handle. Each `darwin_*` op branches on which backing the resolved controller has — the runtime API surface is unchanged, only the controller internals fork. This reuses the existing slot→`NSWindow`→registry resolution (`zapp_sidebar_for_slot` / `zapp_inspector_for_slot`) and the existing emit helper (`zapp_pane_emit`) verbatim.

### Perf/size posture (core Zapp tenet)

- Crossings are **cold-path** (pane toggles happen at human-interaction frequency).
- **Scalar C-ABI, no marshaling**: forward setters take `(state*, bool)`; the reverse callback carries `(ctx, int32 key, int64 value)`. No JSON, no string copy, no per-call allocation.
- **Reverse path is change-driven** (`@Published` `didSet` → C callback), never polled — zero idle cost.
- **No new bundle weight**: Swift/SwiftUI are OS-provided (resolved via SDK `.tbd` + `/usr/lib/swift` from the foundation cycle). 2a adds only `panes.swift` object code.

## The bridge primitive — shaped as the BYO-SwiftUI seam

The reverse "dispatcher" is authored now as a **generic, documented contract** rather than a pane-specific signature, so it is the deliberate prototype of the future "bring-your-own-SwiftUI" bridge (app writes SwiftUI against documented dispatcher keys → picks the changes up Nim-side). Full app-facing generalization is **out of scope for 2a** and tracked as follow-up **#622**.

- **Contract type:** `typedef void (*ZappSwiftStateCallback)(void* ctx, int32_t key, int64_t value);` — generic, scalar, main-thread, change-driven SwiftUI→native state channel.
- **Keys (2a):** `ZAPP_PANE_KEY_SIDEBAR_VISIBLE = 1`, `ZAPP_PANE_KEY_INSPECTOR_PRESENTED = 2`. Values are `0`/`1`. The `int64` value is deliberately wide enough to carry widths/other scalars in 2c without changing the contract.
- **Dispatcher:** a `switch (key)` in `window.m` routing to per-pane handlers (`zapp_sidebar_note_swiftui_visibility` / `zapp_inspector_note_swiftui_visibility`). The switch is the extensible seam — adding a key is a new arm, not a new contract.
- **`ctx`:** the host `NSWindow*` (the registry key), so a handler resolves its controller and reuses the existing per-pane emit + dedup.

What 2a does **not** ship (→ #622): any app-facing key registration, a string/JSON channel, or a Nim-side public receiver/driver API.

## Components

### `native/platform/darwin/swift/panes.swift` (refactor)

- **`final class PaneState: ObservableObject`** with `@Published var sidebarVisible: Bool` and `@Published var inspectorPresented: Bool`, a stored `ctx: UnsafeMutableRawPointer?`, and a stored `cb: ZappSwiftStateCallback?` (`@convention(c)` C function pointer). Each property's `didSet` calls `cb?(ctx, key, value ? 1 : 0)` with its key. (Fires for both user-originated and programmatic changes, matching the AppKit KVO contract; ObjC dedups.)
- **`PaneLayout`** takes `@ObservedObject var state: PaneState` (instead of the current `@State showInspector` + raw `let`s for visibility). It derives:
  - a `Binding<NavigationSplitViewVisibility>` for `NavigationSplitView(columnVisibility:)` — get: `state.sidebarVisible ? .all : .detailOnly`; set: `state.sidebarVisible = (newValue != .detailOnly)`.
  - the `.inspector(isPresented: Binding(get: { state.inspectorPresented }, set: { state.inspectorPresented = $0 }))`.
  - The webview-hosting `PaneHost`s and `.navigationSplitViewStyle(.balanced)` are unchanged (tiling is 2c).
- **New `@_cdecl`s** (scalar C-ABI):
  - `zapp_swift_panes_state_create(_ ctx: UnsafeMutableRawPointer?, _ cb: ZappSwiftStateCallback?, _ sidebarVisible: Bool, _ inspectorPresented: Bool) -> UnsafeMutableRawPointer?` — allocs a `PaneState` with initial values, returns `Unmanaged.passRetained(...).toOpaque()`.
  - `zapp_swift_panes_state_release(_ state: UnsafeMutableRawPointer)` — `Unmanaged<PaneState>.fromOpaque(state).release()`.
  - `zapp_swift_panes_set_sidebar_visible(_ state: UnsafeMutableRawPointer, _ visible: Bool)` and `zapp_swift_panes_set_inspector_presented(_ state: UnsafeMutableRawPointer, _ presented: Bool)` — set the published var (caller guarantees main thread; the `darwin_*` ops already wrap in `on_main`).
  - `zapp_swift_panes_toggle_sidebar(_ state: UnsafeMutableRawPointer)` and `zapp_swift_panes_toggle_inspector(_ state: UnsafeMutableRawPointer)` — flip the published var. Toggle is implemented Swift-side because `PaneState` is the authoritative source of current visibility; ObjC never reads it back. (Setting a published `Bool` always fires `didSet`, even to the same value; the reverse-path dedup against `lastCollapsed` — below — absorbs any redundant set, so the ObjC ops need no idempotent guard.)
- **`zapp_swift_panes_create`** gains a leading `state` param: `zapp_swift_panes_create(_ state: UnsafeMutableRawPointer, _ content:, _ sidebar:, _ inspector:) -> NSView*`. It builds `PaneLayout(state:)` (initial visibility now lives in `PaneState`, so the old `showInspector` Bool param is dropped). Still returns a `+1`-retained `NSHostingView`.

### `native/platform/darwin/sidebar.m` and `inspector.m` (modify, parallel changes)

- Add `@property (nonatomic, assign) void* swiftPaneState;` to `ZappSidebarController` / `ZappInspectorController` (assign, **non-owning** — the window delegate owns the single reference; controllers only use it to route forward calls).
- A **SwiftUI register variant**, e.g. `void zapp_sidebar_register_swiftui(void* window_ptr, void* paneState, int32_t host_id, int32_t sidebar_slot_id, bool initial_collapsed)` (and the inspector twin). It creates a controller with `swiftPaneState = paneState`, `splitVC`/`sidebarItem` nil, `lastCollapsed = initial_collapsed` (so the dedup baseline matches the visibility `PaneState` was created with), and **installs no KVO/`NSNotification` observers** (there is no `NSSplitView` to observe; the Swift callback is the observation source). It registers under the same host-`NSWindow` key so `zapp_sidebar_for_slot` resolves it.
- **Branch each control op** at the top: if the resolved controller has `swiftPaneState`, route to the Swift setter and return; else the existing `NSSplitViewItem` path (byte-unchanged):
  - `darwin_sidebar_toggle` → `zapp_swift_panes_toggle_sidebar(state)` (direction decided Swift-side from the authoritative state — no `lastCollapsed` read).
  - `darwin_sidebar_collapse` → `zapp_swift_panes_set_sidebar_visible(state, false)`; `darwin_sidebar_expand` → `set_sidebar_visible(state, true)`.
  - inspector twins → `zapp_swift_panes_toggle_inspector` / `set_inspector_presented`.
  - `darwin_sidebar_set_width` / `set_collapsible` / `set_resizable` (+ inspector twins) on a `swiftPaneState` controller: **documented no-op** with a `ZAPP_LOG` debug line ("[zapp] sidebar set_width ignored on SwiftUI path (2c)"). (2c work.)
- A **reverse emit-and-dedup entry** exported for the dispatcher: `void zapp_sidebar_note_swiftui_visibility(void* window_ptr, bool collapsed)` — resolves the controller by `window_ptr`, dedups against `lastCollapsed` (early-return if unchanged), updates it, and calls the existing `zapp_sidebar_emit(c, collapsed ? "sidebar-collapsed" : "sidebar-expanded", nil)`. Inspector twin emits `inspector-collapsed`/`-expanded`. (Note: `value`/`visible` is inverted to `collapsed` for the existing event names — `visible == false ⇒ collapsed`.)
- `zapp_sidebar_unregister` / `zapp_inspector_unregister`: when the controller is SwiftUI-backed (`swiftPaneState != NULL`), skip the KVO/observer removal (none were installed) and **do not** release `swiftPaneState` (non-owning). The owning release happens once in window teardown (below).

### `native/platform/darwin/window.m` (modify — the existing SwiftUI fork)

In the `useSwiftUIPanes` branch (the `#ifdef ZAPP_HAS_SWIFTUI` block that today builds the containers and calls `zapp_swift_panes_create`):

- Define the key enum + a `static` dispatcher: `static void zapp_swiftui_pane_changed(void* ctx, int32_t key, int64_t value)` that `switch`es on `key` → `zapp_sidebar_note_swiftui_visibility((void*)ctx, value == 0)` / `zapp_inspector_note_swiftui_visibility((void*)ctx, value == 0)` (value is "visible"; `collapsed = (value == 0)`).
- Compute initial visibility from the same window config Sub-cycle 1 used (sidebar visible by default; inspector from `inspectorCollapsed`): `sidebarVisible = useSidebar` (a sidebar'd window starts expanded), `inspectorPresented = useInspector && !inspectorCollapsed`.
- `void* paneState = zapp_swift_panes_state_create((void*)window /* host NSWindow* */, &zapp_swiftui_pane_changed, sidebarVisible, inspectorPresented);`
- `paneHost = zapp_swift_panes_create(paneState, mainContainer, sidebarContainer, inspectorContainer);` (drop the old `showInspector` arg).
- After setting `window.contentView = paneHost` (as today): **register the SwiftUI controllers** (the piece Sub-cycle 1 omitted), passing the initial collapsed baseline: `if (useSidebar) zapp_sidebar_register_swiftui(window, paneState, hostId, sidebarSlotId, !sidebarVisible);` and `if (useInspector) zapp_inspector_register_swiftui(window, paneState, hostId, inspectorSlotId, !inspectorPresented);`.
- Declare the new externs (`zapp_swift_panes_state_create`/`_release`/`_set_sidebar_visible`/`_set_inspector_presented`/`_toggle_sidebar`/`_toggle_inspector`, the two `register_swiftui`, the two `note_swiftui_visibility`) under `#ifdef ZAPP_HAS_SWIFTUI`, alongside the existing `zapp_swift_panes_create` extern.
- **Own the `PaneState` lifetime:** add `@property (nonatomic, assign) void* swiftPaneState;` to `ZappWindowDelegate`; set it to the created `paneState` in the SwiftUI branch; in the existing window teardown (where `zapp_sidebar_unregister`/`zapp_inspector_unregister` are already called), after unregister, `if (delegate.swiftPaneState) { zapp_swift_panes_state_release(delegate.swiftPaneState); delegate.swiftPaneState = NULL; }` — released exactly once regardless of how many panes the window has.
- The AppKit `else` branch is unchanged; the teardown gains only the single guarded release above.

### Nim / TS

No changes. The runtime sidebar/inspector visibility APIs and event names already exist (used by the AppKit path); 2a only makes them reach the SwiftUI panes. The kitchen-sink already has the in-content toggle controls.

## Data flow

1. window.m builds the accessory'd window; the gate resolves `useSwiftUIPanes` (unchanged).
2. It creates the pane webviews + containers (unchanged), creates the `PaneState` (with initial visibility + the dispatcher callback), builds the hosting view via `zapp_swift_panes_create(state, …)`, sets it as `contentView`, and registers the SwiftUI controllers.
3. **Forward:** app calls e.g. `win.inspector.toggle()` → router → `darwin_inspector_toggle` → controller has `swiftPaneState` → `zapp_swift_panes_set_inspector_presented(state, true)` → `@Published` flips → `.inspector` presents → inspector webview renders.
4. **Reverse:** any visibility change (user dismiss or programmatic) → `@Published` `didSet` → `ZappSwiftStateCallback(ctx=window, key, value)` → window.m dispatcher → `zapp_*_note_swiftui_visibility(window, collapsed)` → dedup → `zapp_pane_emit` → both panes' JS receive `window:inspector-collapsed`/`-expanded` etc.

No loop: emit dispatches JS only; it never mutates `PaneState`.

## Error handling / fallback

- **Opted out** (`native.swiftui:false`): `swiftc` skipped, `ZAPP_HAS_SWIFTUI`/`-d:zappSwiftUI` undefined → the whole SwiftUI branch `#ifdef`s out → AppKit (registers the real `NSSplitViewItem` controllers as today). No swift symbols.
- **macOS < 14:** `@available` false → AppKit.
- **Plain window** (no accessories): AppKit (unchanged).
- **Nil `PaneState`** (state-create returns nil — only if `< macOS 14`, already gated): window.m falls through to the AppKit path (guaranteed floor).

## Testing

- **Build gates:** macOS default links the new `panes.swift` symbols + builds clean; opted-out (`native.swiftui:false`) builds clean with **no swift**; iOS-sim still builds (macOS-only change); `bun test cli/src` green (no CLI surface change, so this is a regression check).
- **Human visual smoke (macOS 14):** in the kitchen-sink sidebar+inspector window on the SwiftUI path —
  - the in-content **inspector toggle** shows/hides the inspector and the **inspector webview renders** (the Sub-cycle-1 breakage is gone);
  - the in-content **sidebar collapse/expand** controls drive the sidebar;
  - JS receives `window:inspector-collapsed`/`-expanded` and `window:sidebar-collapsed`/`-expanded` (observe via the kitchen-sink event log / console);
  - title bar / traffic lights intact; assets + bridge still work.
  - With `native: { swiftui: false }` (then reverted): identical to today (AppKit), all the same controls + events work.
- No unit tests for the native UI itself — build + visual smoke is the established gate.

## Non-goals (later sub-cycles / follow-ups)

- **Per-world toolbar** (2b) — including the SwiftUI auto-toggle/`NSToolbar` collision fix and the dead toolbar inspector button.
- **Width control + width events** on the SwiftUI path; `setCollapsible`/`setResizable` parity (2c) — no-ops with a log line in 2a.
- **Presentation styles** (tile vs overlay; `.balanced`→forced tile) + **per-platform default docs** (2c).
- **iOS** (Sub-cycle 3 — `UIHostingController`, the adaptive payoff).
- **Full BYO-SwiftUI app-facing surface** (#622) — 2a ships only the internal seam (named callback contract + switch dispatcher + scalar keys).
