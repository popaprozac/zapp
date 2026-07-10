## Webview <-> native message bridge: the `{t, id, m, a}` envelope, its parse,
## and the invoke-response sender. Wire-identical to the zc reference path
## (native/bridge/dispatch.zc:dispatch_invoke_response) — the JS->native
## envelope shape and the native->JS `_onInvokeResult` IIFE must NOT drift, or
## the bootstrap bridge (bootstrap/webview.ts) stops resolving promises.
import std/[json, options]
import nativeabi

type BridgeMsg* = object
  ## A decoded webview->native envelope. Mirrors the protocol the bootstrap
  ## bridge posts (native/bridge/protocol.zc): t = message type (1 = INVOKE),
  ## id = request id, m = method name, a = args (or nil when absent).
  t*: int
  id*: int
  m*: string
  a*: JsonNode

proc parseBridge*(raw: string): Option[BridgeMsg] =
  ## Parse a raw JSON envelope. Returns none on malformed input. The guarded
  ## `{}` accessors never raise on a missing key — they yield the JNull/default,
  ## so a partial envelope decodes to sane zero values rather than throwing.
  try:
    let n = parseJson(raw)
    if n.kind != JObject: return none(BridgeMsg)
    some BridgeMsg(
      t: n{"t"}.getInt(0),
      id: n{"id"}.getInt(0),
      m: n{"m"}.getStr(""),
      a: n{"a"})            # nil when "a" is absent
  except CatchableError:
    none(BridgeMsg)

# darwin_window_eval_js — defined in the (compiled) window.m. Evaluates a JS
# snippet in the given window's WKWebView on the main thread; it copies `js`
# synchronously, so the caller may free immediately after the call.
proc nativeWindowEvalJs(windowId: int32, js: cstring) {.importc: abiPrefix & "window_eval_js", cdecl.}

proc escapeJsSingleQuoted*(s: string): string =
  ## Escape a string as the CONTENTS of a JS single-quoted literal. Byte-for-byte
  ## the same transform as bridge/dispatch.zc's zapp_escape_dup: backslash,
  ## single-quote, and the two line terminators are the only chars escaped.
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '\\': result.add("\\\\")
    of '\'': result.add("\\'")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    else: result.add(c)

proc sendInvokeResponse*(windowId, requestId: int, ok: bool, payload: string) =
  ## Send an invoke result back to the webview's bridge. Wire-identical to
  ## bridge/dispatch.zc:dispatch_invoke_response so the bootstrap's
  ## `_onInvokeResult(id, ok, payload)` resolves/rejects the pending promise.
  ## NB arg order: window id first, request id second (matches the zc
  ## (int window_id, int request_id) signature).
  ## TODO(phase2): reintroduce the cancellation guard — zc dispatch_invoke_response
  ## drops the response when zapp_is_cancelled(requestId); no cancellation
  ## machinery exists in the skeleton yet.
  let okLit = if ok: "true" else: "false"
  let js = "(function(){var b=globalThis[Symbol.for('zapp.bridge')];" &
           "if(b&&typeof b._onInvokeResult==='function'){" &
           "b._onInvokeResult(" & $requestId & "," & okLit & ",'" &
           escapeJsSingleQuoted(payload) & "');}})();"
  nativeWindowEvalJs(windowId.int32, js.cstring)
