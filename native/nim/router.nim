## Message router: decode the envelope, dispatch INVOKE (t==1) to the service
## registry, and answer over the webview bridge. The non-INVOKE envelope types
## (emit / window-action / worker / sync) are framework breadth not exercised by
## the walking skeleton — they fall through silently for now.
import std/[options, json, strutils]
import bridge, service, clipboard, callbacks, events, permissions, fs, dialog

# Bridge-ready signal: the webview posts {t:4,m:"ready"} once its bootstrap bridge
# is up (bootstrap/webview.ts). The .m window delegate defers the FIRST focus
# event (window.m:384 — window becomes key before the bridge is ready →
# pendingFocusEvent) and only flushes it when darwin_window_set_bridge_ready
# fires (window.m:550-554). So without routing "ready", window:focus is stuck
# deferred forever (every other window event dispatches unconditionally).
proc darwin_window_id_string(numericId: int32): cstring {.importc, cdecl.}
proc darwin_window_set_bridge_ready(windowId: cstring) {.importc, cdecl.}
proc zapp_window_trigger_on_ready(id: int32) {.importc, cdecl.}  # def in callbacks.nim

# __zapp: route targets. zapp_workers_registry_list_json is the zapp.nim stub →
# a STATIC "[]" (NOT malloc'd) — do NOT free it (the zc frees a malloc'd registry
# string; B7's real registry will re-add the free here). permissions_bootstrap_json
# is in permissions.nim (B3, already imported).
proc zapp_workers_registry_list_json(): cstring {.importc, cdecl.}

# __app: route targets (platform.m — SMAppService login item, macOS).
proc darwin_set_login_item(enabled: bool): bool {.importc, cdecl.}
proc darwin_get_login_item(): bool {.importc, cdecl.}

# --- t:4 window-op targets (window.m / webview.h, all compiled) -------------
proc darwin_window_get_by_numeric_id(numericId: int32): pointer {.importc, cdecl.}
proc darwin_window_numeric_id_for_string(wid: cstring): int32 {.importc, cdecl.}
proc darwin_window_show(handle: pointer) {.importc, cdecl.}
proc darwin_window_hide(handle: pointer) {.importc, cdecl.}
proc darwin_window_minimize(handle: pointer) {.importc, cdecl.}
proc darwin_window_maximize(handle: pointer) {.importc, cdecl.}
proc darwin_window_focus(handle: pointer) {.importc, cdecl.}
proc darwin_window_force_close(handle: pointer) {.importc, cdecl.}
proc darwin_window_set_title(handle: pointer, title: cstring) {.importc, cdecl.}
proc darwin_window_set_size(handle: pointer, w, h: int32) {.importc, cdecl.}
proc darwin_window_set_position(handle: pointer, x, y: int32) {.importc, cdecl.}
proc darwin_window_set_fullscreen(handle: pointer, on: bool) {.importc, cdecl.}
proc darwin_window_set_always_on_top(handle: pointer, on: bool) {.importc, cdecl.}
proc darwin_window_attach_modal(parent, modal: pointer) {.importc, cdecl.}
proc darwin_window_detach_modal(parent, modal: pointer) {.importc, cdecl.}
proc darwin_window_load_url(windowId: int32, url: cstring) {.importc, cdecl.}
proc darwin_webview_set_drag_region(windowId: int32, drag: bool) {.importc, cdecl.}
proc zapp_window_set_close_guard(id, enabled: cint) {.importc, cdecl.}  # def in callbacks.nim (exportc)

# --- t:4 app-op + shell targets (platform.m / webview.h) -------------------
proc darwin_app_quit(force: bool) {.importc, cdecl.}
proc darwin_app_activate() {.importc, cdecl.}
proc darwin_set_quit_guard(enabled: bool) {.importc, cdecl.}
proc darwin_open_external(url: cstring) {.importc, cdecl.}

# --- t:4 shell-path targets (webview.m, compiled; B6a) ---------------------
proc darwin_show_item_in_folder(p: cstring) {.importc, cdecl.}
proc darwin_open_path(p: cstring) {.importc, cdecl.}
proc darwin_trash_item(p: cstring) {.importc, cdecl.}

proc resolveWinId(a: JsonNode, key: string): int32 =
  ## parentId/modalId may be an int OR a "win-<n>" pointer-string; -1 if absent
  ## (router.zc:666-700). Mirrors the int-then-string resolution.
  if a.isNil: return -1
  let v = a{key}
  if v.isNil: return -1
  if v.kind == JInt: return v.getInt(-1).int32
  if v.kind == JString: return darwin_window_numeric_id_for_string(v.getStr("").cstring)
  -1

