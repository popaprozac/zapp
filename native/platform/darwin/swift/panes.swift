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
  // Live inspector geometry (was absent — inspector width lived only in inspector.m).
  @Published var inspectorWidth: CGFloat
  @Published var inspectorResizable: Bool
  @Published var inspectorCollapsible: Bool

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
  // Last rendered pane width (plain vars). The lock-at-current baseline for
  // setResizable(false). Deliberately NOT @Published and NOT written into
  // sidebarWidth/inspectorWidth — the modifier's source of truth is owned by
  // setWidth. Mixing them let the geometry observer revert a programmatic setWidth
  // (the #660 retest bug: width buttons had no effect).
  var lastSidebarRendered: CGFloat = 0
  var lastInspectorRendered: CGFloat = 0

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
    lastSidebarRendered = w
    // Track the rendered width so a later relayout re-applies the CURRENT width (not a stale
    // ideal) and setResizable(false) locks at the right place. (Width is SET imperatively via
    // the reach-through setPosition; this only mirrors the result into the @Published source.)
    if iw != Int(sidebarWidth.rounded()) { sidebarWidth = CGFloat(iw) }
    if iw != lastSidebarWidthEmitted { lastSidebarWidthEmitted = iw; cb?(ctx, kPaneKeySidebarWidth, Int64(iw)) }
  }
  func noteInspectorWidth(_ w: CGFloat) {
    let iw = Int(w.rounded())
    if iw <= 0 { return }
    lastInspectorRendered = w
    if iw != Int(inspectorWidth.rounded()) { inspectorWidth = CGFloat(iw) }
    if iw != lastInspectorWidthEmitted { lastInspectorWidthEmitted = iw; cb?(ctx, kPaneKeyInspectorWidth, Int64(iw)) }
  }
}

// Always the min:ideal:max: form; "locked" collapses the range to min==max==width
// (non-draggable). Reading the @Published fields here (from PaneLayout.body) registers
// the SwiftUI dependency so relayouts re-apply current values.
@available(macOS 14.0, *)
extension View {
  func paneSidebarWidth(_ s: PaneState) -> some View {
    let locked = !s.sidebarResizable
    return navigationSplitViewColumnWidth(
      min: locked ? s.sidebarWidth : s.sidebarMinW,
      ideal: s.sidebarWidth,
      max: locked ? s.sidebarWidth : s.sidebarMaxW)
  }
  func paneInspectorWidth(_ s: PaneState) -> some View {
    let locked = !s.inspectorResizable
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
          .paneSidebarWidth(state)
          .background(WidthReader { w in state.noteSidebarWidth(w) })
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
          PaneHost(view: inspector)
            .ignoresSafeArea(.container, edges: state.bleedTop ? .top : [])
            .paneInspectorWidth(state)
            .background(WidthReader { w in state.noteInspectorWidth(w) })
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
      set: { newValue in
        // Non-collapsible: refuse user-driven hide (the toolbar toggle / divider can't
        // collapse it). Programmatic show/hide still goes through PaneState directly.
        if !state.sidebarCollapsible && newValue == .detailOnly { return }
        state.sidebarVisible = (newValue != .detailOnly)
      }
    )
  }
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
}

// --- @_cdecl entries ---------------------------------------------------------

// Create the shared state (+1 retained; ObjC owns it, releases via _state_release).
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

// --- #660 runtime geometry setters (callers in sidebar.m / inspector.m run on main) ---

// NOTE: there is no zapp_swift_panes_set_sidebar_width — runtime setWidth is imperative
// (darwin_sidebar_set_width → setPosition reach-through). SwiftUI's column-width modifier
// is initial-only at runtime, so a declarative width setter has no effect (#660 finding).

@_cdecl("zapp_swift_panes_set_sidebar_resizable")
public func zapp_swift_panes_set_sidebar_resizable(_ state: UnsafeMutableRawPointer, _ resizable: Bool) {
  let st = Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue()
  // Lock at the CURRENT rendered width (AppKit parity), not a stale programmatic value —
  // WidthReader no longer writes sidebarWidth, so capture the live width here.
  if !resizable && st.lastSidebarRendered > 0 { st.sidebarWidth = st.lastSidebarRendered }
  st.sidebarResizable = resizable
}

@_cdecl("zapp_swift_panes_set_sidebar_collapsible")
public func zapp_swift_panes_set_sidebar_collapsible(_ state: UnsafeMutableRawPointer, _ collapsible: Bool) {
  Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue().sidebarCollapsible = collapsible
}

// (no zapp_swift_panes_set_inspector_width — width is imperative; see the sidebar note.)

@_cdecl("zapp_swift_panes_set_inspector_resizable")
public func zapp_swift_panes_set_inspector_resizable(_ state: UnsafeMutableRawPointer, _ resizable: Bool) {
  let st = Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue()
  if !resizable && st.lastInspectorRendered > 0 { st.inspectorWidth = st.lastInspectorRendered }
  st.inspectorResizable = resizable
}

@_cdecl("zapp_swift_panes_set_inspector_collapsible")
public func zapp_swift_panes_set_inspector_collapsible(_ state: UnsafeMutableRawPointer, _ collapsible: Bool) {
  Unmanaged<PaneState>.fromOpaque(state).takeUnretainedValue().inspectorCollapsible = collapsible
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
