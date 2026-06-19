## Clipboard — ports native/clipboard/clipboard.zc.
##
## The zc version wrapped each `darwin_clipboard_read_*` call in a `raw{}` block
## and parked the malloc'd C buffer in a function-`static char*` slot, freeing
## the *previous* call's buffer on the next call, so the returned zc `string`
## (a borrowed pointer) stayed valid for the caller. In Nim that whole hack
## collapses: assigning a `cstring` into a `string` COPIES the bytes, so we can
## free the C buffer immediately — no static slot, no `raw{}`, no Foundation.
##
## The ObjC backing is the TARGET-CORRECT clipboard.m — darwin/clipboard.m
## (AppKit/NSPasteboard) on macOS, ios/clipboard.m (UIPasteboard) on iOS. Its
## `{.compile.}` is owned by the CLI-generated `.zapp/zapp_platform.nim` (via
## getPlatformSources), NOT this module: compiling darwin/clipboard.m here
## unconditionally pulled AppKit into the UIKit iOS target and broke the link.
## This module owns only the C-ABI `importc` declarations + the Nim wrappers.
## Ownership per clipboard.h: `darwin_clipboard_read_*` return a malloc'd C
## string the caller must free; `read_files` returns a JSON array string ("[]"
## when none).
##
## Image bytes (`readImagePng` / `writeImagePng`) cross the JSON-only bridge as
## base64; clipboard.m encodes/decodes server-side via the `*_b64` helpers so
## this module needs no Foundation. `read_image_png_b64` returns a malloc'd
## base64 C string (NULL when no image) — same caller-frees contract as the
## other reads.

proc darwin_clipboard_read_text(): cstring {.importc, cdecl.}
proc darwin_clipboard_write_text(s: cstring): bool {.importc, cdecl.}
proc darwin_clipboard_read_html(): cstring {.importc, cdecl.}
proc darwin_clipboard_write_html(s: cstring): bool {.importc, cdecl.}
proc darwin_clipboard_read_files(): cstring {.importc, cdecl.}
proc darwin_clipboard_read_image_png_b64(): cstring {.importc, cdecl.}
proc darwin_clipboard_write_image_png_b64(b64: cstring): bool {.importc, cdecl.}
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

proc readImagePngB64*(): string =
  ## Base64 PNG of the clipboard image; "" when no image present. clipboard.m
  ## does the PNG->base64 encode so the bridge stays JSON-only.
  takeCString(darwin_clipboard_read_image_png_b64())

proc writeImagePngB64*(b64: string): bool =
  ## Decode the base64 PNG and place it on the clipboard.
  darwin_clipboard_write_image_png_b64(b64.cstring)

proc has*(fmt: string): bool = darwin_clipboard_has(fmt.cstring)
proc clear*() = darwin_clipboard_clear()
