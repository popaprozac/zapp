# SwiftUI accessories Sub-cycle 2a — runtime pane control bridge (macOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the SwiftUI pane path (macOS 14+, accessory'd window, not opted out), make Zapp's existing runtime sidebar/inspector **visibility** APIs drive the SwiftUI panes, and emit the same visibility events the AppKit path does — closing the Sub-cycle-1 dead-inspector-toggle limitation (the inspector renders + toggles).

**Architecture:** A Swift `final class PaneState: ObservableObject` (in `panes.swift`) holds the pane visibility as `@Published` bools and crosses the ObjC↔Swift boundary as a retained opaque handle. `PaneLayout` observes it and derives the `NavigationSplitView` `columnVisibility` + `.inspector(isPresented:)` bindings. ObjC drives it forward via scalar `@_cdecl` setters/togglers; SwiftUI changes flow back via a change-driven `@convention(c)` callback (`ZappSwiftStateCallback(ctx, key, value)`) → a `switch` dispatcher in `window.m` → the existing `zapp_pane_emit`. The existing `darwin_sidebar_*`/`darwin_inspector_*` ops branch on whether the resolved controller is SwiftUI-backed. Width/lock/presentation are deferred (2c); toolbar is 2b.

**Tech Stack:** Swift (SwiftUI/WebKit, the existing `swiftc` step globs `native/platform/darwin/swift/*.swift`), Objective-C (`window.m`, `sidebar.m`, `inspector.m`), Nim build (unchanged). macOS 14 floor.

**Branch:** `feat/nim-native` (do not merge to main). **Commit trailer (every commit):**
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

**Spec:** `docs/superpowers/specs/2026-06-21-swiftui-accessories-subcycle2a-runtime-control-macos-design.md`
**References:**
- `native/platform/darwin/swift/panes.swift` — current `PaneHost`/`PaneLayout`/`zapp_swift_panes_create` (the file being refactored).
- `native/platform/darwin/sidebar.m` + `inspector.m` — the AppKit controllers, registry (`zapp_sidebar_for_slot`), control ops (`darwin_sidebar_*`), emit helpers (`zapp_pane_emit`, `zapp_sidebar_emit`, `zapp_sidebar_sync_collapse`), register/unregister.
- `native/platform/darwin/window.m` — the SwiftUI fork (`useSwiftUIPanes` at ~797; branch body ~810-957), the extern block (~81-83), the `ZappWindowDelegate` props (~322-324), the delegate assignment (~1208-1216), and the teardown (~1329-1343).

---

## Verification model (read first)

**No unit tests for native UI** — verification is **build-succeeds + human visual smoke** (the repo's established gate). The build-complete signal is the **last line `[zapp] build complete: …`** (Vite's `✓ built` is NOT success).

**Build command (from repo root):** `cd kitchen-sink && bun run build 2>&1 | tail -3 ; cd ..` → expect last line `[zapp] build complete: …`. The kitchen-sink main window declares sidebar + inspector, so it takes the SwiftUI path on macOS 14+ (host is macOS 26 — fine).

**Smoke controls in the kitchen-sink (already present):**
- Sidebar section (`kitchen-sink/src/sections/sidebar.ts`): a button → `win.sidebar?.toggle()`.
- Inspector section (`kitchen-sink/src/sections/inspector.ts`): a button → `win.inspector?.toggle()`.
- Shell (`kitchen-sink/src/shell/main-pane.ts`): hamburger → `Window.current().sidebar?.toggle()`; an inspector button → `Window.current().inspector?.toggle()`.

**Critical invariant (unchanged from Sub-cycle 1):** a `WKWebView` is created into its final container and **never re-parented**. This sub-cycle does not touch webview creation/containers — only the visibility state mechanism. Do not re-order or duplicate the `darwin_webview_create_ext` / `zapp_register_webview` calls.

**Risk-isolating order:** Task 1 swaps `PaneLayout`'s visibility source from `@State` to the external `PaneState` and wires the (stub) reverse dispatcher — a pure refactor gated by "renders identically." Task 2 wires sidebar control + reverse events. Task 3 wires inspector control + reverse events (the render/toggle payoff). Task 4 is the gate matrix + docs + review.

---

## File Structure

**Modify:**
- `native/platform/darwin/swift/panes.swift` — add `PaneState` + the `ZappSwiftStateCallback` typealias; refactor `PaneLayout` to `@ObservedObject` + derived bindings; add the state `@_cdecl`s; widen `zapp_swift_panes_create`'s signature (drop `showInspector`, prepend `state`).
- `native/platform/darwin/window.m` — expand the `#ifdef ZAPP_HAS_SWIFTUI` extern block (typedef + key enum + new externs); add the file-static reverse dispatcher; create the `PaneState`, pass it to `zapp_swift_panes_create`, register the SwiftUI controllers; own the `PaneState` on the delegate + release it once at teardown.
- `native/platform/darwin/sidebar.m` — `swiftPaneState` property; `zapp_sidebar_register_swiftui`; branch the control ops; `zapp_sidebar_note_swiftui_visibility`; SwiftUI-aware `unregister`.
- `native/platform/darwin/inspector.m` — the exact inspector twin of the `sidebar.m` changes.
- `docs/native-ui-strategy.md` — mark Sub-cycle 2a shipped; update the known-limitations list.

---

## Task 1 (RISK GATE): `PaneState` foundation + window.m wiring

