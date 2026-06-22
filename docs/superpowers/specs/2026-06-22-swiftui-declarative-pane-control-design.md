# Declarative SwiftUI Pane-Control — Design (#660)

**Date:** 2026-06-22
**Branch:** `feat/nim-native` (do NOT merge to main)
**Status:** Approved design → ready for implementation plan
**Predecessor:** SwiftUI Accessories Sub-cycle 2c (#656). 2c shipped create-time pane
geometry + the titlebar/toolbar parity model; it left runtime resize/collapsible/width
on the SwiftUI path implemented via an AppKit reach-through that proved **transient**.
This cycle replaces that reach-through with a declarative mechanism.

---

## Problem

On the macOS SwiftUI pane path (`native.swiftui` on, multi-pane windows), the runtime
sidebar/inspector controls — `setWidth`, resize-lock, collapsible — are implemented by
reaching through the `NSHostingController` to the `NSSplitView`/`NSSplitViewItem` that
backs SwiftUI's `NavigationSplitView` / `.inspector`, then calling `setPosition`, pinning
`min/max thickness`, and toggling `canCollapse`. This works for a single op but is
**transient**: SwiftUI owns the column layout and re-asserts it on every relayout
(collapse→expand, a setWidth-triggered relayout, window resize), wiping the imperative
state.

Concrete bugs the user observed (both panes), which this cycle fixes:

- `setWidth` doesn't move a resizable column (the inspector clamps back to its original
  width; the sidebar ignores the request while resizable).
