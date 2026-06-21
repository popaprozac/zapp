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
