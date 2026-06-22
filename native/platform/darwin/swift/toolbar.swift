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
  let checked: Bool?   // moving checkmark (e.g. the Mail filter pull-down)
  enum CodingKeys: String, CodingKey { case dynId = "id", label, icon, checked }
}

struct ZappToolbarItem: Decodable, Identifiable {
  let id: String          // synthesized for spacer/separator (no app id)
  let type: String        // button | toggleSidebar | toggleInspector | trackingSeparator | space | flexibleSpace
  // var (not let): updateItem merges a partial patch into the existing item.
  var label: String?
  var icon: String?
  var enabled: Bool?
  var indicator: Bool?
  var menu: [ZappMenuItem]?

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
      // MERGE the patch into the existing item (the wire carries only the changed
      // fields, e.g. `{id, menu}` — matching AppKit's darwin_toolbar_update_item).
      // A whole-item replace dropped the unspecified fields (e.g. the icon → the
      // button fell back to a circle glyph).
      if let data = value.data(using: .utf8),
         let patch = try? JSONDecoder().decode(ZappToolbarItem.self, from: data),
         let idx = items.firstIndex(where: { $0.id == patch.id }) {
        var merged = items[idx]
        if patch.label != nil { merged.label = patch.label }
        if patch.icon != nil { merged.icon = patch.icon }
        if patch.enabled != nil { merged.enabled = patch.enabled }
        if patch.indicator != nil { merged.indicator = patch.indicator }
        if patch.menu != nil { merged.menu = patch.menu }
        items[idx] = merged
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

// --- SwiftUI renderer --------------------------------------------------------
// Renders the live ToolbarState into the NSWindow title bar via SwiftUI's
// `.toolbar`. Items render as two `ToolbarItemGroup`s split at the first
// `flexibleSpace`: items before it → leading (`.navigation`); items after it →
// trailing (`.primaryAction`). Each group is a `ForEach` over the stable-`id`
// `ZappToolbarItem` array — the spike-proven shape that survives NavigationSplit-
// View re-layout AND dynamic setItems/updateItem/remove without dropping items
// (the failure mode of the earlier single-ToolbarItem-HStack / bare-ForEach
// attempts). `trackingSeparator` and `space` are dropped — they have no SwiftUI
// toolbar equivalent and NavigationSplitView aligns the columns itself.
// Toggle items bind directly to PaneState visibility (the app authors the
// toggles; SwiftUI's auto sidebar toggle is suppressed in panes.swift); all
// other items round-trip clicks back to native via emitClick.
@available(macOS 14.0, *)
struct ZappToolbarContent: ToolbarContent {
  @ObservedObject var state: ToolbarState   // observe directly so item mutations re-render the toolbar (spike pattern)
  let pane: PaneState   // toggles bind directly to pane visibility (2a)

  // Items split at the first `flexibleSpace`: before → leading (.navigation, above
  // the sidebar column), after → trailing (.primaryAction, above the detail). This
  // is the SwiftUI-native equivalent of the AppKit flexibleSpace + trackingSeparator
  // (placement auto-aligns the toolbar boundary to the column split — no explicit
  // separator item needed). Filtered out of both sides:
  //   • space / flexibleSpace / trackingSeparator → no SwiftUI item; the split itself
  //     carries the alignment intent.
  //   • toggleSidebar → SwiftUI's *native* auto sidebar toggle (NOT suppressed —
  //     `.toolbar(removing:)` doesn't take across the hosting seam) sits leading and
  //     drives the NavigationSplitView column (bound to PaneState), so it toggles +
  //     syncs natively. We don't render our own.
  // NOTE: .navigation placement was unstable (items shifted on sidebar collapse)
  // UNTIL NSWindowStyleMaskFullSizeContentView landed on the SwiftUI pane window
  // (window.m) — that stabilized the toolbar, which is what makes this split viable.
  private var groups: (leading: [ZappToolbarItem], trailing: [ZappToolbarItem]) {
    func renderable(_ items: ArraySlice<ZappToolbarItem>) -> [ZappToolbarItem] {
      items.filter {
        $0.type != "space" && $0.type != "flexibleSpace"
          && $0.type != "trackingSeparator" && $0.type != "toggleSidebar"
      }
    }
    if let split = state.items.firstIndex(where: { $0.type == "flexibleSpace" }) {
      return (renderable(state.items[..<split]), renderable(state.items[(split + 1)...]))
    }
    return (renderable(state.items[...]), [])
  }

  var body: some ToolbarContent {
    let g = groups
    if !g.leading.isEmpty {
      ToolbarItemGroup(placement: .navigation) {
        ForEach(g.leading) { item in itemView(item) }
      }
    }
    if !g.trailing.isEmpty {
      ToolbarItemGroup(placement: .primaryAction) {
        ForEach(g.trailing) { item in itemView(item) }
      }
    }
  }

  @ViewBuilder private func itemView(_ item: ZappToolbarItem) -> some View {
    switch item.type {
    // toggleSidebar is filtered out in `groups` — SwiftUI's native auto toggle
    // handles it (see the `groups` comment). Only toggleInspector + buttons here.
    case "toggleInspector":
      Button { withAnimation { pane.inspectorPresented.toggle() } } label: { glyph(item, fallback: "sidebar.right") }
    default: // "button"
      if let menu = item.menu, !menu.isEmpty {
        Menu {
          ForEach(menu) { m in
            Button { state.emitMenuClick(m.id) } label: {
              // Render the moving checkmark (AppKit shows it via NSMenuItem.state).
              if m.checked == true { Label(m.label ?? m.id, systemImage: "checkmark") }
              else { Text(m.label ?? m.id) }
            }
          }
        }
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

// Maps the app's toolbar `style` string onto SwiftUI's `.toolbar(style:)`.
// DEVIATION (Task 6 follow-up): `.toolbar(style:)` on a hosted view did NOT
// resolve against the installed SDK — the compiler bound `self.toolbar(...)` to
// the `ToolbarItem` overload (extra argument 'style' / cannot infer base
// 'unifiedCompact'). Per the task's drop-if-it-won't-compile guidance, this is a
// no-op passthrough for now; toolbar style is cosmetic. The `style` field still
// flows through ToolbarState for when this is re-attempted.
@available(macOS 14.0, *)
extension View {
  @ViewBuilder func toolbarStyle(for style: String) -> some View { self }
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