- Collapse→re-expand resets resize-lock and collapsible (controls desync from reality).
- `setResizable(false)` then collapse/expand re-enables resize.
- Setting width re-activates resize/collapse regardless of the configured state.
- The sidebar's native toolbar toggle collapses the sidebar even when `collapsible:false`
  (the create-time `canCollapse=NO` doesn't stop SwiftUI's `columnVisibility`, and the
  runtime `setCollapsible` reach-through never updated SwiftUI's view of "collapsible").
- The main-view sidebar toggle button's UI state doesn't stay synced with the sidebar's
  real visibility.

Root cause: mixing imperative AppKit mutation with SwiftUI's declarative layout — SwiftUI's
relayout always wins. (Same wall as the 2b `window.toolbar` clobber and the original
`.ignoresSafeArea` overlay.)

## Goal

Identical end-user API **and** result whether `native.swiftui` is on or off, for: setWidth,
resize-lock toggle, collapsible toggle, and persistence across collapse→re-expand. The
runtime TS API (`runtime/window.ts` `SidebarHandle`/`InspectorHandle` +
`SidebarOptions`/`InspectorOptions`) is **unchanged** — it is the parity point.

## Approach

Drive **all** pane geometry/state through `@Published` fields on `PaneState`, bound to
SwiftUI's own column modifiers, so every relayout re-applies our **current** values
(idempotent) instead of wiping them. The AppKit path (`swiftui:false`) keeps the existing
reach-through — it is durable there (no SwiftUI relayout to fight).

This is a re-architecture of the SwiftUI branch only. AppKit pane control, the runtime TS
API, `router.nim`, and the `wopts_*` accessors are untouched.

---

## Architecture

### Source of truth: `PaneState` (`native/platform/darwin/swift/panes.swift`)

Promote create-time geometry to live observable state and add the inspector twin (inspector
width/resizable/collapsible are currently NOT in `PaneState` — they live only in
`inspector.m`). New/changed members:

```swift
final class PaneState: ObservableObject {
  // existing
  @Published var sidebarVisible: Bool { didSet { cb?(ctx, kPaneKeySidebarVisible, sidebarVisible ? 1 : 0) } }
  @Published var inspectorPresented: Bool { didSet { cb?(ctx, kPaneKeyInspectorPresented, inspectorPresented ? 1 : 0) } }
  let ctx: UnsafeMutableRawPointer?
  let cb: ZappSwiftStateCallback?
  let bleedTop: Bool

  // sidebar geometry — width/resizable/collapsible now LIVE (were let / absent)
  @Published var sidebarWidth: CGFloat       // current ideal/target width (no didSet — see width events)
  @Published var sidebarResizable: Bool
  @Published var sidebarCollapsible: Bool    // was a `let`; promoting it is the core fix
  @Published var sidebarPinned: Bool = false // transient: forces a fixed width for one render (setWidth)
  let sidebarMinW: CGFloat
  let sidebarMaxW: CGFloat

  // inspector geometry — all NEW
  @Published var inspectorWidth: CGFloat
  @Published var inspectorResizable: Bool
  @Published var inspectorCollapsible: Bool
  @Published var inspectorPinned: Bool = false
  let inspectorMinW: CGFloat
  let inspectorMaxW: CGFloat

  // dedup baselines for reverse width events (plain vars, not @Published)
  private var lastSidebarWidthEmitted: Int = -1
  private var lastInspectorWidthEmitted: Int = -1
}
```

`sidebarMinW/MaxW` and `inspectorMinW/MaxW` stay `let` — they are config-time bounds, not
runtime-mutable in this cycle.

### The column modifiers (`PaneLayout`)

Width and resize are one declarative decision driven by `resizable` + the transient `pinned`
flag:

- **Sidebar** (`NavigationSplitView` column):
  ```swift
  // useFixed locks the column to an exact width (not draggable);
  // the range form allows the user to drag within [min, max].
  let useFixed = !state.sidebarResizable || state.sidebarPinned
  PaneHost(view: sidebar)
    .ignoresSafeArea(.container, edges: state.bleedTop ? .top : [])
    .modifier(SidebarColumnWidth(fixed: useFixed, width: state.sidebarWidth,
                                 min: state.sidebarMinW, max: state.sidebarMaxW))
    .background(WidthReader { w in state.noteSidebarWidth(w) })
  ```
  where `SidebarColumnWidth` applies `.navigationSplitViewColumnWidth(width)` when `fixed`,
  else `.navigationSplitViewColumnWidth(min: min, ideal: width, max: max)`.

- **Inspector** (`.inspector` column): same shape with `.inspectorColumnWidth(_:)` (fixed)
  vs `.inspectorColumnWidth(min:ideal:max:)` (range), plus its own `WidthReader`. This is
  the first time the inspector column width is declarative — it replaces `inspector.m`'s
  thickness re-pin entirely.

- **Collapsible** — the existing binding-clamps, now reading `@Published` flags so they
  re-evaluate live:
  - sidebar: `sidebarVisibilityBinding` setter already has
    `if !state.sidebarCollapsible && newValue == .detailOnly { return }` — promoting
    `sidebarCollapsible` to `@Published` is what makes this respect a *runtime* change.
  - inspector: add the twin clamp to `inspectorPresentedBinding`:
    `if !state.inspectorCollapsible && newValue == false { return }`.

### Forcing width while staying resizable — pin-and-release

Setting `ideal:` on an already-laid-out resizable column is only a hint; SwiftUI won't snap
a column the user has dragged. The `setWidth` setter does a one-render pin-and-release:

```swift
@_cdecl("zapp_swift_panes_set_sidebar_width")
public func zapp_swift_panes_set_sidebar_width(_ state: UnsafeMutableRawPointer, _ w: Int32) {
  let st = Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue()
  st.sidebarWidth = CGFloat(w)
  if st.sidebarResizable {
    st.sidebarPinned = true                          // this render: fixed width -> forces the snap
    DispatchQueue.main.async { st.sidebarPinned = false }  // next tick: range -> stays draggable at the new width
  }
}
```

After the pin, `ideal == sidebarWidth` and the current width *is* `sidebarWidth`, which is
inside `[min, max]`, so releasing the pin keeps the column at the new width and draggable.
Inspector uses the identical pattern with `inspectorPinned`.

### Reverse sync — width and visibility events reach the runtime

Visibility already flows back through `PaneState`'s `didSet` → `ZappSwiftStateCallback`
(keys 1/2) → `zapp_sidebar_note_swiftui_visibility` / `zapp_inspector_note_swiftui_visibility`
→ `sidebar-collapsed`/`-expanded` events. That fixes the toggle-button-sync bug.

Width events are NEW and come from a geometry observer, not a `didSet` (a user drag does not
mutate the `@Published` width, so `didSet` can't see it — but the rendered width changes).
A lightweight `WidthReader` reports the rendered width; `PaneState.noteSidebarWidth` /
`noteInspectorWidth` dedup by integer point width and fire the callback with new keys:

```swift
struct WidthReader: View {
  let onChange: (CGFloat) -> Void
  var body: some View {
    GeometryReader { geo in
      Color.clear.onChange(of: geo.size.width, initial: true) { _, w in onChange(w) }
    }
  }
}

func noteSidebarWidth(_ w: CGFloat) {
  let iw = Int(w.rounded())
  if iw <= 0 || iw == lastSidebarWidthEmitted { return }
  lastSidebarWidthEmitted = iw
  cb?(ctx, kPaneKeySidebarWidth, Int64(iw))
}
```

This captures BOTH programmatic relayout and user drag, giving the SwiftUI path the same
`sidebar-resized` / `inspector-resized` events the AppKit `splitViewDidResize` path emits.

### Native dispatcher + reverse-emit (`window.m`, `sidebar.m`, `inspector.m`)

Add two reverse keys and route them to new dedup'd emitters mirroring the visibility ones:

```c
// window.m — enum + dispatcher
enum { ZAPP_PANE_KEY_SIDEBAR_VISIBLE = 1, ZAPP_PANE_KEY_INSPECTOR_PRESENTED = 2,
       ZAPP_PANE_KEY_SIDEBAR_WIDTH = 3, ZAPP_PANE_KEY_INSPECTOR_WIDTH = 4 };
// in zapp_swiftui_pane_changed:
case ZAPP_PANE_KEY_SIDEBAR_WIDTH:   zapp_sidebar_note_swiftui_width(ctx, (int)value); break;
case ZAPP_PANE_KEY_INSPECTOR_WIDTH: zapp_inspector_note_swiftui_width(ctx, (int)value); break;
```

`zapp_sidebar_note_swiftui_width(window_ptr, int width)` / the inspector twin: resolve the
controller, dedup against `lastWidth`, emit `sidebar-resized` / `inspector-resized` with
`{"width":N}` — the same payload the AppKit path emits.

### Control-op rewiring (`sidebar.m` / `inspector.m`)

Each runtime control op gains a SwiftUI early-return that calls the new `@Published` setter;
the existing AppKit body runs only when `swiftPaneState == nil`:

```c
void darwin_sidebar_set_width(int32_t window_id, int32_t width) {
  zapp_sidebar_on_main(^{
    ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
    if (!c) return;
#ifdef ZAPP_HAS_SWIFTUI
    if (c.swiftPaneState) { zapp_swift_panes_set_sidebar_width(c.swiftPaneState, width); return; }
#endif
    // ... existing AppKit setPosition body unchanged ...
  });
}
```

Same shape for `darwin_sidebar_set_collapsible` → `zapp_swift_panes_set_sidebar_collapsible`,
`darwin_sidebar_set_resizable` → `zapp_swift_panes_set_sidebar_resizable`, and the three
`darwin_inspector_*` twins. After this, the SwiftUI branch no longer reaches through, so
`zapp_sidebar_bind_swiftui` / `zapp_inspector_bind_swiftui` (and their use of
`zapp_find_split_view` / `zapp_webview_for_slot`) become dead on the pane path and are
removed from `sidebar.m` / `inspector.m`. The helper definitions in `window.m` stay (they
may serve `toolbar.m`'s trackingSeparator path — out of scope here).

### Create-time wiring (`window.m`)

Widen `zapp_swift_panes_state_create` to carry the full initial geometry for both panes:

```c
extern void* zapp_swift_panes_state_create(
    void* ctx, ZappSwiftStateCallback cb,
    bool sidebarVisible, bool inspectorPresented, bool bleedTop,
    double sidebarMinW, double sidebarWidth, double sidebarMaxW,
    bool sidebarResizable, bool sidebarCollapsible,
    double inspectorMinW, double inspectorWidth, double inspectorMaxW,
    bool inspectorResizable, bool inspectorCollapsible);
```

Populated from the existing accessors: `wopts_sidebar_min_width/width/max_width`,
`wopts_sidebar_can_resize`, `wopts_sidebar_collapsible`, and the `wopts_inspector_*`
equivalents. With resizable/collapsible now create-time on the SwiftUI path, the post-hoc
`darwin_sidebar_set_resizable(host_slot,false)` / `darwin_inspector_set_resizable(...)`
calls at `window.m:1402/1409` are skipped on the SwiftUI branch (they remain for AppKit).

---

## Data flow

```
config (zapp.config.ts / app.nim)
  -> wopts_* accessors
  -> zapp_swift_panes_state_create(... full geometry ...)   [create-time]
  -> PaneState @Published fields
  -> SwiftUI column modifiers (.navigationSplitViewColumnWidth / .inspectorColumnWidth + binding-clamps)

runtime control (sidebar.setWidth / .setResizable / .setCollapsible, inspector twins)
  -> router.nim (unchanged) -> darwin_sidebar_* / darwin_inspector_*
  -> [SwiftUI] zapp_swift_panes_set_* -> @Published mutation -> SwiftUI relayout (idempotent)
  -> [AppKit]  existing reach-through (unchanged)

reverse (user drag / collapse / programmatic relayout)
  visibility: PaneState didSet -> cb (key 1/2) -> note_swiftui_visibility -> sidebar/inspector -collapsed/-expanded
  width:      WidthReader -> noteSidebarWidth/noteInspectorWidth -> cb (key 3/4) -> note_swiftui_width -> -resized
```

## Semantics (explicit decisions for review)

- **`collapsible:false` gates user/system collapse affordances only** — the divider snap and
  SwiftUI's native sidebar toggle. Programmatic `collapse()`/`expand()`/`toggle()` and the
  app's own toolbar toggle button still work. This matches the AppKit path, where
  `[item animator] setCollapsed:` ignores `canCollapse`. (If stricter "the app's own toggle
  is also blocked" semantics are wanted, that's a follow-up — it would diverge from AppKit.)
- **`setWidth` clamps to `[min, max]`** in the native/runtime layer as today; the SwiftUI
  modifier's range enforces it as well.
- **Width-resize events** fire on both user drag and programmatic width changes (parity with
  AppKit's `splitViewDidResize`), dedup'd by integer point width.

## Error handling / edge cases

- All `@_cdecl` setters run on the main thread (callers already dispatch via
  `zapp_*_on_main`; the setters mutate `@Published` directly, which must be main-thread).
- `WidthReader` dedup prevents a drag from flooding the bridge; `note_swiftui_width` dedups
  again natively (belt-and-suspenders, mirrors visibility).
- `pinned` release uses `DispatchQueue.main.async` (one runloop tick); if the window tears
  down between set and release, the `PaneState` is still retained by the hosting controller
  (unchanged ownership), so the async release is safe.
- `#ifdef ZAPP_HAS_SWIFTUI` guards every Swift-symbol reference so the AppKit-only /
  opted-out build never references an undefined symbol (`swiftPaneState` is nil there).
- Pre-layout: if `WidthReader` reports 0 before layout, `noteSidebarWidth` ignores it
  (`iw <= 0`).

## Testing

- **Native (compile/link):** Nim macOS build ends with `[zapp] build complete: …` and a
  fresh binary mtime (Vite's `✓ built` is NOT success). `swiftui:false` AppKit build
  unchanged. iOS-sim build (the `.m`-only-symbol gate — `#281` lint only covers
  `.zc`-referenced symbols). `bun test cli/src` (iOS parity lint).
- **Human visual smoke (the gate):** with `native.swiftui` on vs off, verify identical end
  result for, on BOTH sidebar and inspector:
  1. `setWidth(N)` snaps to N and the column stays draggable afterward (resizable case).
  2. `setResizable(false)` locks the width; collapse→re-expand keeps it locked.
  3. `setCollapsible(false)` blocks the native sidebar toggle + divider; programmatic
     toggle still works.
  4. Drag-resize emits `*-resized`; collapse/expand emits `*-collapsed`/`*-expanded`;
     toggle-button UI stays synced.
- Kitchen-sink (`kitchen-sink/zapp.config.ts` — **never commit**) drives the smoke; the
  Sidebar/Inspector sections already exercise these controls.

## File structure

| File | Responsibility | Change |
| --- | --- | --- |
| `native/platform/darwin/swift/panes.swift` | declarative source of truth | new `@Published` fields, `WidthReader`, column modifiers, 6 new `@_cdecl` setters, widened `state_create` |
| `native/platform/darwin/window.m` | NSWindow build + reverse dispatcher | 2 new pane keys + dispatcher arms, widened `state_create` call (full inspector geometry), skip post-hoc resizable on SwiftUI branch, externs for new symbols |
| `native/platform/darwin/sidebar.m` | sidebar control ops + reverse emit | route SwiftUI branch of set_width/collapsible/resizable to new setters; add `zapp_sidebar_note_swiftui_width`; remove dead `bind_swiftui` reach-through |
| `native/platform/darwin/inspector.m` | inspector control ops + reverse emit | same as sidebar; inspector width now fully declarative (drop thickness re-pin) |
| `runtime/window.ts`, `native/nim/router.nim`, `wopts_*` | parity point | **unchanged** |
| `docs/native-ui-strategy.md` (+ api-reference if needed) | parity matrix | update: SwiftUI runtime pane control is now declarative + durable; note the `collapsible` semantics |

## Out of scope / follow-ups

- Runtime mutation of pane min/max bounds (only width/resizable/collapsible are runtime here).
- `toolbar.m` trackingSeparator on the SwiftUI path (#638).
- Stricter `collapsible` semantics that also block the app's own toggle (would diverge from
  AppKit).
- Removing the now-dead `zapp_find_split_view`/`bind_swiftui` *definitions* from `window.m`
  (left in place; may serve other callers).