Swap `PaneLayout`'s visibility from `@State` to an external `PaneState`, and wire window.m to create/own it. No runtime control or reverse events yet (the dispatcher is a stub). Gate: the kitchen-sink window renders **identically** to today via the new state-driven layout.

**Files:**
- Modify: `native/platform/darwin/swift/panes.swift`
- Modify: `native/platform/darwin/window.m`

- [ ] **Step 1: Rewrite `panes.swift` with `PaneState` + derived bindings + new `@_cdecl`s**

Replace the **entire** contents of `native/platform/darwin/swift/panes.swift` with:

```swift
import SwiftUI
import WebKit

// Wraps a pre-built NSView (a container that ALREADY holds a Zapp WKWebView)
// inside SwiftUI WITHOUT re-parenting the webview — we only wrap the container.
// The strong `let view` keeps the container (and its webview) alive under ARC.
struct PaneHost: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

// Reverse channel: a SwiftUI state change -> native. Scalar, main-thread,
// change-driven. `key` selects the field (see ZAPP_PANE_KEY_* in window.m);
// `value` is the new scalar (0/1 for the visibility bools). Deliberately
// generic — this is the seam the future bring-your-own-SwiftUI bridge reuses (#622).
public typealias ZappSwiftStateCallback =
  @convention(c) (UnsafeMutableRawPointer?, Int32, Int64) -> Void

// Keys must match the enum in window.m.
private let kPaneKeySidebarVisible: Int32 = 1
private let kPaneKeyInspectorPresented: Int32 = 2

// Shared, observable pane visibility crossing the ObjC<->Swift boundary. ObjC
// drives it via the scalar setters/togglers below; SwiftUI drives it via the
// derived bindings; every change fires `cb` (change-driven, never polled).
// `didSet` is NOT called during init, so creating a PaneState never emits.
final class PaneState: ObservableObject {
  @Published var sidebarVisible: Bool {
    didSet { cb?(ctx, kPaneKeySidebarVisible, sidebarVisible ? 1 : 0) }
  }
  @Published var inspectorPresented: Bool {
    didSet { cb?(ctx, kPaneKeyInspectorPresented, inspectorPresented ? 1 : 0) }
  }
  let ctx: UnsafeMutableRawPointer?
  let cb: ZappSwiftStateCallback?

  init(ctx: UnsafeMutableRawPointer?, cb: ZappSwiftStateCallback?,
       sidebarVisible: Bool, inspectorPresented: Bool) {
    self.ctx = ctx; self.cb = cb
    self.sidebarVisible = sidebarVisible
    self.inspectorPresented = inspectorPresented
  }
}

@available(macOS 14.0, *)
struct PaneLayout: View {
  let content: NSView
  let sidebar: NSView?
  let inspector: NSView?
  @ObservedObject var state: PaneState

  var body: some View {
    if let sidebar {
      NavigationSplitView(columnVisibility: sidebarVisibilityBinding) {
        PaneHost(view: sidebar).ignoresSafeArea()
      } detail: {
        detail
      }
      // Tiling vs overlay is Sub-cycle 2c; keep the Sub-cycle-1 style.
      .navigationSplitViewStyle(.balanced)
    } else {
      detail
    }
  }

  @ViewBuilder private var detail: some View {
    PaneHost(view: content)
      .ignoresSafeArea()
      .inspector(isPresented: inspectorPresentedBinding) {
        if let inspector { PaneHost(view: inspector).ignoresSafeArea() }
      }
  }

  // Map the visibility bool <-> NavigationSplitViewVisibility. `.all` shows the
  // sidebar column; `.detailOnly` hides it.
  private var sidebarVisibilityBinding: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: { state.sidebarVisible ? .all : .detailOnly },
      set: { state.sidebarVisible = ($0 != .detailOnly) }
    )
  }
  private var inspectorPresentedBinding: Binding<Bool> {
    Binding(
      get: { state.inspectorPresented },
      set: { state.inspectorPresented = $0 }
    )
  }
}

// --- @_cdecl entries ---------------------------------------------------------

// Create the shared state (+1 retained; ObjC owns it, releases via _state_release).
@_cdecl("zapp_swift_panes_state_create")
public func zapp_swift_panes_state_create(_ ctx: UnsafeMutableRawPointer?,
                                          _ cb: ZappSwiftStateCallback?,
                                          _ sidebarVisible: Bool,
                                          _ inspectorPresented: Bool) -> UnsafeMutableRawPointer? {
  let state = PaneState(ctx: ctx, cb: cb,
                        sidebarVisible: sidebarVisible, inspectorPresented: inspectorPresented)
  return Unmanaged.passRetained(state).toOpaque()
}

@_cdecl("zapp_swift_panes_state_release")
public func zapp_swift_panes_state_release(_ state: UnsafeMutableRawPointer) {
  Unmanaged<PaneState>.fromOpaque(state).release()
}

@_cdecl("zapp_swift_panes_set_sidebar_visible")
public func zapp_swift_panes_set_sidebar_visible(_ state: UnsafeMutableRawPointer, _ visible: Bool) {
  Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue().sidebarVisible = visible
}

@_cdecl("zapp_swift_panes_set_inspector_presented")
public func zapp_swift_panes_set_inspector_presented(_ state: UnsafeMutableRawPointer, _ presented: Bool) {
  Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue().inspectorPresented = presented
}

@_cdecl("zapp_swift_panes_toggle_sidebar")
public func zapp_swift_panes_toggle_sidebar(_ state: UnsafeMutableRawPointer) {
  Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue().sidebarVisible.toggle()
}

@_cdecl("zapp_swift_panes_toggle_inspector")
public func zapp_swift_panes_toggle_inspector(_ state: UnsafeMutableRawPointer) {
  Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue().inspectorPresented.toggle()
}

// Build the hosting view. `state` carries initial visibility; the old
// showInspector Bool param is gone. Returns a +1-retained NSHostingView;
// ObjC consumes it with __bridge_transfer.
@_cdecl("zapp_swift_panes_create")
public func zapp_swift_panes_create(_ state: UnsafeMutableRawPointer,
                                    _ content: UnsafeMutableRawPointer,
                                    _ sidebar: UnsafeMutableRawPointer?,
                                    _ inspector: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
  guard #available(macOS 14.0, *) else { return nil }
  let st = Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue()
  let c = Unmanaged<NSView>.fromOpaque(content).takeUnretainedValue()
  let s = sidebar.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
  let i = inspector.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
  let host = NSHostingView(rootView: PaneLayout(content: c, sidebar: s, inspector: i, state: st))
  return Unmanaged.passRetained(host).toOpaque()
}
```