proc routeZapp(meth: string, windowId, id: int) =
  ## __zapp:* routes (router.zc:1352-1375).
  if meth == "__zapp:workers-list":
    let json = zapp_workers_registry_list_json()
    sendInvokeResponse(windowId, id, true, (if json.isNil: "[]" else: $json))
    return
  if meth == "__zapp:permissions":
    sendInvokeResponse(windowId, id, true, $permissions_bootstrap_json())
    return
  sendInvokeResponse(windowId, id, false, "UNKNOWN_ZAPP_METHOD")

proc routeApp(meth: string, a: JsonNode, windowId, id: int) =
  ## __app:* routes (router.zc:1377-1415). Login item (macOS); reply the bool as
  ## a JSON literal the runtime JSON.parses.
  if meth == "__app:setLoginItem":
    let enabled = (if a.isNil: false else: a{"enabled"}.getBool(false))
    let ok = darwin_set_login_item(enabled)
    sendInvokeResponse(windowId, id, true, (if ok: "true" else: "false"))
    return
  if meth == "__app:getLoginItem":
    let ok = darwin_get_login_item()
    sendInvokeResponse(windowId, id, true, (if ok: "true" else: "false"))
    return
  sendInvokeResponse(windowId, id, false, "UNKNOWN")

proc routeClipboard(m: string, a: JsonNode, windowId, id: int) =
  ## Handle a `__clipboard:*` INVOKE natively (NOT via the service registry),
  ## mirroring native/app/router.zc:router_handle_clipboard. Arg keys match the
  ## runtime (runtime/clipboard.ts) + the zc reference: writeText reads "text",
  ## writeHtml reads "html", has reads "format", writeImagePng reads "data".
  ##
  ## Payload contract (consumed by bootstrap/webview.ts:_onInvokeResult →
  ## JSON.parse): text/html reads -> a JSON STRING literal of the content (via
  ## `$ % str`, correctly escaped); readFiles -> the JSON array string verbatim;
  ## has -> JSON bool; writes/clear -> "null" (the runtime ignores it). An
  ## unhandled `__clipboard:*` method rejects with the bare token (no JSON quotes
  ## — webview.ts does `new Error(payload)`), matching the zc UNKNOWN_CLIPBOARD.
  let args = if a.isNil: newJObject() else: a
  case m
  of "__clipboard:readText":
    sendInvokeResponse(windowId, id, true, $(%clipboard.readText()))
  of "__clipboard:readHtml":
    sendInvokeResponse(windowId, id, true, $(%clipboard.readHtml()))
  of "__clipboard:readFiles":
    sendInvokeResponse(windowId, id, true, clipboard.readFiles())
  of "__clipboard:readImagePng":
    # base64 PNG as a JSON string ("" => runtime treats as null / no image).
    sendInvokeResponse(windowId, id, true, $(%clipboard.readImagePngB64()))
  of "__clipboard:writeImagePng":
    # arg key is "data" (runtime/clipboard.ts writeImage sends { data }), NOT b64.
    discard clipboard.writeImagePngB64(args{"data"}.getStr(""))
    sendInvokeResponse(windowId, id, true, "null")
  of "__clipboard:has":
    let ok = clipboard.has(args{"format"}.getStr(""))
    sendInvokeResponse(windowId, id, true, (if ok: "true" else: "false"))
  of "__clipboard:writeText":
    discard clipboard.writeText(args{"text"}.getStr(""))
    sendInvokeResponse(windowId, id, true, "null")
  of "__clipboard:writeHtml":
    discard clipboard.writeHtml(args{"html"}.getStr(""))
    sendInvokeResponse(windowId, id, true, "null")
  of "__clipboard:clear":
    clipboard.clear()
    sendInvokeResponse(windowId, id, true, "null")
  else:
    sendInvokeResponse(windowId, id, false, "UNKNOWN_CLIPBOARD")

