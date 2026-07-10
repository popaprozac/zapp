## Native C-ABI seam — the single place the platform prefix is decided.
##
## The Nim layer calls into per-platform native code (darwin/*.m, ios/*.m,
## windows/*.c) by C symbol name. Each platform exports the SAME suffix under a
## platform prefix: `darwin_window_show` (macOS/iOS) vs `windows_window_show`.
## Rather than hard-code `darwin_` in shared Nim (the Zen-C-era wart, where the
## *portable* interface was misleadingly named "darwin"), every `importc`
## derives its C symbol from `abiPrefix`:
##
##   proc windowShow(h: pointer) {.importc: abiPrefix & "window_show", cdecl.}
##
## → binds `darwin_window_show` on Apple, `windows_window_show` on Windows, chosen
## at compile time by `-d:zappWindows` (set by nimDefinesForTarget for the windows
## target). Apple codegen is unchanged (the default prefix is still `darwin_`),
## so this seam is behaviour-preserving for the shipping macOS/iOS builds.
##
## Platform-specific entry points that exist on only one side stay behind a
## `when defined(zappWindows)` / `else` guard at their call site.

const abiPrefix* = when defined(zappWindows): "windows_" else: "darwin_"
