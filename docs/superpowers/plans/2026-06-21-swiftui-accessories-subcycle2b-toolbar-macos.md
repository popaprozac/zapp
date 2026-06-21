# SwiftUI accessories Sub-cycle 2b — per-world toolbar (macOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the SwiftUI pane path (macOS 14+, accessory'd window, not opted out), render the window's title-bar toolbar via SwiftUI `.toolbar` (no `NSToolbar`), driven by the same app-facing toolbar spec; on the AppKit path, keep `NSToolbar` unchanged. Fixes the toolbar collision + dead sidebar toggle.

**Architecture:** Per-world fork at the toolbar boundary, behind one app-facing spec. The SwiftUI tree is hosted via `NSHostingController` (so `.toolbar` bridges into the `NSWindow` title bar). A new `ToolbarState: ObservableObject` (conforming to a generic `ZappNativeModule` protocol) holds the parsed items; `PaneLayout` applies `.toolbar` from it + `.toolbar(removing: .sidebarToggle)` (Strategy A — app authors the items). Communication uses the generic key-routed ObjC↔Swift bridge: 2a's scalar channel + a NEW string channel (`ZappSwiftStringCallback` reverse + `zapp_swift_module_set_string` forward) — the toolbar is its first consumer and the BYO-native-module seam (#622). Clicks route through the existing `window:toolbar-clicked` emit; no runtime/TS changes.

**Tech Stack:** Swift (SwiftUI/AppKit, the existing `swiftc` step globs `native/platform/darwin/swift/*.swift`), Objective-C (`window.m`, `toolbar.m`), Nim (`router.nim`). macOS 14 floor.

**Branch:** `feat/nim-native` (do not merge to main). **Commit trailer (every commit):**
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

**Spec:** `docs/superpowers/specs/2026-06-21-swiftui-accessories-subcycle2b-toolbar-macos-design.md`
**References:**
- `native/platform/darwin/swift/panes.swift` — current (post-2a): `PaneState`, `PaneLayout`, `zapp_swift_panes_create` (returns `NSHostingView` at line ~132-144), the `ZappSwiftStateCallback` scalar channel + `passRetained` pattern.
- `native/platform/darwin/window.m` — the SwiftUI fork: `paneHost` create + `window.contentView = paneHost` (~947-952); the SwiftUI `register_swiftui` calls + `swiftPaneState` delegate ownership/teardown (from 2a); the toolbar attach (`darwin_toolbar_attach`, ~1306-1322); teardown `zapp_toolbar_unregister` (~1404).
- `native/platform/darwin/toolbar.m` — `ZappToolbarController`, `darwin_toolbar_attach/set_items/update_item/remove`, `zappToolbarItemClicked:` emit (the `window:toolbar-clicked` JS), `NSMenuToolbarItem` (menu items ride `__menu:click`), `zapp_toolbar_inject_metrics` (chrome metrics KVO).
- `runtime/window.ts` — `ToolbarItemDef`/`normalizeToolbar`/the `toolbar:*` wire (`{style, items:[{type,id,label,icon,enabled,indicator,menu}]}`) — **unchanged**.
- `native/nim/router.nim:606-620` — the `toolbar:*` arm.

---

## Verification model (read first)