- [ ] **Step 2: Expand the `window.m` extern block + add the stub dispatcher**

In `native/platform/darwin/window.m`, replace the existing block (currently ~81-83):

```objc
#ifdef ZAPP_HAS_SWIFTUI
extern void* zapp_swift_panes_create(void* content, void* sidebar, void* inspector, bool showInspector);
#endif
```

with:

```objc
#ifdef ZAPP_HAS_SWIFTUI
// Reverse state-change channel from SwiftUI (panes.swift). Scalar, main-thread,
// change-driven. Keys match panes.swift; value is the new scalar (0/1 here).
typedef void (*ZappSwiftStateCallback)(void* ctx, int32_t key, int64_t value);
enum { ZAPP_PANE_KEY_SIDEBAR_VISIBLE = 1, ZAPP_PANE_KEY_INSPECTOR_PRESENTED = 2 };

extern void* zapp_swift_panes_state_create(void* ctx, ZappSwiftStateCallback cb,
                                           bool sidebarVisible, bool inspectorPresented);
extern void zapp_swift_panes_state_release(void* state);
extern void zapp_swift_panes_set_sidebar_visible(void* state, bool visible);
extern void zapp_swift_panes_set_inspector_presented(void* state, bool presented);
extern void zapp_swift_panes_toggle_sidebar(void* state);
extern void zapp_swift_panes_toggle_inspector(void* state);
extern void* zapp_swift_panes_create(void* state, void* content, void* sidebar, void* inspector);

// Reverse-emit entries (defined in sidebar.m / inspector.m — wired in Tasks 2/3).
extern void zapp_sidebar_note_swiftui_visibility(void* window_ptr, bool collapsed);
extern void zapp_inspector_note_swiftui_visibility(void* window_ptr, bool collapsed);
// SwiftUI controller register variants (defined in sidebar.m / inspector.m — Tasks 2/3).
extern void zapp_sidebar_register_swiftui(void* window_ptr, void* paneState,
                                          int32_t host_id, int32_t sidebar_slot_id,
                                          bool initial_collapsed);
extern void zapp_inspector_register_swiftui(void* window_ptr, void* paneState,
                                            int32_t host_id, int32_t inspector_slot_id,
                                            bool initial_collapsed);

// File-static reverse dispatcher: PaneState's didSet fires this with the changed
// key + new value (1=visible/0=collapsed). ctx is the host NSWindow*. The switch
// arms are added in Tasks 2 (sidebar) and 3 (inspector); a stub today emits nothing.
static void zapp_swiftui_pane_changed(void* ctx, int32_t key, int64_t value) {
    (void)ctx; (void)key; (void)value;
    // Task 2 adds: case ZAPP_PANE_KEY_SIDEBAR_VISIBLE -> zapp_sidebar_note_swiftui_visibility(ctx, value == 0);
    // Task 3 adds: case ZAPP_PANE_KEY_INSPECTOR_PRESENTED -> zapp_inspector_note_swiftui_visibility(ctx, value == 0);
}
#endif
```

(The `note`/`register_swiftui` externs are declared now but not *called* until Tasks 2/3, so the link succeeds — an undefined symbol only matters when referenced.)

- [ ] **Step 3: Declare a `swiftPaneState` local before the SwiftUI branch**

Find the pane webview-ref locals (currently ~772-779):

```objc
        WKWebView* mainWebviewRef = nil;
        ...
        WKWebView* inspectorWebviewRef = nil;
```

Immediately after `inspectorWebviewRef`, add:

```objc
        void* swiftPaneState = NULL;  // SwiftUI PaneState handle (owned by the delegate; released once at teardown)
```

- [ ] **Step 4: Create the `PaneState` and pass it to `zapp_swift_panes_create`**

In the SwiftUI branch, replace the current block (currently ~891-904):

```objc
                // Initial inspector visibility — shown unless created collapsed.
                bool showInspector = useInspector && !wopts_inspector_collapsed(opts);

                // Install the SwiftUI host ...
                NSView* paneHost = (__bridge_transfer NSView*)zapp_swift_panes_create(
                    (__bridge void*)mainContainer, (__bridge void*)sidebarContainer,
                    (__bridge void*)inspectorContainer, showInspector);
                paneHost.frame = [window contentView].frame;
                window.contentView = paneHost;
                [paneHost layoutSubtreeIfNeeded];
```

