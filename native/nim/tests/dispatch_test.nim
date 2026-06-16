import ../dispatch
import std/strutils

# dispatch.nim importc's these C symbols (zjs.c / webview.m in the real build);
# stub them here to capture what would be eval'd.
var webviewJs = ""
proc darwin_webview_eval_all(js: cstring) {.exportc, cdecl.} = webviewJs = $js
var workerJs = ""
proc zjs_broadcast_eval_js(js: cstring) {.exportc, cdecl.} = workerJs = $js

proc test() =
  # escapeJs: backslash, quote, newline, CR
  doAssert escapeJs("a'b\nc\\d\re") == "a\\'b\\nc\\\\d\\re"
  # zapp_escape_dup (libc): same rules; nil -> ""
  doAssert $zapp_escape_dup("x'y".cstring) == "x\\'y"
  doAssert $zapp_escape_dup(nil) == ""
  # dispatch_event_to_all: _onEvent IIFE to BOTH webviews + workers. Per
  # dispatch.zc, only \ ' \n \r are escaped — a `"` inside a single-quoted JS
  # string needs no escaping, so the double-quotes stay raw and only the ' is
  # escaped (`a'b` -> `a\'b`).
  dispatch_event_to_all("app:theme-changed".cstring, "{\"v\":\"a'b\"}".cstring)
  doAssert webviewJs.contains("b._onEvent('app:theme-changed','{\"v\":\"a\\'b\"}')")
  doAssert webviewJs.contains("Symbol.for('zapp.bridge')")
  doAssert workerJs == webviewJs        # same IIFE to both
  echo "dispatch ok"
test()
