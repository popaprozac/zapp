## Message router: decode the envelope, dispatch INVOKE (t==1) to the service
## registry, and answer over the webview bridge. The non-INVOKE envelope types
## (emit / window-action / worker / sync) are framework breadth not exercised by
## the walking skeleton — they fall through silently for now.
import std/options
import bridge, service

proc routeMessage*(msg: string, windowId: int) =
  ## Entry point for a single webview->native message. Owns parse + dispatch +
  ## response so app.nim's C-ABI handler stays a thin shim.
  let parsed = parseBridge(msg)
  if parsed.isNone: return
  let f = parsed.get
  if f.t != 1: return            # skeleton answers INVOKE only

  # --- Task 6 (clipboard) seam ---------------------------------------------
  # The clipboard methods arrive as INVOKEs whose `m` is prefixed `__clipboard:`
  # (e.g. `__clipboard:readText`). They are handled natively, NOT via the
  # service registry, so the dispatch below must NOT see them. Task 6 inserts
  # its handling block HERE, right before the registry lookup — e.g.:
  #   if f.m.startsWith("__clipboard:"):
  #     routeClipboard(f.m, f.a, windowId, f.id)   # owns its own sendInvokeResponse
  #     return
  # -------------------------------------------------------------------------

  let res = invokeService(f.m, f.a)
  if res.isSome:
    sendInvokeResponse(windowId, f.id, true, res.get)
  else:
    # Wire-identical to the inline sub-gate-A bridge: the error payload is the
    # bare token "NOT_FOUND" (bootstrap/webview.ts builds Error(payload) from it,
    # so the message must stay unquoted, not JSON-encoded).
    sendInvokeResponse(windowId, f.id, false, "NOT_FOUND")
