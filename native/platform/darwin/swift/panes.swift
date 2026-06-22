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
  // 2c: bleed pane content up under the titlebar (full-height look) ONLY when the
  // window has transparent/hidden chrome (titleBarStyle hidden/hiddenInset). For a
  // standard `default` titlebar the panes respect the safe area (content below the
  // title bar) — keeps AppKit/SwiftUI parity per resolved titlebar style.
  let bleedTop: Bool

  init(ctx: UnsafeMutableRawPointer?, cb: ZappSwiftStateCallback?,
       sidebarVisible: Bool, inspectorPresented: Bool, bleedTop: Bool) {
    self.ctx = ctx; self.cb = cb
    self.sidebarVisible = sidebarVisible
    self.inspectorPresented = inspectorPresented
    self.bleedTop = bleedTop
  }
}

@available(macOS 14.0, *)
struct PaneLayout: View {
  let content: NSView
  let sidebar: NSView?
  let inspector: NSView?
  @ObservedObject var state: PaneState
  @ObservedObject var toolbar: ToolbarState

  var body: some View {
    // NOTE: the content `.toolbar { ZappToolbarContent }` lives on `detail` (inside
    // the NavigationSplitView), NOT here. A body-level `.toolbar` (outside the
    // NavigationSplitView) re-introduces the navigation toolbar context and
    // resurrects SwiftUI's auto sidebar toggle, defeating `.toolbar(removing:)`.
    rootView
      .toolbarStyle(for: toolbar.style)
  }

  @ViewBuilder private var rootView: some View {
    if let sidebar {
      NavigationSplitView(columnVisibility: sidebarVisibilityBinding) {
        // 2c TILING FIX: never use ALL-edges .ignoresSafeArea() on a pane — that flips
        // the whole NavigationSplitView into floating-overlay. A SCOPED top-only
        // container ignore keeps the column tiled AND lets content bleed under the
        // titlebar — but ONLY for transparent/hidden chrome (bleedTop); a `default`
        // titlebar gets an empty edge set (= no-op) so content sits below the bar.
        PaneHost(view: sidebar)
          .ignoresSafeArea(.container, edges: state.bleedTop ? .top : [])
          .navigationSplitViewColumnWidth(min: 180, ideal: 260, max: 480)
      } detail: {
        detail
      }
      // Tiling vs overlay is Sub-cycle 2c; keep the Sub-cycle-1 style.
      .navigationSplitViewStyle(.balanced)
      // We KEEP SwiftUI's native auto sidebar toggle (no `.toolbar(removing:)`):
      // `.toolbar(removing:)` doesn't take across the AppKit↔SwiftUI hosting seam
      // (it leaked a duplicate), and the native toggle drives this column's
      // visibility (bound to PaneState) directly — so the app's `toggleSidebar`
      // item is satisfied by it (we don't render our own; see toolbar.swift).
    } else {
      detail
    }
  }

  @ViewBuilder private var detail: some View {
    // 2c: scoped top-only safe-area ignore so content bleeds under the titlebar with
    // transparent/hidden chrome, while the panes stay tiled (all-edges ignore would
    // flip the whole NavigationSplitView into floating-overlay). Gated on bleedTop so
    // a `default` titlebar keeps content below the bar (AppKit/SwiftUI parity).
    PaneHost(view: content)
      .ignoresSafeArea(.container, edges: state.bleedTop ? .top : [])
      .inspector(isPresented: inspectorPresentedBinding) {
        if let inspector {
          PaneHost(view: inspector).ignoresSafeArea(.container, edges: state.bleedTop ? .top : [])
        }
      }
      // Toolbar on the DETAIL (matching the proven spike): it must live inside
      // the NavigationSplitView's content context, NOT on the body (a body-level
      // `.toolbar` re-introduces the navigation toolbar context — see the body
      // comment above). We do NOT use `.toolbar(removing: .sidebarToggle)`: it
      // doesn't take across the hosting seam, and we intentionally KEEP SwiftUI's
      // native auto sidebar toggle (see the `rootView` comment above).
      .toolbar { ZappToolbarContent(state: toolbar, pane: state) }
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
                                          _ inspectorPresented: Bool,
                                          _ bleedTop: Bool) -> UnsafeMutableRawPointer? {
  let state = PaneState(ctx: ctx, cb: cb,
                        sidebarVisible: sidebarVisible, inspectorPresented: inspectorPresented,
                        bleedTop: bleedTop)
  return Unmanaged.passRetained(state).toOpaque()
}

@_cdecl("zapp_swift_panes_state_release")
public func zapp_swift_panes_state_release(_ state: UnsafeMutableRawPointer) {
  Unmanaged<PaneState>.fromOpaque(state).release()
}

@_cdecl("zapp_swift_panes_set_sidebar_visible")
public func zapp_swift_panes_set_sidebar_visible(_ state: UnsafeMutableRawPointer, _ visible: Bool) {
  withAnimation { Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue().sidebarVisible = visible }
}

@_cdecl("zapp_swift_panes_set_inspector_presented")
public func zapp_swift_panes_set_inspector_presented(_ state: UnsafeMutableRawPointer, _ presented: Bool) {
  withAnimation { Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue().inspectorPresented = presented }
}

@_cdecl("zapp_swift_panes_toggle_sidebar")
public func zapp_swift_panes_toggle_sidebar(_ state: UnsafeMutableRawPointer) {
  withAnimation { Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue().sidebarVisible.toggle() }
}

@_cdecl("zapp_swift_panes_toggle_inspector")
public func zapp_swift_panes_toggle_inspector(_ state: UnsafeMutableRawPointer) {
  withAnimation { Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue().inspectorPresented.toggle() }
}

// Build the hosting controller. `state` carries initial visibility; the old
// showInspector Bool param is gone. Returns a +1-retained NSHostingController;
// ObjC consumes it with __bridge_transfer NSViewController*. Hosting via an
// NSHostingController (set as window.contentViewController) — not a bare
// NSHostingView — is what lets SwiftUI `.toolbar` bridge into the NSWindow
// title bar (Sub-cycle 2b risk gate).
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
  // Don't let the hosting controller drive the window's size from the SwiftUI
  // content's ideal size — the window keeps its configured frame; the view fills it.
  // (Default sizingOptions would collapse the window to a tiny strip before the
  //  webviews lay out.)
  if #available(macOS 13.0, *) { hc.sizingOptions = [] }
  return Unmanaged.passRetained(hc).toOpaque()   // +1; ObjC consumes via __bridge_transfer NSViewController*
}
