## Message router: decode the envelope, dispatch INVOKE (t==1) to the service
## registry, and answer over the webview bridge. The non-INVOKE envelope types
## (emit / window-action / worker / sync) are framework breadth not exercised by
## the walking skeleton — they fall through silently for now.
import std/[options, json, strutils]
import bridge, service, clipboard, callbacks, events, permissions, fs, dialog, notification, shortcuts

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

# --- t:1 screen-query targets (screen.m, already compiled; B6e). Each returns
# a heap char* the caller frees. darwin_window_numeric_id_for_string is already
# importc'd above (B5b). ---
proc darwin_screen_list_json(): cstring {.importc, cdecl.}
proc darwin_screen_cursor_json(): cstring {.importc, cdecl.}
proc darwin_screen_for_window_json(windowId: int32): cstring {.importc, cdecl.}
proc c_free(p: cstring) {.importc: "free", cdecl.}

# --- t:4 menu targets (menu.m; payload = the FULL bridge envelope, menu.m
# extracts "a"). menu.m builds the NSMenu + icons + click delivery itself. ---
proc darwin_menu_set_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_menu_show_context_from_payload(payloadJson: cstring, windowId: int32) {.importc, cdecl.}

# --- t:4 tray targets (tray.m; payload = the FULL bridge envelope, tray.m
# extracts "a"). tray.m owns the NSStatusItem + icon + menu + click delivery. ---
proc darwin_tray_create_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_tray_set_icon_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_tray_set_title_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_tray_set_tooltip_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_tray_set_menu_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_tray_destroy_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_tray_attach_window_from_payload(payloadJson: cstring) {.importc, cdecl.}
proc darwin_tray_detach_window_from_payload(payloadJson: cstring) {.importc, cdecl.}

# --- t:4 dock targets (dock.m; arg-based, not payload). No darwin set_progress
# (macOS dock has no standard progress — dock.zc:40 is a no-op). ---
proc darwin_dock_show_icon() {.importc, cdecl.}
proc darwin_dock_hide_icon() {.importc, cdecl.}
proc darwin_dock_remove_badge() {.importc, cdecl.}
proc darwin_dock_reset_icon() {.importc, cdecl.}
proc darwin_dock_set_badge(label: cstring) {.importc, cdecl.}
proc darwin_dock_bounce(bounceType: cint) {.importc, cdecl.}
proc darwin_dock_set_icon(imagePath: cstring) {.importc, cdecl.}

# --- t:4 panel (embedded-webview) targets (panel.m, already compiled; B6i).
# Arg-based; embed-gated at the head. ---
proc darwin_panel_create(windowId: int32, panelId, url: cstring, bridge: bool, partition: cstring) {.importc, cdecl.}
proc darwin_panel_set_bounds(panelId: cstring, x, y, w, h: int32) {.importc, cdecl.}
proc darwin_panel_load_url(panelId, url: cstring) {.importc, cdecl.}
proc darwin_panel_eval_js(panelId, js: cstring) {.importc, cdecl.}
proc darwin_panel_post_message(panelId, dataJson: cstring) {.importc, cdecl.}
proc darwin_panel_show(panelId: cstring) {.importc, cdecl.}
proc darwin_panel_hide(panelId: cstring) {.importc, cdecl.}
proc darwin_panel_reload(panelId: cstring) {.importc, cdecl.}
proc darwin_panel_go_back(panelId: cstring) {.importc, cdecl.}
proc darwin_panel_go_forward(panelId: cstring) {.importc, cdecl.}
proc darwin_panel_destroy(panelId: cstring) {.importc, cdecl.}

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

proc routeNotification(meth: string, a: JsonNode, windowId, id: int) =
  ## t:1 `__notif:*` (mirror router.zc:1551-1690). Async ops (requestPermission/
  ## show/schedule) reply LATER via notifResponseCb — this proc returns without
  ## replying for those. Sync ops reply inline ("{}" or the result). macOS only.
  let argsJson = (if a.isNil: "{}" else: $a)
  case meth
  of "__notif:requestPermission": notifRequestPermission(windowId, id)   # async
  of "__notif:show":              notifShow(argsJson, windowId, id)       # async
  of "__notif:schedule":          notifSchedule(argsJson, windowId, id)   # async
  of "__notif:getPermission":
    sendInvokeResponse(windowId, id, true, notifGetPermission())
  of "__notif:cancel":
    let nid = a{"id"}.getStr("")
    if nid.len > 0: notifCancel(nid)
    sendInvokeResponse(windowId, id, true, "{}")
  of "__notif:cancelAll":
    notifCancelAll()
    sendInvokeResponse(windowId, id, true, "{}")
  of "__notif:registerCategory":
    let cid = a{"id"}.getStr("")
    if cid.len > 0: notifRegisterCategory(cid, argsJson)
    sendInvokeResponse(windowId, id, true, "{}")
  of "__notif:removeCategory":
    let cid = a{"id"}.getStr("")
    if cid.len > 0: notifRemoveCategory(cid)
    sendInvokeResponse(windowId, id, true, "{}")
  of "__notif:removeDelivered":
    notifRemoveDelivered(argsJson)
    sendInvokeResponse(windowId, id, true, "{}")
  of "__notif:removeAllDelivered":
    notifRemoveAllDelivered()
    sendInvokeResponse(windowId, id, true, "{}")
  of "__notif:update":
    notifUpdate(argsJson)
    sendInvokeResponse(windowId, id, true, "{}")
  else:
    sendInvokeResponse(windowId, id, false, "UNKNOWN_NOTIFICATION")

