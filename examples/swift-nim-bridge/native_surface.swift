// Framework-authored SwiftUI backing for Zapp's generic "native surface".
// Exposed to the ObjC resolver (nativesurface.m) via a plain C ABI (@_cdecl),
// exactly like the proven spike (spikes/swiftui-nim). The resolver decides
// SwiftUI-vs-AppKit; this file is only reached when SwiftUI is the choice.
import SwiftUI
import AppKit

// C callback the demonstrative control invokes to round-trip a value into Nim.
// (window_id, value) — value is a borrowed C string valid for the call only.
public typealias ZappSurfaceCallback = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

@available(macOS 10.15, *)
struct ZappNativeSurfaceView: View {
    let windowId: Int32
    let callback: ZappSurfaceCallback?
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 12) {
            Text("SwiftUI native surface")
                .font(.headline)
            Text("taps: \(taps)")
                .foregroundColor(.secondary)
            Button("Ping Nim") {
                taps += 1
                "swiftui:\(taps)".withCString { callback?(windowId, $0) }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Returns a retained NSView* (NSHostingView). The ObjC side owns it.
// nil if SwiftUI's floor isn't met at runtime (defensive; the resolver also checks).
@_cdecl("zapp_swift_native_surface_create")
public func zapp_swift_native_surface_create(_ windowId: Int32,
                                             _ callback: ZappSurfaceCallback?) -> UnsafeMutableRawPointer? {
    guard #available(macOS 10.15, *) else { return nil }
    let host = NSHostingView(rootView: ZappNativeSurfaceView(windowId: windowId, callback: callback))
    // Hand off a +1 reference to ObjC (which does CFBridgingRelease / __bridge_transfer).
    return Unmanaged.passRetained(host).toOpaque()
}
