## Platform boot bindings. The ObjC lives in native/platform/darwin/*.m,
## reused untouched; we only bind the plain-C entry points.
import std/os

{.passC: "-I " & currentSourcePath().parentDir & "/../platform/darwin".}

proc darwin_platform_init(appName: cstring) {.importc, cdecl.}
proc darwin_platform_run(terminateAfterLastWindow: bool): cint {.importc, cdecl.}

proc platformInit*(name: string) = darwin_platform_init(name.cstring)
proc platformRun*(terminateAfterLastWindow: bool): int =
  darwin_platform_run(terminateAfterLastWindow).int