proc routeShortcuts(meth: string, a: JsonNode, windowId, id: int) =
  ## t:1 `__shortcuts:*` (mirror router.zc:1717-1762). register/unregister/
  ## isRegistered reply the boolean; unregisterAll replies null; missing arg /
  ## unknown → UNKNOWN_SHORTCUT. Arg key "accelerator".
  let acc = a{"accelerator"}.getStr("")
  case meth
  of "__shortcuts:register":
    if acc.len == 0: sendInvokeResponse(windowId, id, false, "UNKNOWN_SHORTCUT")
    else: sendInvokeResponse(windowId, id, true, (if shortcutRegister(acc): "true" else: "false"))
  of "__shortcuts:unregister":
    if acc.len == 0: sendInvokeResponse(windowId, id, false, "UNKNOWN_SHORTCUT")
    else: sendInvokeResponse(windowId, id, true, (if shortcutUnregister(acc): "true" else: "false"))
  of "__shortcuts:isRegistered":
    if acc.len == 0: sendInvokeResponse(windowId, id, false, "UNKNOWN_SHORTCUT")
    else: sendInvokeResponse(windowId, id, true, (if shortcutIsRegistered(acc): "true" else: "false"))
  of "__shortcuts:unregisterAll":
    shortcutUnregisterAll()
    sendInvokeResponse(windowId, id, true, "null")
  else:
    sendInvokeResponse(windowId, id, false, "UNKNOWN_SHORTCUT")

