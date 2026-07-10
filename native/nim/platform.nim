## Platform boot bindings. The ObjC lives in native/platform/darwin/*.m,
## reused untouched; we only bind the plain-C entry points.
import std/os
import nativeabi

# darwin platform headers (darwin_* prototypes) — Apple only. On Windows the
# windows_* prototypes come from native/platform/windows/*.h (pulled in by the
# .c sources themselves); adding the darwin include there would be wrong.
when not defined(zappWindows):
  {.passC: "-I " & currentSourcePath().parentDir & "/../platform/darwin".}

proc nativePlatformInit(appName: cstring) {.importc: abiPrefix & "platform_init", cdecl.}
proc nativePlatformRun(terminateAfterLastWindow: bool): cint {.importc: abiPrefix & "platform_run", cdecl.}

proc platformInit*(name: string) = nativePlatformInit(name.cstring)
proc platformRun*(terminateAfterLastWindow: bool): int =
  nativePlatformRun(terminateAfterLastWindow).int
