## The ONE safe native->JS literal encoder (native/shared/jslit.c). Every path
## that embeds data into a JS string routes through this — see the lint guard.
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