proc routeDialog(meth: string, a: JsonNode, windowId, id: int) =
  ## t:1 `__dialog:*` — desktop path (mirror router.zc:1430-1535). Pass the
  ## options object (JSON) to the darwin_dialog_* JSON variant; reply with the
  ## result JSON the runtime JSON.parses. On `__dialog:open`, grant each picked
  ## path to the FS session allowlist (so FS/shell-path ops can act on it).
  ## (iOS async + Windows branches are out of scope; macOS desktop only.)
  let optionsJson = (if a.isNil: "{}" else: $a)
  var resultStr = ""
  case meth
  of "__dialog:open":   resultStr = dialogOpenFile(optionsJson)
  of "__dialog:save":   resultStr = dialogSaveFile(optionsJson)
  of "__dialog:message": resultStr = dialogMessage(optionsJson)
  else:
    sendInvokeResponse(windowId, id, false, "UNKNOWN_DIALOG")
    return
  if meth == "__dialog:open" and resultStr.len > 0:
    for p in dialogGrantedPaths(resultStr): fsGrantPath(p)
  if resultStr.len > 0:
    sendInvokeResponse(windowId, id, true, resultStr)
  else:
    sendInvokeResponse(windowId, id, false, "UNKNOWN_DIALOG")

proc routeWindowAction(action: string, a: JsonNode, windowId: int) =
  ## t:4 fire-and-forget window/app action dispatch. HEAD = the action permission
  ## gate (router.zc:376-385): ungated ("") falls through; a gated action not
  ## granted is dropped (fire-and-forget has no reply channel — permissions_check
  ## logs once). The window/app/panel/shell action ARMS are Batch 5b; dock/
  ## sidebar/inspector/popover/toolbar are Batch 8. Only the framework + the
  ## already-ported subscribe/unsubscribe/ready land here.
  let permId = permission_id_for_action(action.cstring)
  if not permId.isNil and permId[0] != '\0':
    if not permissions_check(permId, action.cstring):
      return

  # subscribe / unsubscribe: gate the per-window JS-subscription bitmask so
  # zapp_dispatch_event's Layer-2 JS delivery fires only for subscribed events.
  if action == "subscribe" or action == "unsubscribe":
    let evName = (if a.isNil: "" else: a{"event"}.getStr(""))
    let evId = eventNameToId(evName)
    if evId >= 0:
      zapp_window_set_js_listener(windowId.cint, evId.cint,
        (if action == "subscribe": 1.cint else: 0.cint))
    return

  # ready: the webview's bridge is up — signal bridge-ready (flushes window.m's
  # deferred first-focus event) + fire the native on_ready callback.
  if action == "ready":
    let wid = darwin_window_id_string(windowId.int32)
    if not wid.isNil: darwin_window_set_bridge_ready(wid)
    zapp_window_trigger_on_ready(windowId.int32)
    return

  # --- id-based window ops (take the numeric id; self-guard in the .m) -------
  if action == "loadUrl":
    let url = (if a.isNil: "" else: a{"url"}.getStr(""))
    if url.len > 0: darwin_window_load_url(windowId.int32, url.cstring)
    return
  if action == "setDragRegion":
    let drag = a{"drag"}            # {} is nil-safe on a nil / non-object node
    if not drag.isNil:
      darwin_webview_set_drag_region(windowId.int32, drag.getBool(false))
    return
  if action == "setCloseGuard":
    let on = a{"on"}
    if not on.isNil:
      zapp_window_set_close_guard(windowId.cint, (if on.getBool(false): 1.cint else: 0.cint))
    return

  # --- attach/detach modal (resolve BOTH windows' handles) ------------------
  if action == "attachModal" or action == "detachModal":
    let pNum = resolveWinId(a, "parentId")
    let mNum = resolveWinId(a, "modalId")
    if pNum < 0 or mNum < 0: return
    let pH = darwin_window_get_by_numeric_id(pNum)
    let mH = darwin_window_get_by_numeric_id(mNum)
    if pH.isNil or mH.isNil: return
    if action == "attachModal": darwin_window_attach_modal(pH, mH)
    else: darwin_window_detach_modal(pH, mH)
    return

  # --- app ops (platform.m; ungated) ----------------------------------------
  if action == "quit":
    darwin_app_quit(if a.isNil: false else: a{"force"}.getBool(false))
    return
  if action == "activate":
    darwin_app_activate()
    return
  if action == "setQuitGuard":
    darwin_set_quit_guard(if a.isNil: false else: a{"enabled"}.getBool(false))
    return

  # --- openExternal (shell:open — gated at the head) ------------------------
  if action == "openExternal":
    let url = (if a.isNil: "" else: a{"url"}.getStr(""))
    if url.len > 0: darwin_open_external(url.cstring)
    return

  # --- shell-path ops (B6a; permission-gated at the head as shell:open/reveal/
  # trash). trashItem ADDS the FS-allowlist gate so JS can't trash an arbitrary
  # path (router.zc:576-593); showItemInFolder/openPath are non-destructive. ---
  if action == "showItemInFolder" or action == "openPath" or action == "trashItem":
    let p = a{"path"}
    if p.isNil: return
    let path = p.getStr("")
    if path.len == 0: return
    let abs = fsExpandPath(path)
    if action == "trashItem":
      if not fsIsAllowed(abs): return
    if action == "showItemInFolder": darwin_show_item_in_folder(abs.cstring)
    elif action == "openPath": darwin_open_path(abs.cstring)
    else: darwin_trash_item(abs.cstring)
    return

  # --- handle-based window ops (resolve the NSWindow from the numeric id) ---
  let h = darwin_window_get_by_numeric_id(windowId.int32)
  if h.isNil: return                       # window gone — nothing to act on
  case action
  of "show": darwin_window_show(h)
  of "hide": darwin_window_hide(h)
  of "minimize": darwin_window_minimize(h)
  of "maximize": darwin_window_maximize(h)
  of "setFocus": darwin_window_focus(h)
  of "close":
    # clear the close guard first (router.zc:652-654): force_close is just
    # [NSWindow close], which fires windowShouldClose:; a set guard would veto
    # it. Window.close() is the documented force path, so it must override.
    zapp_window_set_close_guard(windowId.cint, 0.cint)
    darwin_window_force_close(h)
  of "setTitle":
    let title = a{"title"}
    if not title.isNil: darwin_window_set_title(h, title.getStr("").cstring)
  of "setSize":
    let w = a{"width"}; let ht = a{"height"}      # getFloat: zc stores numbers as
    if not w.isNil and not ht.isNil:              # double, truncates to int (parity)
      darwin_window_set_size(h, w.getFloat(0).int32, ht.getFloat(0).int32)
  of "setPosition":
    let x = a{"x"}; let y = a{"y"}
    if not x.isNil and not y.isNil:
      darwin_window_set_position(h, x.getFloat(0).int32, y.getFloat(0).int32)
  of "setFullscreen":
    let on = a{"on"}
    if not on.isNil: darwin_window_set_fullscreen(h, on.getBool(false))
  of "setAlwaysOnTop":
    let on = a{"on"}
    if not on.isNil: darwin_window_set_always_on_top(h, on.getBool(false))
  else: discard