**No unit tests for native UI** — verification is **build-succeeds + human visual smoke** (the established gate). Build-complete signal = last line `[zapp] build complete: …` (Vite's `✓ built` is NOT success).

**Build command (from repo root):** `cd kitchen-sink && bun run build 2>&1 | tail -3 ; cd ..`. The kitchen-sink main window is accessory'd → SwiftUI path on macOS 14+. **For console/devtools gates, the user runs `bun run dev` in `kitchen-sink/` themselves** (the built binary is prod, no devtools). The kitchen-sink **Toolbar section** (`kitchen-sink/src/sections/toolbar.ts`) already exercises `setItems`/`updateItem`/toggle.

**`#ifdef ZAPP_HAS_SWIFTUI` discipline (2a lesson):** every reference to a `zapp_swift_*` symbol — externs AND call sites, in window.m/toolbar.m — must be guarded, so the opted-out (`native.swiftui:false`) + iOS builds link clean.

**Critical invariant:** WKWebviews are created into their containers and never re-parented. This cycle does not touch webview creation; the hosting pivot (`NSHostingView`→`NSHostingController`) wraps the *same* container tree.

**Risk-isolating order:** Task 1 is a true risk gate — prove SwiftUI `.toolbar` bridges to the title bar via `NSHostingController` (with the panes/webviews/2a-control unregressed) using a *hardcoded* trivial toolbar, BEFORE building the real renderer. If it can't bridge, STOP and report — it reshapes the approach.

---

## File Structure

**Create:**
- `native/platform/darwin/swift/toolbar.swift` — `ZappNativeModule` protocol, the `ZappSwiftStringCallback` typedef, `ZappToolbarItem`/`ZappMenuItem` models + JSON parse, `ToolbarState` (ObservableObject + protocol conformance), the `ZappToolbarContent` SwiftUI builder, and the generic string-channel `@_cdecl`s.

**Modify:**
- `native/platform/darwin/swift/panes.swift` — `PaneLayout` takes a `ToolbarState` + applies `.toolbar`/`.toolbar(removing:)`; `zapp_swift_panes_create` gains a `toolbarState` param and returns an `NSHostingController`.
- `native/platform/darwin/window.m` — host via `NSHostingController`; skip `darwin_toolbar_attach` on the SwiftUI path; create/own the `ToolbarState` + the string-dispatcher; register; teardown.
- `native/platform/darwin/toolbar.m` — extract the click/menu emit into shared `zapp_toolbar_emit_click`/`zapp_toolbar_emit_menu_click` helpers.
- `native/nim/router.nim` — fork the `toolbar:*` arm on `zapp_window_uses_swiftui_toolbar`.
- `docs/native-ui-strategy.md` — Task 7.

---

## Task 1 (RISK GATE): hosting pivot + trivial `.toolbar` proof

Prove SwiftUI `.toolbar` reaches the window title bar via `NSHostingController`, with panes/webviews/2a-control unregressed, using a hardcoded toolbar. Skip the `NSToolbar` on the SwiftUI path so the SwiftUI toolbar is the only one.

**Files:**
- Modify: `native/platform/darwin/swift/panes.swift`
- Modify: `native/platform/darwin/window.m`

- [ ] **Step 1: panes.swift — apply a hardcoded `.toolbar` + return an `NSHostingController`**

In `PaneLayout`, wrap the body so a `.toolbar` is applied to the root. Replace `var body: some View { … }` with a version that applies the toolbar + suppresses SwiftUI's auto sidebar toggle. Add this computed property + modify `body`:

```swift
  var body: some View {
    rootView
      .toolbar(removing: .sidebarToggle)
      .toolbar {
        // TASK 1 PROBE — hardcoded; replaced by ToolbarState-driven content in Task 3.
        ToolbarItem {
          Button { state.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
        }
        ToolbarItem {
          Button { state.inspectorPresented.toggle() } label: { Image(systemName: "sidebar.right") }
        }
        ToolbarItem {
          Button("Probe") { /* Task 1: no-op; proves a custom button renders */ }
        }
      }
  }

  @ViewBuilder private var rootView: some View {
    if let sidebar {
      NavigationSplitView(columnVisibility: sidebarVisibilityBinding) {
        PaneHost(view: sidebar).ignoresSafeArea()
      } detail: { detail }
      .navigationSplitViewStyle(.balanced)
    } else {
      detail
    }
  }
```

(`detail`, the bindings, and `PaneHost` are unchanged. The old `body`'s `if let sidebar … else …` becomes `rootView`.)

Then change `zapp_swift_panes_create` to return an **`NSHostingController`** instead of an `NSHostingView`:

```swift
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
  let hc = NSHostingController(rootView: PaneLayout(content: c, sidebar: s, inspector: i, state: st))
  return Unmanaged.passRetained(hc).toOpaque()   // +1; ObjC consumes via __bridge_transfer NSViewController*
}
```

- [ ] **Step 2: window.m — host via `NSHostingController` + skip the NSToolbar on the SwiftUI path**

(a) In the SwiftUI branch, replace the paneHost-as-contentView block (currently ~947-952):

```objc
                NSView* paneHost = (__bridge_transfer NSView*)zapp_swift_panes_create(
                    swiftPaneState, (__bridge void*)mainContainer,
                    (__bridge void*)sidebarContainer, (__bridge void*)inspectorContainer);
                paneHost.frame = [window contentView].frame;
                window.contentView = paneHost;
                [paneHost layoutSubtreeIfNeeded];
```

with (host via the controller):

```objc
                NSViewController* paneVC = (__bridge_transfer NSViewController*)zapp_swift_panes_create(
                    swiftPaneState, (__bridge void*)mainContainer,
                    (__bridge void*)sidebarContainer, (__bridge void*)inspectorContainer);
                window.contentViewController = paneVC;   // sets window.contentView = paneVC.view; window retains the VC
                [paneVC.view layoutSubtreeIfNeeded];
```

(Read the actual current lines first — the exact `zapp_swift_panes_create(...)` arg formatting/comment may differ; preserve everything except the view→controller swap. The webview-creation code AFTER this — `darwin_webview_create_ext` into the containers, `zapp_register_webview`, `zapp_set_*_slot`, `register_swiftui` — is UNCHANGED; it operates on the containers, which are inside the hosted tree either way.)

(b) Skip the NSToolbar attach on the SwiftUI path. Find the toolbar-attach block (currently ~1306-1322, `const char* toolbarJson = wopts_toolbar_json(opts); if (toolbarJson && toolbarJson[0]) { darwin_toolbar_attach(...); … inject_metrics … }`). Guard it so it only runs on the AppKit path. The construction has a `bool useSwiftUIPanes` in scope earlier (from 2a) — but it may be out of scope at line 1306; re-derive a local from the delegate or a flag. Simplest: capture the decision in a local that survives to the attach site. Near the toolbar-attach block, wrap:

```objc
        // Sub-cycle 2b: on the SwiftUI pane path the toolbar is rendered by SwiftUI
        // `.toolbar` (toolbar.swift); do NOT attach an NSToolbar (it would collide).
        bool swiftUIToolbar = false;
#ifdef ZAPP_HAS_SWIFTUI
        swiftUIToolbar = (delegate.swiftPaneState != NULL);  // set iff the SwiftUI pane path ran
#endif
        const char* toolbarJson = wopts_toolbar_json(opts);
        if (!swiftUIToolbar && toolbarJson && toolbarJson[0]) {
            darwin_toolbar_attach((__bridge void*)window, toolbarJson, host_slot);
            // … existing inject_metrics block, unchanged …
        }
```

(`delegate.swiftPaneState` is the 2a-owned handle, non-NULL exactly when the SwiftUI path built the panes — a reliable "this window is SwiftUI-backed" signal. Confirm `delegate` is in scope at the attach site; it is assigned earlier in construction.)

- [ ] **Step 3: Build (macOS)**

Run: `cd kitchen-sink && bun run build 2>&1 | tail -3 ; cd ..` → last line `[zapp] build complete: …`.

- [ ] **Step 4: GATE — human visual smoke (macOS 14), PAUSE for the user**

Ask the user to run `bun run dev` in `kitchen-sink/` and confirm:
1. The window shows a **title-bar toolbar** with the two toggle buttons + a "Probe" button (rendered by SwiftUI `.toolbar`, NOT the old flickering NSToolbar).
2. The sidebar/inspector toggle buttons **drive the panes** (animate open/closed).
3. **No flicker/vanish** of toolbar items (the collision is gone — there's no second NSToolbar).
4. Panes + content + **real webviews** render; the bridge round-trips; **2a control** still works (in-content sidebar/inspector toggles); title bar / traffic lights / resize normal; devtools open.
5. (Note for later) whether the page's `--zapp-titlebar-height`/`--zapp-toolbar-height` look right (chrome metrics) — informs Task 6.

**If the toolbar does NOT appear in the title bar** (e.g. renders inline or not at all), this is the risk-gate failure: report BLOCKED with what you see — it means `.toolbar` doesn't bridge via `NSHostingController` and the approach needs rethink (titlebar-accessory controller, etc.). Do not thrash.

- [ ] **Step 5: Commit**

```bash
git add native/platform/darwin/swift/panes.swift native/platform/darwin/window.m
git commit -m "feat(darwin): SwiftUI toolbar risk gate — host via NSHostingController + .toolbar proof (2b)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: `toolbar.swift` — generic string channel + ToolbarState (no rendering yet)

**Files:**
- Create: `native/platform/darwin/swift/toolbar.swift`

- [ ] **Step 1: Write `toolbar.swift` (model + state + generic channel; no SwiftUI `.toolbar` content yet — that's Task 3)**

```swift
import SwiftUI
import AppKit

// --- Generic native-module bridge (the cross-language seam, #622) -------------
// A module's Swift state object conforms to ZappNativeModule; ObjC drives it via
// the generic scalar/string channel. The SCALAR channel + reverse callback live
// in panes.swift (PaneState, 2a: ZappSwiftStateCallback). This file adds the
// STRING channel + its first consumer (the toolbar).

protocol ZappNativeModule: AnyObject {
  func applyScalar(_ key: Int32, _ value: Int64)
  func applyString(_ key: Int32, _ value: String)
}
extension ZappNativeModule {
  func applyScalar(_ key: Int32, _ value: Int64) {}   // default: scalar-less modules ignore
}

// Reverse string channel (Swift -> native). Sibling of ZappSwiftStateCallback.
public typealias ZappSwiftStringCallback =
  @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void

// Generic forward string setter: ObjC -> a module's applyString. Protocol-
// dispatched so any ZappNativeModule reuses it.
@_cdecl("zapp_swift_module_set_string")
public func zapp_swift_module_set_string(_ state: UnsafeMutableRawPointer,
                                         _ key: Int32,
                                         _ value: UnsafePointer<CChar>?) {
  guard let mod = Unmanaged<AnyObject>.fromOpaque(state).takeUnretainedValue() as? ZappNativeModule
  else { return }
  let s = value != nil ? String(cString: value!) : ""
  mod.applyString(key, s)
}

// --- Toolbar module ----------------------------------------------------------
// Key namespace (must match the enum in window.m).
private let kTbSetItems: Int32 = 1     // value = full toolbarJson {style, items:[...]}
private let kTbUpdateItem: Int32 = 2   // value = one itemJson
private let kTbClear: Int32 = 3        // value = "" 
let kTbEvtClick: Int32 = 1             // reverse: value = itemId
let kTbEvtMenuClick: Int32 = 2         // reverse: value = menuId

struct ZappMenuItem: Decodable, Identifiable {
  var id: String { dynId }
  let dynId: String
  let label: String?
  let icon: String?
  enum CodingKeys: String, CodingKey { case dynId = "id", label, icon }
}

struct ZappToolbarItem: Decodable, Identifiable {
  let id: String          // synthesized for spacer/separator (no app id)
  let type: String        // button | toggleSidebar | toggleInspector | trackingSeparator | space | flexibleSpace
  let label: String?
  let icon: String?
  let enabled: Bool?
  let indicator: Bool?
  let menu: [ZappMenuItem]?

  enum CodingKeys: String, CodingKey { case id, type, label, icon, enabled, indicator, menu }
  init(from dec: Decoder) throws {
    let c = try dec.container(keyedBy: CodingKeys.self)
    self.type = (try? c.decode(String.self, forKey: .type)) ?? "button"
    let rawId = try? c.decode(String.self, forKey: .id)
    self.id = rawId ?? "__\(type)_\(UUID().uuidString.prefix(8))"
    self.label = try? c.decode(String.self, forKey: .label)
    self.icon = try? c.decode(String.self, forKey: .icon)
    self.enabled = try? c.decode(Bool.self, forKey: .enabled)
    self.indicator = try? c.decode(Bool.self, forKey: .indicator)
    self.menu = try? c.decode([ZappMenuItem].self, forKey: .menu)
  }
}

private struct ZappToolbarWire: Decodable { let style: String?; let items: [ZappToolbarItem]? }

@available(macOS 14.0, *)
final class ToolbarState: ObservableObject, ZappNativeModule {
  @Published var items: [ZappToolbarItem] = []
  @Published var style: String = "unified"
  let ctx: UnsafeMutableRawPointer?
  let cb: ZappSwiftStringCallback?

  init(ctx: UnsafeMutableRawPointer?, cb: ZappSwiftStringCallback?) { self.ctx = ctx; self.cb = cb }

  func applyString(_ key: Int32, _ value: String) {
    switch key {
    case kTbSetItems:
      if let data = value.data(using: .utf8),
         let wire = try? JSONDecoder().decode(ZappToolbarWire.self, from: data) {
        self.style = wire.style ?? "unified"
        self.items = wire.items ?? []
      }
    case kTbUpdateItem:
      if let data = value.data(using: .utf8),
         let patch = try? JSONDecoder().decode(ZappToolbarItem.self, from: data),
         let idx = items.firstIndex(where: { $0.id == patch.id }) {
        items[idx] = patch   // whole-item replace (matches updateItem's merged-def wire)
      }
    case kTbClear:
      items = []
    default: break
    }
  }

  // Reverse: a SwiftUI toolbar button/menu was tapped.
  func emitClick(_ itemId: String) { itemId.withCString { cb?(ctx, kTbEvtClick, $0) } }
  func emitMenuClick(_ menuId: String) { menuId.withCString { cb?(ctx, kTbEvtMenuClick, $0) } }
}

@_cdecl("zapp_swift_toolbar_state_create")
public func zapp_swift_toolbar_state_create(_ ctx: UnsafeMutableRawPointer?,
                                            _ cb: ZappSwiftStringCallback?) -> UnsafeMutableRawPointer? {
  guard #available(macOS 14.0, *) else { return nil }
  return Unmanaged.passRetained(ToolbarState(ctx: ctx, cb: cb)).toOpaque()
}

@_cdecl("zapp_swift_toolbar_state_release")
public func zapp_swift_toolbar_state_release(_ state: UnsafeMutableRawPointer) {
  Unmanaged<AnyObject>.fromOpaque(state).release()
}
```

- [ ] **Step 2: Build**

`cd kitchen-sink && bun run build 2>&1 | tail -3 ; cd ..` → `build complete`. (toolbar.swift compiles; not yet wired into PaneLayout.)

- [ ] **Step 3: Commit**

```bash
git add native/platform/darwin/swift/toolbar.swift
git commit -m "feat(darwin): toolbar.swift — generic string channel + ToolbarState (2b)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: render the real toolbar from `ToolbarState`

Replace Task 1's hardcoded `.toolbar` with `ToolbarState`-driven content.

**Files:**
- Modify: `native/platform/darwin/swift/toolbar.swift`
- Modify: `native/platform/darwin/swift/panes.swift`

- [ ] **Step 1: Add the `ZappToolbarContent` builder to `toolbar.swift`**

```swift
@available(macOS 14.0, *)
struct ZappToolbarContent: ToolbarContent {
  let state: ToolbarState
  let pane: PaneState   // toggles bind directly to pane visibility (2a)

  var body: some ToolbarContent {
    ForEach(state.items) { item in
      ToolbarItem(id: item.id) { itemView(item) }
    }
  }

  @ViewBuilder private func itemView(_ item: ZappToolbarItem) -> some View {
    switch item.type {
    case "toggleSidebar":
      Button { pane.sidebarVisible.toggle() } label: { glyph(item, fallback: "sidebar.left") }
    case "toggleInspector":
      Button { pane.inspectorPresented.toggle() } label: { glyph(item, fallback: "sidebar.right") }
    case "space", "flexibleSpace", "trackingSeparator":
      // Spacers/separators: NavigationSplitView auto-aligns toolbar sections to
      // columns, so trackingSeparator is a no-op; space/flexibleSpace use the
      // system spacer. (SwiftUI ToolbarSpacer is macOS 14+.)
      Spacer()
    default: // "button"
      if let menu = item.menu, !menu.isEmpty {
        Menu { ForEach(menu) { m in Button(m.label ?? m.id) { state.emitMenuClick(m.id) } } }
          label: { label(item) }
          .disabled(item.enabled == false)
      } else {
        Button { state.emitClick(item.id) } label: { label(item) }
          .disabled(item.enabled == false)
      }
    }
  }

  @ViewBuilder private func glyph(_ item: ZappToolbarItem, fallback: String) -> some View {
    if let icon = item.icon, icon.hasPrefix("sf:") { Image(systemName: String(icon.dropFirst(3))) }
    else { Image(systemName: fallback) }
  }
  @ViewBuilder private func label(_ item: ZappToolbarItem) -> some View {
    if let icon = item.icon, icon.hasPrefix("sf:") {
      Label(item.label ?? "", systemImage: String(icon.dropFirst(3)))
    } else if let t = item.label, !t.isEmpty {
      Text(t)
    } else {
      Image(systemName: "circle")  // fallback so an iconless/labelless button is still tappable
    }
  }
}
```

IMPLEMENTER NOTE: SwiftUI's `ToolbarContent` + dynamic `ForEach` + per-item placement is the fiddly part. The above is a working starting point; the human-visual gate (Task 5) is where you refine placement (`ToolbarItem(placement:)`), spacer fidelity (`ToolbarSpacer` on macOS 14+), and button chrome to match the AppKit look. If `ForEach` in `ToolbarContent` won't compile against the installed SDK, fall back to a fixed set of optional `ToolbarItem`s keyed off the parsed items. Note any divergence; don't expand scope.

- [ ] **Step 2: panes.swift — thread `ToolbarState` into `PaneLayout` + apply the real `.toolbar`**

Add to `PaneLayout`: `@ObservedObject var toolbar: ToolbarState`. Replace Task 1's hardcoded `.toolbar { … }` with:

```swift
  var body: some View {
    rootView
      .toolbar(removing: .sidebarToggle)
      .toolbar { ZappToolbarContent(state: toolbar, pane: state) }
      .toolbarStyle(for: toolbar.style)
  }
```

Add a small helper (or inline) for the style mapping — define as a `View` extension in panes.swift or toolbar.swift:

```swift
@available(macOS 14.0, *)
extension View {
  @ViewBuilder func toolbarStyle(for style: String) -> some View {
    switch style {
    case "unifiedCompact": self.toolbar(style: .unifiedCompact)
    case "expanded":       self.toolbar(style: .expanded)
    default:               self.toolbar(style: .unified)
    }
  }
}
```

(If `.toolbar(style:)` on a hosted view doesn't take effect, drop the style modifier and note it for Task 6 — style is cosmetic.)

Update `zapp_swift_panes_create` to take + pass the toolbar state:

```swift
@_cdecl("zapp_swift_panes_create")
public func zapp_swift_panes_create(_ state: UnsafeMutableRawPointer,
                                    _ toolbarState: UnsafeMutableRawPointer,
                                    _ content: UnsafeMutableRawPointer,
                                    _ sidebar: UnsafeMutableRawPointer?,
                                    _ inspector: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
  guard #available(macOS 14.0, *) else { return nil }
  let st = Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue()
  let tb = Unmanaged<ToolbarState>.fromOpaque(toolbarState).takeUnretainedValue()
  let c = Unmanaged<NSView>.fromOpaque(content).takeUnretainedValue()
  let s = sidebar.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
  let i = inspector.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
  let hc = NSHostingController(rootView: PaneLayout(content: c, sidebar: s, inspector: i, state: st, toolbar: tb))
  return Unmanaged.passRetained(hc).toOpaque()
}
```

(window.m's call site gains the `toolbarState` arg in Task 4. Until then the build will fail to link the new signature — Task 3 Step 3's build is Swift-compile-only; the window.m caller is updated in Task 4. To keep Task 3 independently building, temporarily leave the window.m call passing the old 4-arg form is NOT possible since the signature changed — so Task 3 + Task 4 land together. **Combine Task 3's build/commit with Task 4** OR update the window.m extern+call in Task 3 Step 2 too. RECOMMENDED: do the window.m extern + call-site update here in Task 3 so each task builds.)

Update the window.m extern (under `#ifdef ZAPP_HAS_SWIFTUI`) + the call site to the new 5-arg signature, creating the ToolbarState first (a minimal version; the dispatcher/registration is fleshed out in Task 4):

```objc
// extern (window.m, under ZAPP_HAS_SWIFTUI):
extern void* zapp_swift_toolbar_state_create(void* ctx, ZappSwiftStringCallback cb);
extern void zapp_swift_toolbar_state_release(void* state);
extern void zapp_swift_module_set_string(void* state, int32_t key, const char* value);
extern void* zapp_swift_panes_create(void* state, void* toolbarState, void* content, void* sidebar, void* inspector);
```

In the SwiftUI branch, before `zapp_swift_panes_create`, create the toolbar state (callback wired in Task 4 — pass `NULL` cb here, fill in Task 4) and pass it:

```objc
                void* swiftToolbarState = zapp_swift_toolbar_state_create((__bridge void*)window, NULL);
                NSViewController* paneVC = (__bridge_transfer NSViewController*)zapp_swift_panes_create(
                    swiftPaneState, swiftToolbarState, (__bridge void*)mainContainer,
                    (__bridge void*)sidebarContainer, (__bridge void*)inspectorContainer);
```

Add a `void* swiftToolbarState = NULL;` local near `swiftPaneState` (declared in 2a) and a delegate property + teardown release (mirror `swiftPaneState`): `@property (nonatomic, assign) void* swiftToolbarState;`, `delegate.swiftToolbarState = swiftToolbarState;`, and at teardown `if (delegate.swiftToolbarState) { zapp_swift_toolbar_state_release(delegate.swiftToolbarState); delegate.swiftToolbarState = NULL; }` (under `#ifdef ZAPP_HAS_SWIFTUI`).

You'll also need a `ZappSwiftStringCallback` typedef in window.m (under `#ifdef ZAPP_HAS_SWIFTUI`): `typedef void (*ZappSwiftStringCallback)(void* ctx, int32_t key, const char* value);`.

- [ ] **Step 3: Build**

`cd kitchen-sink && bun run build 2>&1 | tail -3 ; cd ..` → `build complete`. (Toolbar renders from ToolbarState; it's empty until Task 4 pushes the config toolbar, but the kitchen-sink calls `setItems` at runtime — which still routes to NSToolbar until Task 5's router fork. So at this point the SwiftUI toolbar shows nothing yet; that's expected — Tasks 4-5 wire the data + clicks.)

- [ ] **Step 4: Commit**

```bash
git add native/platform/darwin/swift/toolbar.swift native/platform/darwin/swift/panes.swift native/platform/darwin/window.m
git commit -m "feat(darwin): SwiftUI toolbar renderer (ZappToolbarContent) + ToolbarState wiring (2b)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: shared emit helpers + window.m string-dispatcher + initial toolbar push

**Files:**
- Modify: `native/platform/darwin/toolbar.m`
- Modify: `native/platform/darwin/window.m`

- [ ] **Step 1: toolbar.m — extract shared emit helpers**

Refactor the body of `zappToolbarItemClicked:` into a reusable C function, and add a menu twin. Add near the top of toolbar.m (after the externs):

```objc
// Shared toolbar emit — used by the NSToolbar handler AND the SwiftUI toolbar
// reverse dispatcher (window.m). itemId must be non-NULL.
void zapp_toolbar_emit_click(int32_t host_id, const char* item_id) {
    if (!item_id) return;
    NSString* itemId = [NSString stringWithUTF8String:item_id];
    NSString* escaped = [itemId stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* js = [NSString stringWithFormat:
            @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&b._onEvent)b._onEvent('window:toolbar-clicked',"
            "'{\"windowId\":\"win-%d\",\"id\":\"%@\"}');})();",
            host_id, escaped];
        darwin_webview_eval_all([js UTF8String]);
        worker_broadcast_eval_js((char*)[js UTF8String]);
    });
}
```

Then make `zappToolbarItemClicked:` call it:

```objc
- (void)zappToolbarItemClicked:(NSToolbarItem*)sender {
    if (!sender.itemIdentifier.length) return;
    zapp_toolbar_emit_click(self.windowNumericId, [sender.itemIdentifier UTF8String]);
}
```

For menus: the NSToolbar path uses `NSMenuToolbarItem` whose clicks ride the existing `__menu:click` broadcast (menu.m). The SwiftUI path's `Menu` buttons need the same `__menu:click` emit. Add a `zapp_toolbar_emit_menu_click(int32_t host_id, const char* menu_id)` that emits the `__menu:click` event in the same shape menu.m uses (read menu.m's `__menu:click` emit and mirror it — it's `b._onEvent('__menu:click', '{"id":"<menuId>"}')` style; match it exactly). Keep it minimal and consistent with menu.m.

- [ ] **Step 2: window.m — the SwiftUI toolbar string-dispatcher + real callback + initial push**

Add a file-static reverse dispatcher (sibling to 2a's `zapp_swiftui_pane_changed`), under `#ifdef ZAPP_HAS_SWIFTUI`:

```objc
extern void zapp_toolbar_emit_click(int32_t host_id, const char* item_id);
extern void zapp_toolbar_emit_menu_click(int32_t host_id, const char* menu_id);
enum { ZAPP_TB_EVT_CLICK = 1, ZAPP_TB_EVT_MENU_CLICK = 2 };
enum { ZAPP_TB_SET_ITEMS = 1, ZAPP_TB_UPDATE_ITEM = 2, ZAPP_TB_CLEAR = 3 };

// ctx is the host NSWindow*. Map to numeric id for the emit.
static void zapp_swiftui_toolbar_event(void* ctx, int32_t key, const char* value) {
    int32_t host = darwin_window_numeric_id_for_ptr(ctx);  // see note below
    switch (key) {
        case ZAPP_TB_EVT_CLICK:      zapp_toolbar_emit_click(host, value); break;
        case ZAPP_TB_EVT_MENU_CLICK: zapp_toolbar_emit_menu_click(host, value); break;
        default: break;
    }
}
```

NOTE: you need the host numeric id from the window pointer. 2a's pane dispatcher passed the host id implicitly (the note fns resolved the controller by window ptr). For the toolbar emit you need the numeric `host_id`. Two options: (a) pass `host_slot` (already known at construction) as the `ctx` instead of the window pointer — but ctx is used as the registry key elsewhere; toolbar doesn't share that registry, so **passing the numeric host id boxed as the ctx is fine here** — simplest: create the ToolbarState with `ctx = (void*)(intptr_t)host_slot` and in the dispatcher `int32_t host = (int32_t)(intptr_t)ctx;`. Use that. (Document it: the toolbar module's `ctx` is the numeric host id, not the window ptr.)

Revise Task 3's `zapp_swift_toolbar_state_create` call to pass the boxed host id + the real dispatcher, and push the initial config toolbar:

```objc
                void* swiftToolbarState = zapp_swift_toolbar_state_create(
                    (void*)(intptr_t)host_slot, zapp_swiftui_toolbar_event);
                // (then zapp_swift_panes_create(swiftPaneState, swiftToolbarState, …) as Task 3)
                // Push the initial config toolbar into the SwiftUI toolbar (instead of NSToolbar).
                {
                    const char* tj = wopts_toolbar_json(opts);
                    if (tj && tj[0]) zapp_swift_module_set_string(swiftToolbarState, ZAPP_TB_SET_ITEMS, tj);
                }
```

Register the window as SwiftUI-toolbar-backed for the router fork (Task 5). Simplest: the `delegate.swiftToolbarState != NULL` already signals it; expose a resolver in Task 5.

- [ ] **Step 3: Build**

`cd kitchen-sink && bun run build 2>&1 | tail -3 ; cd ..` → `build complete`. The config-declared toolbar (if any) now renders via SwiftUI; clicks emit `window:toolbar-clicked`. (Runtime `setItems` still routes to NSToolbar until Task 5.)

- [ ] **Step 4: Commit**

```bash
git add native/platform/darwin/toolbar.m native/platform/darwin/window.m
git commit -m "feat(darwin): shared toolbar emit + SwiftUI toolbar reverse dispatcher + initial push (2b)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: router fork → full runtime toolbar on the SwiftUI path (GATE)

**Files:**
- Modify: `native/platform/darwin/window.m` (resolver)
- Modify: `native/nim/router.nim`

- [ ] **Step 1: window.m — the resolver**

```objc
// True when this window renders its toolbar via SwiftUI (toolbar.swift), so the
// router routes toolbar:* to the SwiftUI module instead of NSToolbar.
bool zapp_window_uses_swiftui_toolbar(void* handle) {
#ifdef ZAPP_HAS_SWIFTUI
    NSWindow* window = (__bridge NSWindow*)handle;
    ZappWindowDelegate* d = (ZappWindowDelegate*)[window delegate];
    if ([d isKindOfClass:[ZappWindowDelegate class]]) return d.swiftToolbarState != NULL;
#endif
    (void)handle; return false;
}
// Also expose the state handle for the router to push into:
void* zapp_window_swiftui_toolbar_state(void* handle) {
#ifdef ZAPP_HAS_SWIFTUI
    NSWindow* window = (__bridge NSWindow*)handle;
    ZappWindowDelegate* d = (ZappWindowDelegate*)[window delegate];
    if ([d isKindOfClass:[ZappWindowDelegate class]]) return d.swiftToolbarState;
#endif
    (void)handle; return NULL;
}
```

- [ ] **Step 2: router.nim — fork the `toolbar:*` arm**

Add the externs (near the other `darwin_*` importc decls in router.nim):

```nim
proc zapp_window_uses_swiftui_toolbar(handle: pointer): bool {.importc, cdecl.}
proc zapp_window_swiftui_toolbar_state(handle: pointer): pointer {.importc, cdecl.}
proc zapp_swift_module_set_string(state: pointer, key: int32, value: cstring) {.importc, cdecl.}
```

Replace the `toolbar:*` arm body (router.nim:611-619) so each op forks:

```nim
    let swiftTb = zapp_window_uses_swiftui_toolbar(h)
    let tbState = (if swiftTb: zapp_window_swiftui_toolbar_state(h) else: nil)
    case action
    of "toolbar:setItems":
      let tj = a{"toolbarJson"}.getStr("")
      if tj.len > 0:
        if swiftTb: zapp_swift_module_set_string(tbState, 1'i32, tj.cstring)   # ZAPP_TB_SET_ITEMS
        else: darwin_toolbar_set_items(h, tj.cstring, target)
    of "toolbar:updateItem":
      let ij = a{"itemJson"}.getStr("")
      if ij.len > 0:
        if swiftTb: zapp_swift_module_set_string(tbState, 2'i32, ij.cstring)   # ZAPP_TB_UPDATE_ITEM
        else: darwin_toolbar_update_item(h, ij.cstring)
    of "toolbar:remove":
      if swiftTb: zapp_swift_module_set_string(tbState, 3'i32, "".cstring)      # ZAPP_TB_CLEAR
      else: darwin_toolbar_remove(h)
    else: discard
    return
```

(The integer keys `1/2/3` match the `ZAPP_TB_*` enum in window.m + `kTb*` in toolbar.swift. Keep them in sync — they're the toolbar module's string-channel key namespace.)

- [ ] **Step 3: Build**

`cd kitchen-sink && bun run build 2>&1 | tail -3 ; cd ..` → `build complete`.

- [ ] **Step 4: GATE — human visual (PAUSE, `bun run dev`)**

Ask the user to run `bun run dev` and exercise the **Toolbar** section + the window's title-bar toolbar:
1. Config-declared + runtime `win.toolbar.setItems([...])` items **render in the SwiftUI title-bar toolbar**; `updateItem` (enabled/label/icon) reflects; custom button clicks fire their handlers (`window:toolbar-clicked` → action map); menu items work.
2. The **sidebar + inspector toggle items** drive the panes (animate); no duplicate auto sidebar toggle (suppressed).
3. **No flicker/vanish**; title bar / traffic lights / resize normal.
Then the user kills it.

- [ ] **Step 5: Commit**

```bash
git add native/platform/darwin/window.m native/nim/router.nim
git commit -m "feat(darwin): router toolbar:* fork → SwiftUI toolbar on the SwiftUI path (2b)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 6: chrome metrics + style + build matrix

**Files:**
- Modify: `native/platform/darwin/window.m` and/or `toolbar.swift` (chrome metrics, as the gate revealed)

- [ ] **Step 1: Chrome metrics on the SwiftUI toolbar path**

From Task 1/5's gate: if `--zapp-titlebar-height`/`--zapp-toolbar-height` are correct (SwiftUI-via-NSHostingController created an `NSToolbar` the existing KVO observes), do nothing here and note it. If they're wrong/missing, inject them for the SwiftUI path: after the panes register, measure the window's `frame` − `contentLayoutRect` (titlebar inset) and inject the two CSS vars into the panes via the existing `zapp_toolbar_inject_metrics` helper (or a small equivalent that doesn't require a `ZappToolbarController`). Reuse `zapp_toolbar_inject_metrics`'s injection JS shape. Keep it macOS-only + `#ifdef`-guarded.

- [ ] **Step 2: Opted-out build links clean with NO Swift toolbar**

Temporarily add `native: { swiftui: false },` to `kitchen-sink/zapp.config.ts`, then:
```bash
cd kitchen-sink && bun run build 2>&1 | tail -2
nm bin/kitchen-sink | grep -cE 'zapp_swift_(toolbar|module)'   # expect 0
cd ..
```
Expected: `build complete`; `0` (SwiftUI toolbar compiled out → AppKit `NSToolbar` path intact). Then **revert**: `git checkout kitchen-sink/zapp.config.ts`; confirm `git status --short kitchen-sink/zapp.config.ts` empty.

- [ ] **Step 3: iOS-sim builds + CLI tests**

```bash
cd kitchen-sink && bun run ../cli/src/zapp-cli.ts build --platform ios 2>&1 | tail -2 ; cd ..
bun test cli/src 2>&1 | tail -3
```
Expected: iOS `build complete` (toolbar.swift is macOS-target only via `resolveSwiftUIBuild`; no new iOS symbols); `bun test cli/src` all pass (no CLI surface changed).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(darwin): SwiftUI toolbar chrome metrics + build-matrix gates (2b)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 7: docs + final review

**Files:**
- Modify: `docs/native-ui-strategy.md`

- [ ] **Step 1: Docs**

In `docs/native-ui-strategy.md`: mark **Sub-cycle 2b (per-world toolbar) ✅ Done** in the roadmap (SwiftUI `.toolbar` via `NSHostingController` on the SwiftUI path / `NSToolbar` on AppKit, one app-facing spec). Update the toolbar-coexistence section + the Sub-cycle-1 toolbar-glitch limitation (now resolved). **Add a named "split-world AppKit/SwiftUI pattern" anchor**: one tech-agnostic app-facing spec → a per-backend native renderer chosen by a resolver fork, communicating over the generic key-routed bridge (scalar + string channels, `ZappNativeModule`), reversible by flipping the resolver default — the reusable template for future dual-rendered surfaces. Note 2c still owns presentation/width.

- [ ] **Step 2: Commit**

```bash
git add docs/native-ui-strategy.md
git commit -m "docs: native-ui-strategy — Sub-cycle 2b shipped + split-world pattern anchor

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 3: Final cross-cutting review (controller dispatches a reviewer)**

Confirm: (a) AppKit path unchanged (NSToolbar attaches + works when `swiftToolbarState==NULL`); (b) `ToolbarState` owned once by the delegate, released once at teardown (mirrors `swiftPaneState`); (c) every `zapp_swift_*` ref is `#ifdef ZAPP_HAS_SWIFTUI`-guarded (opted-out + iOS link clean); (d) the generic string channel (`zapp_swift_module_set_string` + `ZappSwiftStringCallback`) is module-agnostic + the toolbar key namespace matches across toolbar.swift/window.m/router.nim; (e) clicks route through the identical `window:toolbar-clicked`/`__menu:click` emit (no runtime/TS changes); (f) `NSHostingController` pivot didn't regress panes/webviews/2a-control. Record follow-ups in memory.

---

## Task 8 (PINNED, optional — only if the A renderer is stable): B-for-toggles exploration

**Files:** scratch only — do NOT commit behavior changes; capture findings.

- [ ] **Step 1:** In a throwaway diff, drop `.toolbar(removing: .sidebarToggle)` (let `NavigationSplitView` own the sidebar toggle) and remove the app's `toggleSidebar` item rendering. Build + observe: where does SwiftUI place its auto toggle, does it animate, does it conflict with the app's declared order?
- [ ] **Step 2:** Write a short findings note (append to `docs/native-ui-strategy.md` or a scratch doc) comparing A (faithful) vs B (SwiftUI-owned) toggle placement/behavior — info for a future A-vs-B decision. **Revert the throwaway diff.** No commit of behavior change.

---

## Self-Review (against the spec)

**Spec coverage:**
- Per-world fork (SwiftUI `.toolbar` / NSToolbar) behind one spec → Tasks 1-5. ✓
- Hosting pivot + risk gate → Task 1. ✓
- Generic bridge: string channel (`ZappSwiftStringCallback` + `zapp_swift_module_set_string` + `ZappNativeModule`) → Task 2; toolbar first consumer. ✓
- ToolbarState + `ZappToolbarContent` renderer (button/menu/enabled/indicator/spacers) → Tasks 2-3. ✓
- Strategy A toggles (app-declared, `.toolbar(removing:.sidebarToggle)`, bind PaneState) → Task 3. ✓
- Shared emit (`zapp_toolbar_emit_click`/`_menu_click`) → existing `window:toolbar-clicked`/`__menu:click` → Task 4; no runtime/TS changes. ✓
- window.m fork (NSHostingController, skip NSToolbar, create/own/register ToolbarState) → Tasks 1,3,4. ✓
- Router fork (`zapp_window_uses_swiftui_toolbar`) → Task 5. ✓
- chrome metrics/style/trackingSeparator → Tasks 3,6 (trackingSeparator = no-op, documented). ✓
- Build matrix (enabled/opted-out/iOS-sim/bun test) → Task 6. ✓
- Pinned B exploration → Task 8. ✓
- Docs + split-world anchor → Task 7. ✓
- Non-goals (iOS toolbar, #622 registration, #628 reorg, #627) → not tasked. ✓

**Placeholder scan:** Code steps carry full code; the IMPLEMENTER NOTE in Task 3 flags the SwiftUI `ToolbarContent` dynamic-items API as the human-visual-refined area (native UI, build+visual gate) — not a placeholder but an explicit known-fiddly. The `zapp_toolbar_emit_menu_click` body says "mirror menu.m's `__menu:click` emit exactly" rather than reproducing it — that's a precise cite of an exact existing pattern (read + match), consistent with the no-blind-copy guidance.

**Type/name consistency:** `zapp_swift_panes_create` grows to 5 args (`state, toolbarState, content, sidebar, inspector`) in Task 3 with the window.m extern+call updated same task. The toolbar key namespace (1=SET_ITEMS/CLICK, 2=UPDATE_ITEM/MENU_CLICK, 3=CLEAR) is consistent across `toolbar.swift` (`kTb*`), `window.m` (`ZAPP_TB_*`), `router.nim` (literals `1/2/3` with comments). `ZappSwiftStringCallback`, `ZappNativeModule`, `ToolbarState`, `swiftToolbarState`, `zapp_swift_module_set_string`, `zapp_window_uses_swiftui_toolbar`/`_swiftui_toolbar_state`, `zapp_toolbar_emit_click`/`_menu_click` are used consistently. The toolbar module's `ctx` = boxed numeric `host_slot` (documented in Task 4) — used by the dispatcher to emit. ✓
```