with:

```objc
                // Initial pane visibility for the shared PaneState: sidebar shown
                // when present; inspector shown unless created collapsed.
                bool sidebarVisible = useSidebar;
                bool inspectorPresented = useInspector && !wopts_inspector_collapsed(opts);

                // Shared, observable pane state. ctx = host NSWindow* (the registry
                // key the reverse dispatcher resolves controllers by); cb = the
                // file-static reverse dispatcher. The delegate owns this handle and
                // releases it once at teardown.
                swiftPaneState = zapp_swift_panes_state_create((__bridge void*)window,
                    zapp_swiftui_pane_changed, sidebarVisible, inspectorPresented);

                // Install the SwiftUI host (wrapping the content container + optional
                // sidebar + optional inspector) as the window's contentView FIRST, so
                // the containers are in the window before the webviews are created into
                // them (mirrors the AppKit ordering where splitVC is root before _ext).
                NSView* paneHost = (__bridge_transfer NSView*)zapp_swift_panes_create(
                    swiftPaneState, (__bridge void*)mainContainer,
                    (__bridge void*)sidebarContainer, (__bridge void*)inspectorContainer);
                paneHost.frame = [window contentView].frame;
                window.contentView = paneHost;
                [paneHost layoutSubtreeIfNeeded];
```

(Everything after this — the `darwin_webview_create_ext` calls, `zapp_register_webview`, `zapp_set_sidebar_slot`/`zapp_set_inspector_slot` — is unchanged.)

- [ ] **Step 5: Add the delegate property + store the handle + release at teardown**

(a) In the `ZappWindowDelegate` `@interface` (near the webview props, currently ~322-324: `mainWebview`/`sidebarWebview`/`inspectorWebview`), add:

```objc
@property (nonatomic, assign) void* swiftPaneState;  // owning ref to the SwiftUI PaneState (NULL on AppKit path)
```

(b) In the delegate-assignment block (near `delegate.inspectorWebview = inspectorWebviewRef;`, currently ~1216), add:

```objc
        delegate.swiftPaneState = swiftPaneState;       // NULL unless the SwiftUI path ran
```

(c) In the teardown block, after the inspector unregister (currently ~1342, just before the closing `}` of the `if ([delegate isKindOfClass:[ZappWindowDelegate class]])`), add:

```objc
#ifdef ZAPP_HAS_SWIFTUI
        if (delegate.swiftPaneState) {
            zapp_swift_panes_state_release(delegate.swiftPaneState);
            delegate.swiftPaneState = NULL;
        }
#endif
```

- [ ] **Step 6: Build (macOS)**

Run: `cd kitchen-sink && bun run build 2>&1 | tail -3 ; cd ..`
Expected last line: `[zapp] build complete: …`. Then confirm symbols linked:
```bash
nm kitchen-sink/bin/kitchen-sink | grep -cE 'zapp_swift_panes_(state_create|create|toggle_sidebar)'
```
Expected: `3`.

- [ ] **Step 7: GATE — human visual smoke (macOS 14), PAUSE for the user**

Run: `cd kitchen-sink && ./bin/kitchen-sink & cd ..` (the kitchen-sink window is accessory'd → SwiftUI path). Ask the user to confirm it renders **identically to before this task**:
1. Sidebar + content render; sidebar nav drives the content pane (bridges intact).
2. The inspector is **initially hidden** (kitchen-sink creates it collapsed) — that's expected; toggling it is wired in Task 3.
3. Title bar / traffic lights / resize normal; devtools open.
Then `pkill -f "kitchen-sink/bin/kitchen-sink"`.

This is a pure-refactor regression gate (state source changed `@State`→`PaneState`). If the panes no longer render, the likely cause is the `@ObservedObject`/binding wiring or the `state` retain — report what you see; do not thrash.

- [ ] **Step 8: Commit**

```bash
git add native/platform/darwin/swift/panes.swift native/platform/darwin/window.m
git commit -m "feat(darwin): SwiftUI panes PaneState foundation + reverse-dispatcher seam (2a)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: sidebar runtime control + reverse visibility events

Wire `darwin_sidebar_*` to drive the SwiftUI sidebar, and SwiftUI sidebar changes back to `window:sidebar-collapsed`/`-expanded`.

**Files:**
- Modify: `native/platform/darwin/sidebar.m`
- Modify: `native/platform/darwin/window.m`

- [ ] **Step 1: Add the `swiftPaneState` property to `ZappSidebarController`**

In `native/platform/darwin/sidebar.m`, in the `@interface ZappSidebarController` block, after `@property (nonatomic, assign) int lastWidth;`, add:

```objc
@property (nonatomic, assign) void* swiftPaneState;  // non-owning; set for the SwiftUI path (nil = AppKit)
```

- [ ] **Step 2: Add `extern`s for the Swift setters/togglers**

Near the top of `sidebar.m` (with the other `extern` decls, after `extern void darwin_window_eval_js(...)`), add:

```objc
extern void zapp_swift_panes_set_sidebar_visible(void* state, bool visible);
extern void zapp_swift_panes_toggle_sidebar(void* state);
```

- [ ] **Step 3: Branch the sidebar control ops on the SwiftUI backing**

In `sidebar.m`, edit each op to short-circuit when `c.swiftPaneState` is set. Replace `darwin_sidebar_toggle`:

```objc
void darwin_sidebar_toggle(int32_t window_id) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
        if (c.swiftPaneState) { zapp_swift_panes_toggle_sidebar(c.swiftPaneState); return; }
        if (!c.sidebarItem) return;
        // Documented AppKit idiom: animate the collapsed property via the
        // item's animator proxy.
        [[c.sidebarItem animator] setCollapsed:!c.sidebarItem.isCollapsed];
    });
}
```

Replace `darwin_sidebar_collapse`:

```objc
void darwin_sidebar_collapse(int32_t window_id) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
        if (c.swiftPaneState) { zapp_swift_panes_set_sidebar_visible(c.swiftPaneState, false); return; }
        if (!c.sidebarItem) return;
        if (c.sidebarItem.isCollapsed) return; // idempotent
        [[c.sidebarItem animator] setCollapsed:YES];
    });
}
```

Replace `darwin_sidebar_expand`:

```objc
void darwin_sidebar_expand(int32_t window_id) {
    zapp_sidebar_on_main(^{
        ZappSidebarController* c = zapp_sidebar_for_slot(window_id);
        if (!c) return;
        if (c.swiftPaneState) { zapp_swift_panes_set_sidebar_visible(c.swiftPaneState, true); return; }
        if (!c.sidebarItem) return;
        if (!c.sidebarItem.isCollapsed) return; // idempotent
        [[c.sidebarItem animator] setCollapsed:NO];
    });
}
```

For `darwin_sidebar_set_width`, `darwin_sidebar_set_collapsible`, `darwin_sidebar_set_resizable` — add a SwiftUI no-op-with-log guard at the top of each (these are 2c work). Insert immediately after the `ZappSidebarController* c = zapp_sidebar_for_slot(window_id); if (!c ...) return;` line in each:

```objc
        if (c.swiftPaneState) {
            if (getenv("ZAPP_LOG")) NSLog(@"[zapp] sidebar width/lock ignored on SwiftUI path (Sub-cycle 2c)");
            return;
        }
