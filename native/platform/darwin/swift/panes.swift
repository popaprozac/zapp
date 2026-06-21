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
  @ObservedObject var toolbar: ToolbarState

  var body: some View {
    rootView
      // Keep the outer suppression too (harmless); the effective one is on the
      // NavigationSplitView in rootView, where the auto toggle is generated.
      .toolbar(removing: .sidebarToggle)
      .toolbar { ZappToolbarContent(state: toolbar, pane: state) }
      .toolbarStyle(for: toolbar.style)
  }

  @ViewBuilder private var rootView: some View {
    if let sidebar {
      NavigationSplitView(columnVisibility: sidebarVisibilityBinding) {
        PaneHost(view: sidebar).ignoresSafeArea()
          // Bound the sidebar drag so it can't run away past the window
          // (runaway-resize observed at the Task-1 gate). Full width control is 2c.
          .navigationSplitViewColumnWidth(min: 180, ideal: 260, max: 480)
      } detail: {
        detail
      }
      // Tiling vs overlay is Sub-cycle 2c; keep the Sub-cycle-1 style.
      .navigationSplitViewStyle(.balanced)
      // Suppress SwiftUI's auto sidebar toggle HERE (Strategy A) — the
      // NavigationSplitView is the navigation context that generates it; the
      // outer `.toolbar(removing:)` on `body` alone did not suppress it (Task 1).
      .toolbar(removing: .sidebarToggle)
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