proc routeScreen(meth: string, a: JsonNode, windowId, id: int) =
  ## t:1 `__screen:*` (mirror screen.zc:screen_route). darwin_screen_*_json
  ## return heap char* — copy ($) into the reply, then free. NULL → safe default.
  case meth
  of "__screen:list":
    let j = darwin_screen_list_json()
    if j.isNil: sendInvokeResponse(windowId, id, true, "[]")
    else:
      sendInvokeResponse(windowId, id, true, $j); c_free(j)
  of "__screen:cursor":
    let j = darwin_screen_cursor_json()
    if j.isNil: sendInvokeResponse(windowId, id, false, "null")
    else:
      sendInvokeResponse(windowId, id, true, $j); c_free(j)
  of "__screen:forWindow":
    let ws = a{"windowId"}.getStr("")
    let target = (if ws.len > 0: darwin_window_numeric_id_for_string(ws.cstring) else: -1'i32)
    let j = darwin_screen_for_window_json(target)
    if j.isNil: sendInvokeResponse(windowId, id, false, "null")
    else:
      sendInvokeResponse(windowId, id, true, $j); c_free(j)
  else:
    sendInvokeResponse(windowId, id, false, "UNKNOWN_SCREEN")

proc routePanel(action: string, a: JsonNode, windowId: int): bool =
  ## t:4 embedded-webview ("panel") actions (mirror panel.zc:panel_route).
  ## Returns true if `action` was a panel action (so routeWindowAction stops).
  ## Arg-based; embed-gated at routeWindowAction's head. panel.m owns the WKWebView.
  if not action.startsWith("panel"): return false
  let pid = a{"panelId"}.getStr("")
  case action
  of "panelCreate":
    let url = a{"url"}.getStr("")
    let partition = a{"partition"}.getStr("")
    darwin_panel_create(windowId.int32, pid.cstring, url.cstring,
                        a{"bridge"}.getBool(false), partition.cstring)
  of "panelSetBounds":
    darwin_panel_set_bounds(pid.cstring, a{"x"}.getInt(0).int32, a{"y"}.getInt(0).int32,
                            a{"w"}.getInt(0).int32, a{"h"}.getInt(0).int32)
  of "panelLoadUrl":
    let url = a{"url"}.getStr("")
    darwin_panel_load_url(pid.cstring, url.cstring)
  of "panelExecJs":
    let code = a{"code"}.getStr("")
    darwin_panel_eval_js(pid.cstring, code.cstring)
  of "panelPostMessage":
    let data = a{"data"}.getStr("")
    darwin_panel_post_message(pid.cstring, data.cstring)
  of "panelShow": darwin_panel_show(pid.cstring)
  of "panelHide": darwin_panel_hide(pid.cstring)
  of "panelReload": darwin_panel_reload(pid.cstring)
  of "panelBack": darwin_panel_go_back(pid.cstring)
  of "panelForward": darwin_panel_go_forward(pid.cstring)
  of "panelDestroy": darwin_panel_destroy(pid.cstring)
  else: return false      # "panel"-prefixed but not a real panel action
  return true

proc routeWindowAction(action: string, a: JsonNode, windowId: int, payload: string) =
  ## t:4 fire-and-forget window/app action dispatch. HEAD = the action permission
  ## gate (router.zc:376-385): ungated ("") falls through; a gated action not
  ## granted is dropped (fire-and-forget has no reply channel — permissions_check
  ## logs once). Ported arms: subscribe/unsubscribe/ready, id-based + handle-based
  ## window ops + attach/detachModal (B5b), app ops + openExternal (B5b),
  ## shell-path (B6a), menu (B6f), tray (B6g), dock (B6h), panel (B6i). Remaining:
  ## sidebar/inspector/popover/toolbar t:4 + accessory-pane sender resolution (B8).
  let permId = permission_id_for_action(action.cstring)
  if not permId.isNil and permId[0] != '\0':
    if not permissions_check(permId, action.cstring):
      return

  # subscribe / unsubscribe: gate the per-window JS-subscription bitmask so
  # zapp_dispatch_event's Layer-2 JS delivery fires only for subscribed events.
  if action == "subscribe" or action == "unsubscribe":
    let evName = (if a.isNil: "" else: a{"event"}.getStr(""))
    if action == "subscribe" and evName.startsWith("__notif:"):
      notifSetBridgeReady()        # flush buffered notification responses
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

  # --- menu ops (menu.m parses the full payload; gated "menu" at the head) ---
  if action == "setMenu":
    darwin_menu_set_from_payload(payload.cstring)
    return
  if action == "showContextMenu":
    darwin_menu_show_context_from_payload(payload.cstring, windowId.int32)
    return

  # --- tray ops (tray.m parses the full payload; gated "tray" at the head) ---
  if action.startsWith("tray:"):
    case action
    of "tray:create": darwin_tray_create_from_payload(payload.cstring)
    of "tray:setIcon": darwin_tray_set_icon_from_payload(payload.cstring)
    of "tray:setTitle": darwin_tray_set_title_from_payload(payload.cstring)
    of "tray:setTooltip": darwin_tray_set_tooltip_from_payload(payload.cstring)
    of "tray:setMenu": darwin_tray_set_menu_from_payload(payload.cstring)
    of "tray:destroy": darwin_tray_destroy_from_payload(payload.cstring)
    of "tray:attachWindow": darwin_tray_attach_window_from_payload(payload.cstring)
    of "tray:detachWindow": darwin_tray_detach_window_from_payload(payload.cstring)
    else: discard      # unknown tray:* — no-op (matches the zc fallthrough)
    return

  # --- dock ops (dock.m; arg-based; gated "dock" at the head) ---
  if action.startsWith("dock:"):
    case action
    of "dock:showIcon": darwin_dock_show_icon()
    of "dock:hideIcon": darwin_dock_hide_icon()
    of "dock:removeBadge": darwin_dock_remove_badge()
    of "dock:resetIcon": darwin_dock_reset_icon()
    of "dock:setBadge":
      let label = a{"label"}
      if not label.isNil: darwin_dock_set_badge(label.getStr("").cstring)
    of "dock:bounce":
      darwin_dock_bounce(a{"type"}.getInt(0).cint)
    of "dock:setProgress": discard      # macOS: no-op (dock.zc:40 empty Apple body)
    of "dock:setIcon":
      let path = a{"path"}
      if not path.isNil: darwin_dock_set_icon(path.getStr("").cstring)
    else: discard
    return

  # --- panel (embedded-webview) ops (panel.m; embed-gated at the head) ------
  if routePanel(action, a, windowId): return

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
    routeWindowAction(f.m, f.a, windowId, msg)
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
  if f.m.startsWith("__notif:"):
    routeNotification(f.m, f.a, windowId, f.id)
    return
  if f.m.startsWith("__shortcuts:"):
    routeShortcuts(f.m, f.a, windowId, f.id)
    return
  if f.m.startsWith("__screen:"):
    routeScreen(f.m, f.a, windowId, f.id)
    return

  let res = invokeService(f.m, f.a)
  if res.isSome:
    sendInvokeResponse(windowId, f.id, true, res.get)
  else:
    # Wire-identical to the inline sub-gate-A bridge: the error payload is the
    # bare token "NOT_FOUND" (bootstrap/webview.ts builds Error(payload) from it,
    # so the message must stay unquoted, not JSON-encoded).
    sendInvokeResponse(windowId, f.id, false, "NOT_FOUND")
