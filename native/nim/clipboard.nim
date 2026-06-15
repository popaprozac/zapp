## Clipboard — ports native/clipboard/clipboard.zc.
##
## The zc version wrapped each `darwin_clipboard_read_*` call in a `raw{}` block
## and parked the malloc'd C buffer in a function-`static char*` slot, freeing
## the *previous* call's buffer on the next call, so the returned zc `string`
## (a borrowed pointer) stayed valid for the caller. In Nim that whole hack
## collapses: assigning a `cstring` into a `string` COPIES the bytes, so we can
## free the C buffer immediately — no static slot, no `raw{}`, no Foundation.
##
## The ObjC backing (`native/platform/darwin/clipboard.m`, reused UNTOUCHED) is
## compiled in here with the same `-fobjc-arc` flag the other platform .m files
## use in zapp.nim, keeping this module self-contained: it owns both the C-ABI
## declarations and the compilation of their definitions. Ownership per
## clipboard.h: `darwin_clipboard_read_*` return a malloc'd C string the caller
## must free; `read_files` returns a JSON array string ("[]" when none).
##
## Image methods (`__clipboard:readImagePng` / `writeImagePng`) are out of scope
## for the walking skeleton (deferred to breadth) and intentionally absent.

{.compile("../platform/darwin/clipboard.m", "-fobjc-arc").}

proc darwin_clipboard_read_text(): cstring {.importc, cdecl.}
proc darwin_clipboard_write_text(s: cstring): bool {.importc, cdecl.}
proc darwin_clipboard_read_html(): cstring {.importc, cdecl.}
proc darwin_clipboard_write_html(s: cstring): bool {.importc, cdecl.}
proc darwin_clipboard_read_files(): cstring {.importc, cdecl.}
proc darwin_clipboard_has(fmt: cstring): bool {.importc, cdecl.}
proc darwin_clipboard_clear() {.importc, cdecl.}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc takeCString(p: cstring): string =
  ## Copy a malloc'd C string into a Nim string, then free the C buffer.
  ## NULL => "". The `$p` conversion copies the bytes before we free, so the
  ## returned Nim string owns its own memory (no use-after-free, no leak).
  if p.isNil:
    result = ""
  else:
    result = $p
    c_free(cast[pointer](p))

proc readText*(): string = takeCString(darwin_clipboard_read_text())
proc writeText*(s: string): bool = darwin_clipboard_write_text(s.cstring)
proc readHtml*(): string = takeCString(darwin_clipboard_read_html())
proc writeHtml*(s: string): bool = darwin_clipboard_write_html(s.cstring)

proc readFiles*(): string =
  ## Returns a JSON array of absolute path strings; "[]" when none.
  let s = takeCString(darwin_clipboard_read_files())
  if s.len == 0: "[]" else: s

proc has*(fmt: string): bool = darwin_clipboard_has(fmt.cstring)
proc clear*() = darwin_clipboard_clear()
