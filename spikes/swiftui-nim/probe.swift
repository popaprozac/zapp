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
