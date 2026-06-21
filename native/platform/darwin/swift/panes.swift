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
  var body: some View {
    PaneHost(view: content).ignoresSafeArea()
  }
}

// Returns a +1-retained NSHostingView; ObjC consumes it with __bridge_transfer.
// `content` is an NSView* passed from ObjC (the populated content container).
@_cdecl("zapp_swift_panes_create")
public func zapp_swift_panes_create(_ content: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
  guard #available(macOS 14.0, *) else { return nil }
  let contentView = Unmanaged<NSView>.fromOpaque(content).takeUnretainedValue()
  let host = NSHostingView(rootView: PaneLayout(content: contentView))
  return Unmanaged.passRetained(host).toOpaque()
}
