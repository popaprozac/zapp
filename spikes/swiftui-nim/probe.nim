## SwiftUI → Nim interop spike harness.
## Gate 1: call the Swift @_cdecl bridge via importc.
proc zappSwiftProbe(): cstring {.importc: "zapp_swift_probe", cdecl.}
proc zappSwiftAdd(a, b: int32): int32 {.importc: "zapp_swift_add", cdecl.}

let msg = zappSwiftProbe()
echo "swift says: ", (if msg.isNil: "<nil>" else: $msg)
echo "2 + 3 = ", zappSwiftAdd(2, 3)
