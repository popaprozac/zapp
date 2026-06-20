## SwiftUI → Nim interop spike harness.
## Gate 2: Nim drives a SwiftUI window via the Swift @_cdecl entry.
proc zappSwiftProbe(): cstring {.importc: "zapp_swift_probe", cdecl.}
proc zappSwiftAdd(a, b: int32): int32 {.importc: "zapp_swift_add", cdecl.}
proc zappSwiftShowWindow() {.importc: "zapp_swift_show_window", cdecl.}

let msg = zappSwiftProbe()
echo "swift says: ", (if msg.isNil: "<nil>" else: $msg)
echo "2 + 3 = ", zappSwiftAdd(2, 3)
echo "opening SwiftUI window (close it to exit)…"
zappSwiftShowWindow()  # blocks in the AppKit run loop
