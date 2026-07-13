import ../dispatch
import ../jslit
import std/strutils

# dispatch.nim importc's these C symbols (zjs.c / webview.m in the real build);
# stub them here to capture what would be eval'd.
var webviewJs = ""
proc darwin_webview_eval_all(js: cstring) {.exportc, cdecl.} = webviewJs = $js
var workerJs = ""
proc zjs_broadcast_eval_js(js: cstring) {.exportc, cdecl.} = workerJs = $js

proc test() =
  # zapp_escape_dup (libc): still exported for the out-of-scope zjs.c/bare.c/
  # Windows-platform callers (Task 2 only migrated the Nim-side call sites off
  # it); same rules as before: \ ' \n \r escaped; nil -> "".
  doAssert $zapp_escape_dup("x'y".cstring) == "x\\'y"
  doAssert $zapp_escape_dup(nil) == ""
  # dispatch_event_to_all: _onEvent IIFE to BOTH webviews + workers. Both name
  # and payload are now complete, safe JS string literals via jsLit (finding
  # #2) — compute the expected literal with the same primitive under test so
  # this asserts dispatch.nim's WIRING (right args, right IIFE shape), not a
  # hand-transcribed re-implementation of jsLit's escaping rules (those are
  # covered exhaustively by jslit_test.nim / cli/src/jslit-transport.test.ts).
  let rawName = "app:theme-changed"
  let rawPayload = "{\"v\":\"a'b\"}"
  dispatch_event_to_all(rawName.cstring, rawPayload.cstring)
  let expected = "b._onEvent(" & jsLit(rawName) & "," & jsLit(rawPayload) & ")"
  doAssert webviewJs.contains(expected), "got: " & webviewJs
  doAssert webviewJs.contains("Symbol.for('zapp.bridge')")
  doAssert workerJs == webviewJs        # same IIFE to both
  echo "dispatch ok"
test()