```

(Place it before the existing `!c.sidebarItem`/`!c.splitVC` guard so it short-circuits cleanly.)

- [ ] **Step 4: Add `zapp_sidebar_register_swiftui` + `zapp_sidebar_note_swiftui_visibility`**

In `sidebar.m`, in the "Registry API for window.m" section (near `zapp_sidebar_register`), add:

```objc
// SwiftUI-backed register: no splitVC/NSSplitViewItem, no KVO/NSNotification
// observers (the Swift callback is the observation source). lastCollapsed is the
// dedup baseline, seeded from the visibility the PaneState was created with.
void zapp_sidebar_register_swiftui(void* window_ptr, void* paneState,
                                   int32_t host_id, int32_t sidebar_slot_id,
                                   bool initial_collapsed) {
    if (!window_ptr || !paneState) return;
    zapp_sidebar_on_main(^{
        if (!zapp_sidebars) zapp_sidebars = [NSMutableDictionary dictionary];
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        ZappSidebarController* c = [[ZappSidebarController alloc] init];
        c.swiftPaneState = paneState;
        c.hostWindowId = host_id;
        c.sidebarSlotId = sidebar_slot_id;
        c.lastCollapsed = initial_collapsed ? YES : NO;
        zapp_sidebars[key] = c;
    });
}

// Reverse path: SwiftUI sidebar visibility changed. Dedup against lastCollapsed,
// then emit the same event the AppKit KVO path emits. Called by window.m's
// reverse dispatcher (always on the main thread — SwiftUI bindings fire on main).
void zapp_sidebar_note_swiftui_visibility(void* window_ptr, bool collapsed) {
    if (!window_ptr || !zapp_sidebars) return;
    ZappSidebarController* c = zapp_sidebars[[NSValue valueWithPointer:window_ptr]];
    if (!c) return;
    if (collapsed == c.lastCollapsed) return;  // dedup (absorbs redundant sets)
    c.lastCollapsed = collapsed;
    zapp_sidebar_emit(c, collapsed ? "sidebar-collapsed" : "sidebar-expanded", nil);
}
```

- [ ] **Step 5: Make `zapp_sidebar_unregister` SwiftUI-aware**

Replace `zapp_sidebar_unregister` with:

```objc
void zapp_sidebar_unregister(void* window_ptr) {
    if (!window_ptr) return;
    zapp_sidebar_on_main(^{
        if (!zapp_sidebars) return;
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        ZappSidebarController* c = zapp_sidebars[key];
        if (!c) return;
        if (!c.swiftPaneState) {  // AppKit-only observers; none installed on the SwiftUI path
            @try {
                [c.sidebarItem removeObserver:c forKeyPath:@"collapsed"];
            } @catch (__unused NSException* e) {}
            [[NSNotificationCenter defaultCenter] removeObserver:c];
        }
        // Do NOT release swiftPaneState here — the window delegate owns it.
        [zapp_sidebars removeObjectForKey:key];
    });
}
```

- [ ] **Step 6: Wire the dispatcher arm + register call in `window.m`**

(a) In `window.m`'s `zapp_swiftui_pane_changed`, replace the stub body with the sidebar arm (inspector arm added in Task 3):

```objc
static void zapp_swiftui_pane_changed(void* ctx, int32_t key, int64_t value) {
    switch (key) {
        case ZAPP_PANE_KEY_SIDEBAR_VISIBLE:
            zapp_sidebar_note_swiftui_visibility(ctx, value == 0);  // value=1 visible -> collapsed=false
            break;
        default: break;
    }
}
```

(b) In the SwiftUI branch, in the `if (useSidebar) { … }` block (currently ~930-940), after the `zapp_set_sidebar_slot(host_slot, sidebar_slot);` line, add:

```objc
                    // Register a SwiftUI-backed controller so darwin_sidebar_* ops
                    // resolve + drive the PaneState (no splitVC/NSSplitViewItem).
                    zapp_sidebar_register_swiftui((__bridge void*)window, swiftPaneState,
                                                  host_slot, sidebar_slot, !sidebarVisible);