proc routeMessage*(msg: string, windowId: int) =
  ## Entry point for a single webview->native message. Owns parse + dispatch +
  ## response so app.nim's C-ABI handler stays a thin shim.
  let parsed = parseBridge(msg)
  if parsed.isNone: return
  let f = parsed.get

  # t:4 fire-and-forget window/app action — dispatched (+ permission-gated) in
  # routeWindowAction.
  if f.t == 4:
    routeWindowAction(f.m, f.a, windowId)
    return

  if f.t != 1: return            # skeleton answers INVOKE only

  # Permission gate (t:1). Map the method to a catalog id; ungated ("") falls
  # through. Manifest active + id not granted => reply so the JS promise rejects
  # (PERMISSION_DENIED:<id>; the runtime decorates it into PermissionDeniedError).
  # Mirrors native/app/router.zc:62-80.
  let permId = permission_id_for_invoke(f.m.cstring)
  if not permId.isNil and permId[0] != '\0':
    if not permissions_check(permId, f.m.cstring):
      sendInvokeResponse(windowId, f.id, false, "PERMISSION_DENIED:" & $permId)
      return

  # `__clipboard:*` INVOKEs are handled natively (NOT via the service registry),
  # so they must be intercepted before the registry lookup below.
  if f.m.startsWith("__clipboard:"):
    routeClipboard(f.m, f.a, windowId, f.id)   # owns its own sendInvokeResponse
    return

  if f.m.startsWith("__zapp:"):
    routeZapp(f.m, windowId, f.id)
    return
  if f.m.startsWith("__app:"):
    routeApp(f.m, f.a, windowId, f.id)
    return
  if f.m.startsWith("__dialog:"):
    routeDialog(f.m, f.a, windowId, f.id)
    return

  let res = invokeService(f.m, f.a)
  if res.isSome:
    sendInvokeResponse(windowId, f.id, true, res.get)
  else:
    # Wire-identical to the inline sub-gate-A bridge: the error payload is the
    # bare token "NOT_FOUND" (bootstrap/webview.ts builds Error(payload) from it,
    # so the message must stay unquoted, not JSON-encoded).
    sendInvokeResponse(windowId, f.id, false, "NOT_FOUND")
