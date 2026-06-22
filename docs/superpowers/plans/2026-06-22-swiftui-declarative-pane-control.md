# Declarative SwiftUI Pane-Control Rewrite — Implementation Plan (#660)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make runtime sidebar/inspector width / resize-lock / collapsible durable on the macOS SwiftUI pane path by driving them through `@Published` `PaneState` bound to SwiftUI's own column modifiers, replacing the transient AppKit reach-through.

**Architecture:** One source of truth (`PaneState` `@Published` fields) → SwiftUI column modifiers (`.navigationSplitViewColumnWidth` / `.inspectorColumnWidth` always in `min:ideal:max:` form, collapsed to `min==max==width` to lock) + binding-clamps for collapsible. A `pinned` flag does a one-render pin-and-release so `setWidth` forces a snap while staying resizable. A `GeometryReader` (`WidthReader`) observes the rendered width to keep the source of truth current AND emit drag-resize events (parity with AppKit's `splitViewDidResize`). The AppKit path (`swiftui:false`) keeps the existing reach-through unchanged.

**Tech Stack:** Swift (`@_cdecl`, SwiftUI), Objective-C (`window.m`/`sidebar.m`/`inspector.m`), Nim build pipeline. No new test framework — Swift/ObjC UI glue is verified by build gates + a human visual smoke gate (Task 4). `bun test cli/src` (iOS parity lint) runs in the matrix.

**Spec:** `docs/superpowers/specs/2026-06-22-swiftui-declarative-pane-control-design.md`
**Branch:** `feat/nim-native` (do NOT merge to main).
**Commit trailer:** `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

**Standing constraints (all tasks):**
- Use Bun, never Node.
- Native build success = the LAST line is `[zapp] build complete: …` AND a fresh binary mtime. Vite's `✓ built` is NOT success.
- **Never** `git add kitchen-sink/zapp.config.ts` (carries the user's swiftui regression toggle).
- The working tree carries unrelated noise (`assets/*`, `benchmarks/*`, `vendor/*`, untracked `spikes/`, `native/worker/engines/zjs-cross-eval-test.c`). Stage ONLY the task's named files.
- `#ifdef ZAPP_HAS_SWIFTUI` must guard every Swift-symbol reference in `.m` files.

**Refinements over the spec (apply these — they are strictly better, same intent):**
1. The column-width modifier is ALWAYS the `min:ideal:max:` form; "fixed/locked" = collapse the range to `min==max==width`. (Avoids a `_ConditionalContent` modifier-identity switch during pin-and-release — lower risk than swapping between the single-arg and range forms.)
2. `WidthReader` updates the `@Published` width (single source of truth, dedup'd by integer point) so `setResizable(false)` locks at the *current* rendered width (AppKit parity), not a stale programmatic value. No separate `lastRendered` var needed.
3. No edit at `window.m:1402/1409` — those post-hoc `set_resizable` calls are AppKit-only (inside the `else` branch); create-time resizable now flows through the widened `state_create` on the SwiftUI path.

---

## Task 1: Declarative `PaneState` core + widened `state_create` wiring

Rewrites `PaneState` + `PaneLayout` to be fully declarative, adds the 6 runtime setters, the `WidthReader`, and widens `zapp_swift_panes_state_create`; updates the single `window.m` caller + extern to match so the build links. At the end of this task, create-time geometry (including the previously-unapplied SwiftUI `resizable`/`collapsible`) is declarative; runtime setters exist but `sidebar.m`/`inspector.m` still reach through (rewired in Tasks 2–3).

**Files:**
- Modify: `native/platform/darwin/swift/panes.swift` (PaneState, PaneLayout, modifiers, WidthReader, cdecls)
- Modify: `native/platform/darwin/window.m:84-91` (key enum + state_create extern), `:1058-1061` (state_create call)

- [ ] **Step 1: Replace the `PaneState` class** in `native/platform/darwin/swift/panes.swift`

Replace the existing key constants (lines ~20-23) and the entire `PaneState` class (lines ~24-68) with:

```swift
// Keys must match the enum in window.m.
private let kPaneKeySidebarVisible: Int32 = 1
private let kPaneKeyInspectorPresented: Int32 = 2
private let kPaneKeySidebarWidth: Int32 = 3
private let kPaneKeyInspectorWidth: Int32 = 4

// Shared, observable pane state crossing the ObjC<->Swift boundary. ObjC drives it
// via the scalar setters below; SwiftUI drives visibility via the derived bindings
// and width via WidthReader. Every visibility/width change fires `cb` (change-driven,
// never polled). `didSet` is NOT called during init, so creating a PaneState never emits.
//
// 2c/#660: width/resizable/collapsible are LIVE (@Published) so SwiftUI relayouts
// re-apply our CURRENT values (idempotent) instead of wiping an imperative state.
final class PaneState: ObservableObject {
  @Published var sidebarVisible: Bool {
    didSet { cb?(ctx, kPaneKeySidebarVisible, sidebarVisible ? 1 : 0) }
  }
  @Published var inspectorPresented: Bool {
    didSet { cb?(ctx, kPaneKeyInspectorPresented, inspectorPresented ? 1 : 0) }
  }
  // Live sidebar geometry. `sidebarWidth` is the single source of truth (modifier ideal +
  // lock value); WidthReader keeps it tracking the rendered width. `sidebarPinned` is a
  // transient one-render lock that lets setWidth force a snap while staying resizable.
  @Published var sidebarWidth: CGFloat
  @Published var sidebarResizable: Bool
  @Published var sidebarCollapsible: Bool
  @Published var sidebarPinned: Bool = false
  // Live inspector geometry (was absent — inspector width lived only in inspector.m).
  @Published var inspectorWidth: CGFloat
  @Published var inspectorResizable: Bool
  @Published var inspectorCollapsible: Bool
  @Published var inspectorPinned: Bool = false

  let ctx: UnsafeMutableRawPointer?
  let cb: ZappSwiftStateCallback?
  let bleedTop: Bool
  // Config-time bounds (not runtime-mutable in this cycle).
  let sidebarMinW: CGFloat
  let sidebarMaxW: CGFloat
  let inspectorMinW: CGFloat
  let inspectorMaxW: CGFloat

  // Reverse width-event dedup baselines (plain vars — not observed).
  private var lastSidebarWidthEmitted: Int = -1
  private var lastInspectorWidthEmitted: Int = -1

  init(ctx: UnsafeMutableRawPointer?, cb: ZappSwiftStateCallback?,
       sidebarVisible: Bool, inspectorPresented: Bool, bleedTop: Bool,
       sidebarMinW: CGFloat, sidebarWidth: CGFloat, sidebarMaxW: CGFloat,
       sidebarResizable: Bool, sidebarCollapsible: Bool,
       inspectorMinW: CGFloat, inspectorWidth: CGFloat, inspectorMaxW: CGFloat,
       inspectorResizable: Bool, inspectorCollapsible: Bool) {
    self.ctx = ctx; self.cb = cb
    self.sidebarVisible = sidebarVisible
    self.inspectorPresented = inspectorPresented
    self.bleedTop = bleedTop
    self.sidebarMinW = sidebarMinW; self.sidebarWidth = sidebarWidth; self.sidebarMaxW = sidebarMaxW
    self.sidebarResizable = sidebarResizable; self.sidebarCollapsible = sidebarCollapsible
    self.inspectorMinW = inspectorMinW; self.inspectorWidth = inspectorWidth; self.inspectorMaxW = inspectorMaxW
    self.inspectorResizable = inspectorResizable; self.inspectorCollapsible = inspectorCollapsible
  }

  // WidthReader -> here. Keep the source of truth current (so setResizable(false) locks
  // at the rendered width, AppKit parity) AND emit a dedup'd reverse width event (parity
  // with AppKit's splitViewDidResize). Runs on the main thread (onChange fires post-layout).
  func noteSidebarWidth(_ w: CGFloat) {
    let iw = Int(w.rounded())
    if iw <= 0 { return }
    if iw != Int(sidebarWidth.rounded()) { sidebarWidth = CGFloat(iw) }
    if iw != lastSidebarWidthEmitted { lastSidebarWidthEmitted = iw; cb?(ctx, kPaneKeySidebarWidth, Int64(iw)) }
  }
  func noteInspectorWidth(_ w: CGFloat) {
    let iw = Int(w.rounded())
    if iw <= 0 { return }
    if iw != Int(inspectorWidth.rounded()) { inspectorWidth = CGFloat(iw) }
    if iw != lastInspectorWidthEmitted { lastInspectorWidthEmitted = iw; cb?(ctx, kPaneKeyInspectorWidth, Int64(iw)) }
  }
}
```

- [ ] **Step 2: Add the column-width helpers + `WidthReader`** to `native/platform/darwin/swift/panes.swift`, immediately before `struct PaneLayout`:

```swift
// Always the min:ideal:max: form; "locked" collapses the range to min==max==width
// (non-draggable). Reading the @Published fields here (from PaneLayout.body) registers
// the SwiftUI dependency so relayouts re-apply current values.
@available(macOS 14.0, *)
extension View {
  func paneSidebarWidth(_ s: PaneState) -> some View {
    let locked = !s.sidebarResizable || s.sidebarPinned
    return navigationSplitViewColumnWidth(
      min: locked ? s.sidebarWidth : s.sidebarMinW,
      ideal: s.sidebarWidth,
      max: locked ? s.sidebarWidth : s.sidebarMaxW)
  }
  func paneInspectorWidth(_ s: PaneState) -> some View {
    let locked = !s.inspectorResizable || s.inspectorPinned
    return inspectorColumnWidth(
      min: locked ? s.inspectorWidth : s.inspectorMinW,
      ideal: s.inspectorWidth,
      max: locked ? s.inspectorWidth : s.inspectorMaxW)
  }
}

// Observes the rendered width of the view it backgrounds and reports changes.
// `initial: true` reports the first laid-out width. macOS 14+ (two-param onChange).
@available(macOS 14.0, *)
struct WidthReader: View {
  let onChange: (CGFloat) -> Void
  var body: some View {
    GeometryReader { geo in
      Color.clear.onChange(of: geo.size.width, initial: true) { _, w in onChange(w) }
    }
  }
}
```

- [ ] **Step 3: Wire the modifiers + clamp into `PaneLayout`** in `native/platform/darwin/swift/panes.swift`

In `rootView`, replace the sidebar `PaneHost` block (the `.ignoresSafeArea` + `.navigationSplitViewColumnWidth(min: state.sidebarMinW, ideal: state.sidebarIdealW, max: state.sidebarMaxW)` lines, ~95-97) with:

```swift
        PaneHost(view: sidebar)
          .ignoresSafeArea(.container, edges: state.bleedTop ? .top : [])
          .paneSidebarWidth(state)
          .background(WidthReader { w in state.noteSidebarWidth(w) })
```

In `detail`, replace the inspector `PaneHost` (line ~122) with:

```swift
        if let inspector {
          PaneHost(view: inspector)
            .ignoresSafeArea(.container, edges: state.bleedTop ? .top : [])
            .paneInspectorWidth(state)
            .background(WidthReader { w in state.noteInspectorWidth(w) })
        }
```

Replace the `inspectorPresentedBinding` setter (line ~149-150) to add the collapsible clamp:

```swift
  private var inspectorPresentedBinding: Binding<Bool> {
    Binding(
      get: { state.inspectorPresented },
      set: { newValue in
        // Non-collapsible: refuse user-driven dismissal (parity with the sidebar clamp).
        // Programmatic show/hide goes through PaneState directly and still works.
        if !state.inspectorCollapsible && !newValue { return }
        state.inspectorPresented = newValue
      }
    )
  }
```

(The `sidebarVisibilityBinding` clamp already reads `state.sidebarCollapsible`; promoting it to `@Published` in Step 1 is what makes it respect a runtime change. No edit needed there.)

- [ ] **Step 4: Replace `zapp_swift_panes_state_create` + add the 6 runtime setters** in `native/platform/darwin/swift/panes.swift`

Replace the existing `zapp_swift_panes_state_create` (lines ~158-174) with the widened version, and add the 6 setters after the existing `zapp_swift_panes_toggle_inspector`:

```swift
@_cdecl("zapp_swift_panes_state_create")
public func zapp_swift_panes_state_create(_ ctx: UnsafeMutableRawPointer?,
                                          _ cb: ZappSwiftStateCallback?,
                                          _ sidebarVisible: Bool,
                                          _ inspectorPresented: Bool,
                                          _ bleedTop: Bool,
                                          _ sidebarMinW: Double,
                                          _ sidebarWidth: Double,
                                          _ sidebarMaxW: Double,
                                          _ sidebarResizable: Bool,
                                          _ sidebarCollapsible: Bool,
                                          _ inspectorMinW: Double,
                                          _ inspectorWidth: Double,
                                          _ inspectorMaxW: Double,
                                          _ inspectorResizable: Bool,
                                          _ inspectorCollapsible: Bool) -> UnsafeMutableRawPointer? {
  let state = PaneState(ctx: ctx, cb: cb,
                        sidebarVisible: sidebarVisible, inspectorPresented: inspectorPresented,
                        bleedTop: bleedTop,
                        sidebarMinW: CGFloat(sidebarMinW), sidebarWidth: CGFloat(sidebarWidth),
                        sidebarMaxW: CGFloat(sidebarMaxW),
                        sidebarResizable: sidebarResizable, sidebarCollapsible: sidebarCollapsible,
                        inspectorMinW: CGFloat(inspectorMinW), inspectorWidth: CGFloat(inspectorWidth),
                        inspectorMaxW: CGFloat(inspectorMaxW),
                        inspectorResizable: inspectorResizable, inspectorCollapsible: inspectorCollapsible)
  return Unmanaged.passRetained(state).toOpaque()
}

// --- #660 runtime geometry setters (callers in sidebar.m / inspector.m run on main) ---

@_cdecl("zapp_swift_panes_set_sidebar_width")
public func zapp_swift_panes_set_sidebar_width(_ state: UnsafeMutableRawPointer, _ w: Int32) {
  let st = Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue()
  st.sidebarWidth = CGFloat(w)
  // Pin-and-release: force the snap this render, restore the drag range next tick.
  if st.sidebarResizable {
    st.sidebarPinned = true
    DispatchQueue.main.async { st.sidebarPinned = false }
  }
}

@_cdecl("zapp_swift_panes_set_sidebar_resizable")
public func zapp_swift_panes_set_sidebar_resizable(_ state: UnsafeMutableRawPointer, _ resizable: Bool) {
  Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue().sidebarResizable = resizable
}

@_cdecl("zapp_swift_panes_set_sidebar_collapsible")
public func zapp_swift_panes_set_sidebar_collapsible(_ state: UnsafeMutableRawPointer, _ collapsible: Bool) {
  Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue().sidebarCollapsible = collapsible
}

@_cdecl("zapp_swift_panes_set_inspector_width")
public func zapp_swift_panes_set_inspector_width(_ state: UnsafeMutableRawPointer, _ w: Int32) {
  let st = Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue()
  st.inspectorWidth = CGFloat(w)
  if st.inspectorResizable {
    st.inspectorPinned = true
    DispatchQueue.main.async { st.inspectorPinned = false }
  }
}

@_cdecl("zapp_swift_panes_set_inspector_resizable")
public func zapp_swift_panes_set_inspector_resizable(_ state: UnsafeMutableRawPointer, _ resizable: Bool) {
  Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue().inspectorResizable = resizable
}

@_cdecl("zapp_swift_panes_set_inspector_collapsible")
public func zapp_swift_panes_set_inspector_collapsible(_ state: UnsafeMutableRawPointer, _ collapsible: Bool) {
  Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue().inspectorCollapsible = collapsible
}
```

- [ ] **Step 5: Widen the `state_create` extern + key enum in `window.m`**

In `native/platform/darwin/window.m`, replace the key enum (line 85) with:

```c
enum { ZAPP_PANE_KEY_SIDEBAR_VISIBLE = 1, ZAPP_PANE_KEY_INSPECTOR_PRESENTED = 2,
       ZAPP_PANE_KEY_SIDEBAR_WIDTH = 3, ZAPP_PANE_KEY_INSPECTOR_WIDTH = 4 };
```

Replace the `zapp_swift_panes_state_create` extern (lines 87-91) with:

```c
extern void* zapp_swift_panes_state_create(void* ctx, ZappSwiftStateCallback cb,
                                           bool sidebarVisible, bool inspectorPresented,
                                           bool bleedTop,
                                           double sidebarMinW, double sidebarWidth, double sidebarMaxW,
                                           bool sidebarResizable, bool sidebarCollapsible,
                                           double inspectorMinW, double inspectorWidth, double inspectorMaxW,
                                           bool inspectorResizable, bool inspectorCollapsible);
```

- [ ] **Step 6: Update the `state_create` call** in `native/platform/darwin/window.m` (lines ~1058-1061) to:

```c
                swiftPaneState = zapp_swift_panes_state_create((__bridge void*)window,
                    zapp_swiftui_pane_changed, sidebarVisible, inspectorPresented, paneBleedTop,
                    (double)wopts_sidebar_min_width(opts), (double)wopts_sidebar_width(opts),
                    (double)wopts_sidebar_max_width(opts),
                    wopts_sidebar_can_resize(opts), wopts_sidebar_collapsible(opts),
                    (double)wopts_inspector_min_width(opts), (double)wopts_inspector_width(opts),
                    (double)wopts_inspector_max_width(opts),
                    wopts_inspector_can_resize(opts), wopts_inspector_collapsible(opts));
```

- [ ] **Step 7: Build (macOS Nim) and confirm success**

Run: `cd /Users/zach/code/zapp && bun run build --app kitchen-sink 2>&1 | tail -20`
Expected: the LAST line is `[zapp] build complete: …`. (Vite's `✓ built` alone is NOT success.) If the kitchen-sink build command differs, use the project's standard Nim macOS build for the kitchen-sink app; confirm a fresh binary mtime. swiftc compiles `panes.swift` as part of this build — a Swift type error will fail here.

- [ ] **Step 8: Commit**

```bash
git add native/platform/darwin/swift/panes.swift native/platform/darwin/window.m
git commit -m "feat(darwin): #660 T1 — declarative PaneState core + widened state_create

PaneState width/resizable/collapsible are now @Published for both panes;
column modifiers use min==max==width to lock, pin-and-release forces a
snap while resizable, WidthReader tracks rendered width. state_create
carries full create-time geometry (fixes SwiftUI create-time resizable/
collapsible never being applied). Runtime setters added; sidebar.m/
inspector.m rewired in T2/T3.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Rewire `sidebar.m` to the declarative setters + reverse width events

Routes the SwiftUI branch of the three sidebar control ops to the new `@Published` setters (no more reach-through), adds the reverse width emitter, removes the now-dead `zapp_sidebar_bind_swiftui`, and wires the `SIDEBAR_WIDTH` dispatcher arm in `window.m`.

**Files:**
- Modify: `native/platform/darwin/sidebar.m` (extern block, 3 control ops, new note fn, remove bind helper)
- Modify: `native/platform/darwin/window.m` (extern + dispatcher arm for `ZAPP_PANE_KEY_SIDEBAR_WIDTH`)

- [ ] **Step 1: Add the new setter externs** in `native/platform/darwin/sidebar.m`, inside the existing `#ifdef ZAPP_HAS_SWIFTUI` extern block (lines ~24-27):

```c
#ifdef ZAPP_HAS_SWIFTUI
extern void zapp_swift_panes_set_sidebar_visible(void* state, bool visible);
extern void zapp_swift_panes_toggle_sidebar(void* state);
extern void zapp_swift_panes_set_sidebar_width(void* state, int32_t w);
extern void zapp_swift_panes_set_sidebar_resizable(void* state, bool resizable);
extern void zapp_swift_panes_set_sidebar_collapsible(void* state, bool collapsible);
#endif
```

- [ ] **Step 2: Rewire `darwin_sidebar_set_width`** in `native/platform/darwin/sidebar.m` (replace the body lines ~232-248):

```c
void darwin_sidebar_set_width(int32_t window_id, int32_t width) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
#ifdef ZAPP_HAS_SWIFTUI
        if (c.swiftPaneState) { zapp_swift_panes_set_sidebar_width(c.swiftPaneState, width); return; }
#endif
        if (!c.sidebarItem || !c.splitVC) return;
        CGFloat w = (CGFloat)width;
        CGFloat minT = c.sidebarItem.minimumThickness;
        CGFloat maxT = c.sidebarItem.maximumThickness;
        if (minT > 0 && w < minT) w = minT;
        if (maxT > 0 && w > maxT) w = maxT;
        [c.splitVC.splitView setPosition:w ofDividerAtIndex:0];
    });
}
```

- [ ] **Step 3: Rewire `darwin_sidebar_set_collapsible` and `darwin_sidebar_set_resizable`** in `native/platform/darwin/sidebar.m` (replace bodies lines ~253-288):

```c
void darwin_sidebar_set_collapsible(int32_t window_id, bool can_collapse) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
#ifdef ZAPP_HAS_SWIFTUI
        if (c.swiftPaneState) { zapp_swift_panes_set_sidebar_collapsible(c.swiftPaneState, can_collapse); return; }
#endif
        if (!c.sidebarItem) return;
        c.sidebarItem.canCollapse = can_collapse ? YES : NO;
    });
}

void darwin_sidebar_set_resizable(int32_t window_id, bool resizable) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
#ifdef ZAPP_HAS_SWIFTUI
        if (c.swiftPaneState) { zapp_swift_panes_set_sidebar_resizable(c.swiftPaneState, resizable); return; }
#endif
        if (!c.sidebarItem) return;
        if (resizable) {
            c.sidebarItem.minimumThickness = c.cfgMinThickness;
            c.sidebarItem.maximumThickness = c.cfgMaxThickness;
        } else {
            CGFloat w = (CGFloat)zapp_sidebar_current_width(c);
            if (w <= 0) w = c.sidebarItem.minimumThickness;
            c.sidebarItem.minimumThickness = w;
            c.sidebarItem.maximumThickness = w;
        }
    });
}
```

- [ ] **Step 4: Add the reverse width emitter** in `native/platform/darwin/sidebar.m`, immediately after `zapp_sidebar_note_swiftui_visibility` (after line ~321):

```c
// Reverse path: SwiftUI sidebar rendered width changed (WidthReader). Dedup against
// lastWidth, then emit the same "sidebar-resized" event the AppKit splitViewDidResize
// path emits. Called by window.m's reverse dispatcher (always on the main thread).
void zapp_sidebar_note_swiftui_width(void* window_ptr, int width) {
    if (!window_ptr || !zapp_sidebars || width <= 0) return;
    ZappSidebarController* c = zapp_sidebars[[NSValue valueWithPointer:window_ptr]];
    if (!c) return;
    if (width == c.lastWidth) return;  // dedup
    c.lastWidth = width;
    NSString* json = [NSString stringWithFormat:@"{\"width\":%d}", width];
    zapp_sidebar_emit(c, "sidebar-resized", json);
}
```

- [ ] **Step 5: Remove the now-dead reach-through** in `native/platform/darwin/sidebar.m`

Delete the `zapp_sidebar_bind_swiftui` function (lines ~165-179) and the three externs it depended on that are no longer used (lines ~16-19: `zapp_find_split_vc`, `zapp_find_split_view`, `zapp_dump_view_tree`). After this, no symbol in `sidebar.m` references the `window.m` split-finder helpers. (The helper DEFINITIONS stay in `window.m` — they may serve `toolbar.m`.)

Note: `cfgMinThickness`/`cfgMaxThickness` are still used by the AppKit `set_resizable` path — keep those properties.

- [ ] **Step 6: Wire the `SIDEBAR_WIDTH` dispatcher arm** in `native/platform/darwin/window.m`

Add the extern alongside the existing reverse-emit externs (after line ~108):

```c
extern void zapp_sidebar_note_swiftui_width(void* window_ptr, int width);
```

Add the arm to `zapp_swiftui_pane_changed` (after the `ZAPP_PANE_KEY_SIDEBAR_VISIBLE` case, ~line 126):

```c
        case ZAPP_PANE_KEY_SIDEBAR_WIDTH:
            zapp_sidebar_note_swiftui_width(ctx, (int)value);
            break;
```

- [ ] **Step 7: Build (macOS Nim) and confirm success**

Run: `cd /Users/zach/code/zapp && bun run build --app kitchen-sink 2>&1 | tail -20`
Expected: LAST line `[zapp] build complete: …`. A link error here means a stale reference to the removed `bind_swiftui`/finder helpers — fix the offending reference.

- [ ] **Step 8: Commit**

```bash
git add native/platform/darwin/sidebar.m native/platform/darwin/window.m
git commit -m "feat(darwin): #660 T2 — sidebar runtime control via @Published (drop reach-through)

set_width/resizable/collapsible route to the PaneState setters on the
SwiftUI path; reverse width events emit sidebar-resized (parity with the
AppKit splitViewDidResize path). Removed the dead zapp_sidebar_bind_swiftui
reach-through. AppKit path unchanged.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: Rewire `inspector.m` to the declarative setters + reverse width events

Mirror of Task 2 for the inspector. Inspector width becomes fully declarative — the thickness re-pin in `darwin_inspector_set_width` is replaced by the `@Published` setter.

**Files:**
- Modify: `native/platform/darwin/inspector.m` (extern block, 3 control ops, new note fn, remove bind helper)
- Modify: `native/platform/darwin/window.m` (extern + dispatcher arm for `ZAPP_PANE_KEY_INSPECTOR_WIDTH`)

- [ ] **Step 1: Add the new setter externs** in `native/platform/darwin/inspector.m`, inside the existing `#ifdef ZAPP_HAS_SWIFTUI` block (lines ~19-22):

```c
#ifdef ZAPP_HAS_SWIFTUI
extern void zapp_swift_panes_set_inspector_presented(void* state, bool presented);
extern void zapp_swift_panes_toggle_inspector(void* state);
extern void zapp_swift_panes_set_inspector_width(void* state, int32_t w);
extern void zapp_swift_panes_set_inspector_resizable(void* state, bool resizable);
extern void zapp_swift_panes_set_inspector_collapsible(void* state, bool collapsible);
#endif
```

- [ ] **Step 2: Rewire `darwin_inspector_set_width`** in `native/platform/darwin/inspector.m` (replace body lines ~201-230):

```c
void darwin_inspector_set_width(int32_t window_id, int32_t width) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
#ifdef ZAPP_HAS_SWIFTUI
        if (c.swiftPaneState) { zapp_swift_panes_set_inspector_width(c.swiftPaneState, width); return; }
#endif
        if (!c.inspectorItem || !c.splitVC) return;
        CGFloat w = (CGFloat)width;
        if (w < 50) w = 50;   // sanity floor
        CGFloat minT = c.inspectorItem.minimumThickness;
        CGFloat maxT = c.inspectorItem.maximumThickness;
        if (minT > 0 && w < minT) w = minT;
        if (maxT > 0 && w > maxT) w = maxT;
        // Trailing pane: divider x measured from the left = (total - inspector width).
        CGFloat total = c.splitVC.splitView.bounds.size.width;
        [c.splitVC.splitView setPosition:(total - w) ofDividerAtIndex:c.inspectorDividerIndex];
    });
}
```

- [ ] **Step 3: Rewire `darwin_inspector_set_collapsible` and `darwin_inspector_set_resizable`** in `native/platform/darwin/inspector.m` (replace bodies lines ~234-269):

```c
void darwin_inspector_set_collapsible(int32_t window_id, bool can_collapse) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
#ifdef ZAPP_HAS_SWIFTUI
        if (c.swiftPaneState) { zapp_swift_panes_set_inspector_collapsible(c.swiftPaneState, can_collapse); return; }
#endif
        if (!c.inspectorItem) return;
        c.inspectorItem.canCollapse = can_collapse ? YES : NO;
    });
}

void darwin_inspector_set_resizable(int32_t window_id, bool resizable) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
#ifdef ZAPP_HAS_SWIFTUI
        if (c.swiftPaneState) { zapp_swift_panes_set_inspector_resizable(c.swiftPaneState, resizable); return; }
#endif
        if (!c.inspectorItem) return;
        if (resizable) {
            c.inspectorItem.minimumThickness = c.cfgMinThickness;
            c.inspectorItem.maximumThickness = c.cfgMaxThickness;
        } else {
            CGFloat w = (CGFloat)zapp_inspector_current_width(c);
            if (w <= 0) w = c.inspectorItem.minimumThickness;
            c.inspectorItem.minimumThickness = w;
            c.inspectorItem.maximumThickness = w;
        }
    });
}
```

- [ ] **Step 4: Add the reverse width emitter** in `native/platform/darwin/inspector.m`, immediately after `zapp_inspector_note_swiftui_visibility` (after line ~310):

```c
// Reverse path: SwiftUI inspector rendered width changed (WidthReader). Dedup against
// lastWidth, then emit "inspector-resized" (parity with the AppKit splitViewDidResize
// path). Called by window.m's reverse dispatcher (always on the main thread).
void zapp_inspector_note_swiftui_width(void* window_ptr, int width) {
    if (!window_ptr || !zapp_inspectors || width <= 0) return;
    ZappInspectorController* c = zapp_inspectors[[NSValue valueWithPointer:window_ptr]];
    if (!c) return;
    if (width == c.lastWidth) return;  // dedup
    c.lastWidth = width;
    NSString* json = [NSString stringWithFormat:@"{\"width\":%d}", width];
    zapp_inspector_emit(c, "inspector-resized", json);
}
```

- [ ] **Step 5: Remove the now-dead reach-through** in `native/platform/darwin/inspector.m`

Delete the `zapp_inspector_bind_swiftui` function (lines ~160-199) and the two externs it used that are no longer referenced (lines ~10-11: `zapp_find_split_view`, `zapp_webview_for_slot`). Keep `cfgMinThickness`/`cfgMaxThickness` (still used by the AppKit `set_resizable` path) and `inspectorDividerIndex` (used by the AppKit `set_width` path + `zapp_inspector_divider_index`).

- [ ] **Step 6: Wire the `INSPECTOR_WIDTH` dispatcher arm** in `native/platform/darwin/window.m`

Add the extern alongside the others (after the sidebar one from T2, ~line 109):

```c
extern void zapp_inspector_note_swiftui_width(void* window_ptr, int width);
```

Add the arm to `zapp_swiftui_pane_changed` (after the `ZAPP_PANE_KEY_INSPECTOR_PRESENTED` case, ~line 129):

```c
        case ZAPP_PANE_KEY_INSPECTOR_WIDTH:
            zapp_inspector_note_swiftui_width(ctx, (int)value);
            break;
```

- [ ] **Step 7: Build (macOS Nim) and confirm success**

Run: `cd /Users/zach/code/zapp && bun run build --app kitchen-sink 2>&1 | tail -20`
Expected: LAST line `[zapp] build complete: …`.

- [ ] **Step 8: Commit**

```bash
git add native/platform/darwin/inspector.m native/platform/darwin/window.m
git commit -m "feat(darwin): #660 T3 — inspector runtime control via @Published (drop reach-through)

Inspector width is now fully declarative (.inspectorColumnWidth driven by
PaneState); set_width/resizable/collapsible route to the setters; reverse
width events emit inspector-resized. Removed the dead bind_swiftui +
thickness re-pin. AppKit path unchanged.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: Docs + full build matrix + human visual smoke gate

Documents the new behavior and the `collapsible` semantics, runs the full build matrix, and pauses for the human visual smoke gate (the real verification for this cycle).

**Files:**
- Modify: `docs/native-ui-strategy.md` (parity matrix entry + collapsible semantics note)
- (If the api-reference documents pane runtime control behavior, update it; otherwise skip — the runtime TS API is unchanged.)

- [ ] **Step 1: Update `docs/native-ui-strategy.md`**

Find the SwiftUI accessories / pane-control section. Record that runtime sidebar/inspector width, resize-lock, and collapsible are now **declarative + durable** on the SwiftUI path (driven by `@Published` PaneState → SwiftUI column modifiers), giving the same end result as the AppKit path. Add a short "Pane collapsible semantics" note:

> `collapsible: false` gates user/system collapse affordances only — the divider snap and SwiftUI's native sidebar toggle. Programmatic `collapse()`/`expand()`/`toggle()` and an app's own toolbar toggle button still work, on both the SwiftUI and AppKit paths (AppKit's `setCollapsed:` ignores `canCollapse`).

- [ ] **Step 2: Full build matrix**

Run each and confirm:
- Nim macOS (swiftui ON): `bun run build --app kitchen-sink 2>&1 | tail -5` → LAST line `[zapp] build complete: …`, fresh binary mtime.
- AppKit (swiftui:false) unchanged: temporarily set `native: { swiftui: false }` in `kitchen-sink/zapp.config.ts`, rebuild, confirm `[zapp] build complete: …`, then **revert the toggle** (and never `git add` that file).
- iOS-sim build: the project's iOS-simulator build for kitchen-sink → confirm it links (this is the gate for the `.m`-only symbols `note_swiftui_width`, since the `#281` lint only covers `.zc`-referenced symbols).
- `bun test cli/src` → green (iOS parity lint).

- [ ] **Step 3: Commit docs**

```bash
git add docs/native-ui-strategy.md
git commit -m "docs(native-ui): #660 — declarative SwiftUI pane control + collapsible semantics

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 4: HUMAN VISUAL SMOKE GATE — pause for the user**

Ask the user to run `bun run dev --app kitchen-sink` and verify, on the Sidebar AND Inspector sections, with `native.swiftui` ON (default) and again with `swiftui:false`, that the END RESULT is identical for:
1. **setWidth(N):** the pane snaps to N and STAYS draggable afterward (resizable case).
2. **setResizable(false):** width locks; collapse→re-expand keeps it locked (no re-enable).
3. **setCollapsible(false):** the native sidebar toggle + divider can't collapse it; the app's own toggle()/collapse() still works.
4. **Events:** drag-resize fires `*-resized`; collapse/expand fires `*-collapsed`/`*-expanded`; the toggle-button UI stays synced with the real pane state.

Do NOT mark the task complete until the user confirms the gate passes. If a behavior diverges, capture the exact symptom and diagnose before any fix.

---

## Self-Review

**Spec coverage:** PaneState @Published fields + modifiers (T1); pin-and-release setWidth (T1 setters); collapsible binding-clamps incl. inspector (T1 Step 3); widened state_create + create-time geometry (T1 Steps 4-6); reverse width events via WidthReader + note fns (T1 Step 2 / T2 Step 4 / T3 Step 4); control-op rewiring (T2/T3); dispatcher arms + keys (T1 Step 5, T2 Step 6, T3 Step 6); dead reach-through removal (T2/T3 Step 5); docs + parity matrix + collapsible semantics (T4); build matrix + human smoke (T4). All spec sections map to a task.

**Placeholder scan:** none — every code step shows complete code; build/commit commands are concrete.

**Type/name consistency:** Pane keys 1-4 identical in `panes.swift` (`kPaneKey*`) and `window.m` (`ZAPP_PANE_KEY_*`). Setter names identical across `panes.swift` `@_cdecl`, `sidebar.m`/`inspector.m` externs, and call sites (`zapp_swift_panes_set_{sidebar,inspector}_{width,resizable,collapsible}`). `state_create` signature identical in the `panes.swift` definition and the `window.m` extern + call (15 params: ctx, cb, 3 bools, sidebar 3 doubles + 2 bools, inspector 3 doubles + 2 bools). Reverse-emit fns `zapp_{sidebar,inspector}_note_swiftui_width(void*, int)` consistent between definition (T2/T3 Step 4) and `window.m` extern/call (T2/T3 Step 6). `noteSidebarWidth`/`noteInspectorWidth` consistent between PaneState (T1 Step 1) and WidthReader call sites (T1 Step 3).
