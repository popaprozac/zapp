## Platform boot bindings. The ObjC lives in native/platform/darwin/*.m,
## reused untouched; we only bind the plain-C entry points.
import std/os
import nativeabi

{.passC: "-I " & currentSourcePath().parentDir & "/../platform/darwin".}

proc nativePlatformInit(appName: cstring) {.importc: abiPrefix & "platform_init", cdecl.}
proc nativePlatformRun(terminateAfterLastWindow: bool): cint {.importc: abiPrefix & "platform_run", cdecl.}

proc platformInit*(name: string) = nativePlatformInit(name.cstring)
proc platformRun*(terminateAfterLastWindow: bool): int =
  nativePlatformRun(terminateAfterLastWindow).int
