## The ONE safe native->JS literal encoder (native/shared/jslit.c). Every path
## that embeds data into a JS string routes through this — see the lint guard.
##
## {.compile.} lives HERE, and ONLY here (not also in zapp.nim's real-build
## wiring), so every module that `import jslit` — main-thread Nim callers AND
## the standalone native/nim/tests/*_test.nim binaries that link a module
## transitively — gets jslit.c compiled in automatically, without needing its
## own copy of the pragma. Task 1 originally put an identical
## {.compile("../shared/jslit.c", "").} in zapp.nim, before any Nim module
## imported this one; Task 2 REMOVED that copy when adding this one, because
## Nim 2.2.10 does NOT dedupe {.compile.} by the C file's resolved path across
## two modules — confirmed empirically: with the pragma in both zapp.nim and
## here, the real `zapp build` failed at link time with "duplicate symbol
## '_zapp_js_lit_dup'". Do not reintroduce a second {.compile.} for this file
## anywhere else in native/nim/ (native/nim/tests/jslit_test.nim's own copy is
## fine — it is a fully standalone, single-file test binary that never imports
## this module).
{.compile("../shared/jslit.c", "").}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>", cdecl.}
proc zapp_js_lit_dup*(utf8: cstring): cstring {.importc, cdecl.}
  ## Complete double-quoted JS string literal; caller frees. Worker-pthread
  ## paths call this DIRECTLY (libc/gcsafe). NULL only on malloc failure.

proc jsLit*(s: string): string =
  ## Main-thread convenience wrapper — calls the ONE C encoder, no reimplementation.
  let c = zapp_js_lit_dup(s.cstring)
  if c == nil: return "\"\""          # OOM -> empty literal (still safe, never raw)
  result = $c
  c_free(c)
