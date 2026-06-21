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

@available(macOS 14.0, *)
struct PaneLayout: View {
  let content: NSView
  let sidebar: NSView?
  let inspector: NSView?
  @State private var showInspector: Bool

  init(content: NSView, sidebar: NSView?, inspector: NSView?, showInspector: Bool) {
    self.content = content; self.sidebar = sidebar; self.inspector = inspector
    _showInspector = State(initialValue: showInspector)
  }

  var body: some View {
    if let sidebar {
      NavigationSplitView {
        PaneHost(view: sidebar).ignoresSafeArea()
      } detail: {
        detail
      }
      // Tile the columns (push content) instead of overlaying — matches the
      // prior AppKit NSSplitViewItem sidebar behavior on macOS.
      .navigationSplitViewStyle(.balanced)
    } else {
      detail
    }
  }

  @ViewBuilder private var detail: some View {
    PaneHost(view: content)
      .ignoresSafeArea()
      .inspector(isPresented: $showInspector) {
        if let inspector { PaneHost(view: inspector).ignoresSafeArea() }
      }
  }
}

// Returns a +1-retained NSHostingView; ObjC consumes it with __bridge_transfer.
// `content` is an NSView* passed from ObjC (the populated content container).
@_cdecl("zapp_swift_panes_create")
public func zapp_swift_panes_create(_ content: UnsafeMutableRawPointer,
                                    _ sidebar: UnsafeMutableRawPointer?,
                                    _ inspector: UnsafeMutableRawPointer?,
                                    _ showInspector: Bool) -> UnsafeMutableRawPointer? {
  guard #available(macOS 14.0, *) else { return nil }
  let c = Unmanaged<NSView>.fromOpaque(content).takeUnretainedValue()
  let s = sidebar.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
  let i = inspector.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
  let host = NSHostingView(rootView: PaneLayout(content: c, sidebar: s, inspector: i, showInspector: showInspector))
  return Unmanaged.passRetained(host).toOpaque()
}
