// SwiftUI → Nim interop spike — Swift side.
// Gate 1: pure-Swift @_cdecl bridge (no SwiftUI/AppKit yet) — isolates the
// "does the Swift runtime link into a nim/clang binary" question.
import Foundation

@_cdecl("zapp_swift_probe")
public func zapp_swift_probe() -> UnsafePointer<CChar>? {
  // strdup so the returned pointer outlives this call (Nim reads it; we leak
  // the few bytes — fine for a probe). Proves a Swift-built String crosses
  // the C ABI back to Nim.
  return UnsafePointer(strdup("hello from Swift 6.3"))
}

@_cdecl("zapp_swift_add")
public func zapp_swift_add(_ a: Int32, _ b: Int32) -> Int32 {
  return a + b
}

// Gate 2: a real SwiftUI view, hosted in an NSWindow, created + shown from a
// @_cdecl entry called by Nim. Proves SwiftUI itself works through the bridge.
import SwiftUI
import AppKit

struct ProbeView: View {
  var body: some View {
    VStack(spacing: 12) {
      Text("Hello from SwiftUI").font(.largeTitle)
      Text("driven from Nim via @_cdecl").foregroundStyle(.secondary)
    }
    .padding(40)
    .frame(width: 360, height: 200)
  }
}

@_cdecl("zapp_swift_show_window")
public func zapp_swift_show_window() {
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  let win = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
    styleMask: [.titled, .closable],
    backing: .buffered, defer: false)
  win.title = "Zapp SwiftUI Spike"
  win.contentView = NSHostingView(rootView: ProbeView())
  win.center()
  win.makeKeyAndOrderFront(nil)
  app.activate(ignoringOtherApps: true)
  app.run()  // blocks — the harness's Swift side owns the run loop
}