```

- [ ] **Step 7: Build**

`cd kitchen-sink && bun run build 2>&1 | tail -3 ; cd ..` → `[zapp] build complete: …`.

- [ ] **Step 8: GATE — human visual (PAUSE)**

Launch: `cd kitchen-sink && ./bin/kitchen-sink & cd ..`. Ask the user to confirm:
1. The Sidebar section's toggle button (or the shell hamburger) **collapses/expands the SwiftUI sidebar**.
2. App JS receives `window:sidebar-collapsed` / `window:sidebar-expanded` when it toggles (visible in the kitchen-sink event log / console).
Then `pkill -f "kitchen-sink/bin/kitchen-sink"`.

- [ ] **Step 9: Commit**

```bash
git add native/platform/darwin/sidebar.m native/platform/darwin/window.m
git commit -m "feat(darwin): SwiftUI sidebar runtime control + reverse visibility events (2a)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: inspector runtime control + reverse visibility events (the render/toggle payoff)

Exact inspector twin of Task 2. After this, the inspector renders + toggles on the SwiftUI path — the headline Sub-cycle-2a fix.

**Files:**
- Modify: `native/platform/darwin/inspector.m`
- Modify: `native/platform/darwin/window.m`

- [ ] **Step 1: Add the `swiftPaneState` property to `ZappInspectorController`**

In `native/platform/darwin/inspector.m`, in the `@interface ZappInspectorController` block, after `@property (nonatomic, assign) int lastWidth;`, add:

```objc
@property (nonatomic, assign) void* swiftPaneState;  // non-owning; set for the SwiftUI path (nil = AppKit)
```

- [ ] **Step 2: Add `extern`s for the Swift setters/togglers**

Near the top of `inspector.m` (with the other `extern` decls), add:

```objc
extern void zapp_swift_panes_set_inspector_presented(void* state, bool presented);
extern void zapp_swift_panes_toggle_inspector(void* state);
```

- [ ] **Step 3: Branch the inspector control ops on the SwiftUI backing**

Replace `darwin_inspector_toggle`:

```objc
void darwin_inspector_toggle(int32_t window_id) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
        if (c.swiftPaneState) { zapp_swift_panes_toggle_inspector(c.swiftPaneState); return; }
        if (!c.inspectorItem) return;
        // Documented AppKit idiom: animate the collapsed property via the
        // item's animator proxy.
        [[c.inspectorItem animator] setCollapsed:!c.inspectorItem.isCollapsed];
    });
}
```

Replace `darwin_inspector_collapse`:

```objc
void darwin_inspector_collapse(int32_t window_id) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
        if (c.swiftPaneState) { zapp_swift_panes_set_inspector_presented(c.swiftPaneState, false); return; }
        if (!c.inspectorItem) return;
        if (c.inspectorItem.isCollapsed) return; // idempotent
        [[c.inspectorItem animator] setCollapsed:YES];
    });
}
```

Replace `darwin_inspector_expand`:

```objc
void darwin_inspector_expand(int32_t window_id) {
    zapp_inspector_on_main(^{
        ZappInspectorController* c = zapp_inspector_for_slot(window_id);
        if (!c) return;
        if (c.swiftPaneState) { zapp_swift_panes_set_inspector_presented(c.swiftPaneState, true); return; }
        if (!c.inspectorItem) return;
        if (!c.inspectorItem.isCollapsed) return; // idempotent
        [[c.inspectorItem animator] setCollapsed:NO];
    });
}
```

For `darwin_inspector_set_width`, `darwin_inspector_set_collapsible`, `darwin_inspector_set_resizable` — insert the SwiftUI no-op-with-log guard at the top of each, immediately after the `ZappInspectorController* c = zapp_inspector_for_slot(window_id); if (!c ...) return;` line:

```objc
        if (c.swiftPaneState) {
            if (getenv("ZAPP_LOG")) NSLog(@"[zapp] inspector width/lock ignored on SwiftUI path (Sub-cycle 2c)");
            return;
        }
```

- [ ] **Step 4: Add `zapp_inspector_register_swiftui` + `zapp_inspector_note_swiftui_visibility`**

In `inspector.m`, in the "Registry API for window.m" section (near `zapp_inspector_register`), add:

```objc
// SwiftUI-backed register: no splitVC/NSSplitViewItem, no KVO/NSNotification
// observers (the Swift callback is the observation source). lastCollapsed is the
// dedup baseline, seeded from the visibility the PaneState was created with.
void zapp_inspector_register_swiftui(void* window_ptr, void* paneState,
                                     int32_t host_id, int32_t inspector_slot_id,
                                     bool initial_collapsed) {
    if (!window_ptr || !paneState) return;
    zapp_inspector_on_main(^{
        if (!zapp_inspectors) zapp_inspectors = [NSMutableDictionary dictionary];
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        ZappInspectorController* c = [[ZappInspectorController alloc] init];
        c.swiftPaneState = paneState;
        c.hostWindowId = host_id;
        c.inspectorSlotId = inspector_slot_id;
        c.lastCollapsed = initial_collapsed ? YES : NO;
        zapp_inspectors[key] = c;
    });
}

// Reverse path: SwiftUI inspector visibility changed. Dedup against lastCollapsed,
// then emit the same event the AppKit KVO path emits. Called by window.m's
// reverse dispatcher (always on the main thread — SwiftUI bindings fire on main).
void zapp_inspector_note_swiftui_visibility(void* window_ptr, bool collapsed) {
    if (!window_ptr || !zapp_inspectors) return;
    ZappInspectorController* c = zapp_inspectors[[NSValue valueWithPointer:window_ptr]];
    if (!c) return;
    if (collapsed == c.lastCollapsed) return;  // dedup (absorbs redundant sets)
    c.lastCollapsed = collapsed;
    zapp_inspector_emit(c, collapsed ? "inspector-collapsed" : "inspector-expanded", nil);
}
```

- [ ] **Step 5: Make `zapp_inspector_unregister` SwiftUI-aware**

Replace `zapp_inspector_unregister` with:

```objc
void zapp_inspector_unregister(void* window_ptr) {
    if (!window_ptr) return;
    zapp_inspector_on_main(^{
        if (!zapp_inspectors) return;
        NSValue* key = [NSValue valueWithPointer:window_ptr];
        ZappInspectorController* c = zapp_inspectors[key];
        if (!c) return;
        if (!c.swiftPaneState) {  // AppKit-only observers; none installed on the SwiftUI path
            @try {
                [c.inspectorItem removeObserver:c forKeyPath:@"collapsed"];
            } @catch (__unused NSException* e) {}
            [[NSNotificationCenter defaultCenter] removeObserver:c];
        }
        // Do NOT release swiftPaneState here — the window delegate owns it.
        [zapp_inspectors removeObjectForKey:key];
    });
}
```

- [ ] **Step 6: Wire the dispatcher arm + register call in `window.m`**

(a) In `window.m`'s `zapp_swiftui_pane_changed`, add the inspector arm:

```objc
static void zapp_swiftui_pane_changed(void* ctx, int32_t key, int64_t value) {
    switch (key) {
        case ZAPP_PANE_KEY_SIDEBAR_VISIBLE:
            zapp_sidebar_note_swiftui_visibility(ctx, value == 0);
            break;
        case ZAPP_PANE_KEY_INSPECTOR_PRESENTED:
            zapp_inspector_note_swiftui_visibility(ctx, value == 0);
            break;
        default: break;
    }
}
```

(b) In the SwiftUI branch, in the `if (useInspector) { … }` block (currently ~947-957), after the `zapp_set_inspector_slot(host_slot, inspector_slot);` line, add:

```objc
                    // Register a SwiftUI-backed controller so darwin_inspector_* ops
                    // resolve + drive the PaneState (no splitVC/NSSplitViewItem).
                    zapp_inspector_register_swiftui((__bridge void*)window, swiftPaneState,
                                                    host_slot, inspector_slot, !inspectorPresented);
```

- [ ] **Step 7: Build**

`cd kitchen-sink && bun run build 2>&1 | tail -3 ; cd ..` → `[zapp] build complete: …`.

- [ ] **Step 8: GATE — human visual (PAUSE)**

Launch: `cd kitchen-sink && ./bin/kitchen-sink & cd ..`. Ask the user to confirm:
1. The Inspector section's toggle button (or the shell inspector button) **shows/hides the inspector**, and the **inspector webview renders** its content (the Sub-cycle-1 dead-toggle limitation is gone).
2. App JS receives `window:inspector-collapsed` / `window:inspector-expanded` on toggle.
3. Sidebar (Task 2) still works; all three webviews' bridges intact; title bar / traffic lights normal.
Then `pkill -f "kitchen-sink/bin/kitchen-sink"`.

- [ ] **Step 9: Commit**

```bash
git add native/platform/darwin/inspector.m native/platform/darwin/window.m
git commit -m "feat(darwin): SwiftUI inspector runtime control + render/toggle + reverse events (2a)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: gate matrix + docs + final review

**Files:**
- Modify: `docs/native-ui-strategy.md`

- [ ] **Step 1: Opted-out build links clean with NO Swift panes**

Temporarily add `native: { swiftui: false },` to `kitchen-sink/zapp.config.ts` (top level of the config object), then:
```bash
cd kitchen-sink && bun run build 2>&1 | tail -2
nm bin/kitchen-sink | grep -cE 'zapp_swift_panes_(state_create|create)'   # expect 0
cd ..
```
Expected: `[zapp] build complete: …`; symbol count `0` (the `#ifdef ZAPP_HAS_SWIFTUI` block compiled out → AppKit path; `darwin_sidebar_*`/`darwin_inspector_*` keep their AppKit behavior since `swiftPaneState` is never set). Then **revert**: `git checkout kitchen-sink/zapp.config.ts` and confirm `git status --short kitchen-sink/zapp.config.ts` is empty.

- [ ] **Step 2: iOS-sim still builds (macOS-only change)**

```bash
cd kitchen-sink && bun run ../cli/src/zapp-cli.ts build --platform ios 2>&1 | tail -2 ; cd ..
```
Expected last line: `[zapp] build complete: …`. (`panes.swift` is only compiled for the macOS target — `resolveSwiftUIBuild` returns non-macOS for iOS — and `sidebar.m`/`inspector.m`'s new code is plain ObjC behind no new platform symbols. If the iOS build trips, that's a finding to report.)

- [ ] **Step 3: CLI tests green**

```bash
bun test cli/src 2>&1 | tail -3
```
Expected: all pass (no CLI surface changed; this guards against regressions).

- [ ] **Step 4: Docs — record Sub-cycle 2a status**

In `docs/native-ui-strategy.md`:
- In the **Roadmap** table, update the "SwiftUI accessories **Sub-cycle 2**" row: split out 2a as ✅ Done (runtime pane visibility control + reverse visibility events on the SwiftUI path; the inspector renders + toggles), with 2b (per-world toolbar) and 2c (presentation styles + width/lock parity) as ⏭ Next.
- In the **Sub-cycle 1 known limitations** list, mark "Runtime pane control not wired" as **resolved in 2a** (visibility only); note width/lock + tiling/presentation remain for 2c.
Keep it consistent with the doc's style.

- [ ] **Step 5: Commit**

```bash
git add docs/native-ui-strategy.md
git commit -m "docs: native-ui-strategy — Sub-cycle 2a (SwiftUI runtime pane control) shipped

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Final cross-cutting review**

Re-read the diff. Confirm:
(a) the AppKit path is behavior-unchanged — every `darwin_sidebar_*`/`darwin_inspector_*` op falls through to its original body when `c.swiftPaneState == NULL`;
(b) the `PaneState` is created once, stored on the delegate, and released **exactly once** at teardown (no per-controller release — both controllers hold non-owning copies);
(c) the SwiftUI `register_swiftui` controllers install **no** KVO/NSNotification observers, and `unregister` skips observer-removal for them;
(d) `lastCollapsed` is seeded (`!sidebarVisible` / `!inspectorPresented`) so the first reverse event isn't mis-deduped;
(e) `value == 0` ⇒ `collapsed` is consistent across the dispatcher and both `note_*` fns;
(f) width/`setCollapsible`/`setResizable` are no-ops-with-log on the SwiftUI path (2c), not silently dropped;
(g) no public `WindowOptions` field / env flag / app-facing surface added (the BYO seam is internal — #622).
Record any follow-ups in memory (update `project_swiftui_cxx_interop_spike`).

---

## Self-Review (against the spec)

**Spec coverage:**
- "PaneState ObservableObject + scalar C-ABI; PaneLayout derives bindings" → Task 1 Step 1. ✓
- "Forward: darwin_sidebar/inspector toggle/collapse/expand drive PaneState; toggle decided Swift-side" → Task 2 Step 3 / Task 3 Step 3 (togglers) + branch guards. ✓
- "Reverse: change-driven ZappSwiftStateCallback → switch dispatcher → zapp_pane_emit; dedup via lastCollapsed; seeded baseline" → Task 1 Step 2 (typedef/enum/stub), Task 2/3 Step 4 (note_* + emit) + Step 6 (dispatcher arms); register seeds `lastCollapsed`. ✓
- "window.m registers SwiftUI controllers (the omitted bit) with initial collapsed baseline" → Task 2/3 Step 6(b). ✓
- "Ownership: delegate owns PaneState, released once; controllers non-owning" → Task 1 Step 5; Task 2/3 unregister do not release. ✓
- "Scope: visibility only; width/setCollapsible/setResizable = documented no-op + log; presentation/tiling 2c; toolbar 2b" → Task 2/3 Step 3 guards; `.balanced` retained. ✓
- "BYO seam: named callback contract + switch dispatcher + scalar keys; no app-facing surface" → Task 1 Step 1/2; Task 4 Step 6(g). ✓
- "Testing: build gates (macOS default symbols; opted-out no-swift; iOS-sim builds; bun test cli/src) + human visual smoke" → Task 1 Step 6/7, Task 2 Step 7/8, Task 3 Step 7/8, Task 4 Steps 1-3. ✓
- Non-goals (toolbar, width events, presentation, iOS, full BYO) → not tasked; called out in Task 4 Step 6. ✓

**Placeholder scan:** None. Every code step shows full code; the only "added in Task N" notes are in the Task-1 dispatcher stub, which is replaced wholesale in Tasks 2/3 Step 6(a) (full bodies given). Container-construction code in window.m is untouched by this plan (Sub-cycle 1 already built it), so nothing is cited-by-line-to-copy.

**Type/name consistency:** `zapp_swift_panes_create` signature changes once (Task 1) to `(state, content, sidebar, inspector)` and the window.m call + extern are updated in the same task. `PaneState`, `ZappSwiftStateCallback`, `kPaneKeySidebarVisible`/`kPaneKeyInspectorPresented` (Swift) ↔ `ZAPP_PANE_KEY_SIDEBAR_VISIBLE`/`ZAPP_PANE_KEY_INSPECTOR_PRESENTED` (ObjC) match in value (1/2). `swiftPaneState` is the consistent name across `PaneState` handle (window.m local + delegate prop) and both controllers. `zapp_sidebar_register_swiftui`/`zapp_inspector_register_swiftui` + `zapp_sidebar_note_swiftui_visibility`/`zapp_inspector_note_swiftui_visibility` match their externs in window.m (Task 1 Step 2) and definitions (Task 2/3 Step 4). The `value == 0 ⇒ collapsed` convention is uniform. ✓
```
