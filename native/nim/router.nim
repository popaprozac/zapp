## Message router: decode the envelope, dispatch INVOKE (t==1) to the service
## registry, and answer over the webview bridge. The non-INVOKE envelope types
## (emit / window-action / worker / sync) are framework breadth not exercised by
## the walking skeleton — they fall through silently for now.
import std/[options, json, strutils]
import bridge, service, clipboard, callbacks, events, permissions, fs, dialog, notification, shortcuts
import routerstate

# worker: worker_create / worker_post_message / worker_terminate (B7b.1
#   dispatcher). registry: the C-ABI procs routeWorker needs are plain Nim `*`
#   exports (zapp_worker_registry_add_full_with_engine_and_name / _remove —
#   declared `proc … *(…) {.exportc,…}`, so the `*` makes them callable as Nim
#   procs too). So routeWorker reaches them by import — NO importc here
#   (importc'ing our own exportc symbols would re-declare them).
import worker, registry, window
# dispatch: dispatch_event_to_all (t:3 EMIT broadcast). It's a `*`-exported Nim
# proc in dispatch.nim, so importing the module makes it callable by name — NO
# importc (it's a Nim proc, not a C symbol; mixing would risk a duplicate).
import dispatch
import nativeabi

# Bridge-ready signal: the webview posts {t:4,m:"ready"} once its bootstrap bridge
# is up (bootstrap/webview.ts). The .m window delegate defers the FIRST focus
# event (window.m:384 — window becomes key before the bridge is ready →
# pendingFocusEvent) and only flushes it when darwin_window_set_bridge_ready
# fires (window.m:550-554). So without routing "ready", window:focus is stuck
# deferred forever (every other window event dispatches unconditionally).

# --- iOS native routing (N3a). Defined in ios/routing.m; no-op symbol absent on
#     non-iOS builds because the calls are `when defined(zappIos)`-gated. ---
when defined(zappIos):
  proc zapp_ios_push_route_vc(windowId: int32, url: cstring, chromeJson: cstring) {.importc, cdecl.}
  proc zapp_ios_pop_route_vc(windowId: int32) {.importc, cdecl.}
  proc zapp_ios_pop_to_content(windowId: int32) {.importc, cdecl.}

proc nativeWindowIdString(numericId: int32): cstring {.importc: abiPrefix & "window_id_string", cdecl.}
proc nativeWindowSetBridgeReady(windowId: cstring) {.importc: abiPrefix & "window_set_bridge_ready", cdecl.}
proc zapp_window_trigger_on_ready(id: int32) {.importc, cdecl.}  # def in callbacks.nim

# __zapp: route targets. zapp_workers_registry_list_json is the zapp.nim stub →
# a STATIC "[]" (NOT malloc'd) — do NOT free it (the zc frees a malloc'd registry
# string; B7's real registry will re-add the free here). permissions_bootstrap_json
# is in permissions.nim (B3, already imported).
proc zapp_workers_registry_list_json(): cstring {.importc, cdecl.}

# __app: route targets (platform.m — SMAppService login item, macOS).
proc nativeSetLoginItem(enabled: bool): bool {.importc: abiPrefix & "set_login_item", cdecl.}
proc nativeGetLoginItem(): bool {.importc: abiPrefix & "get_login_item", cdecl.}

# --- t:4 window-op targets (window.m / webview.h, all compiled) -------------
proc nativeWindowGetByNumericId(numericId: int32): pointer {.importc: abiPrefix & "window_get_by_numeric_id", cdecl.}
proc nativeWindowNumericIdForString(wid: cstring): int32 {.importc: abiPrefix & "window_numeric_id_for_string", cdecl.}
proc nativeWindowShow(handle: pointer) {.importc: abiPrefix & "window_show", cdecl.}
proc nativeWindowHide(handle: pointer) {.importc: abiPrefix & "window_hide", cdecl.}
proc nativeWindowMinimize(handle: pointer) {.importc: abiPrefix & "window_minimize", cdecl.}
proc nativeWindowMaximize(handle: pointer) {.importc: abiPrefix & "window_maximize", cdecl.}
proc nativeWindowZoom(handle: pointer) {.importc: abiPrefix & "window_zoom", cdecl.}
proc nativeWindowFocus(handle: pointer) {.importc: abiPrefix & "window_focus", cdecl.}
proc nativeWindowForceClose(handle: pointer) {.importc: abiPrefix & "window_force_close", cdecl.}
proc nativeWindowSetTitle(handle: pointer, title: cstring) {.importc: abiPrefix & "window_set_title", cdecl.}
proc nativeWindowSetSize(handle: pointer, w, h: int32) {.importc: abiPrefix & "window_set_size", cdecl.}
proc nativeWindowSetPosition(handle: pointer, x, y: int32) {.importc: abiPrefix & "window_set_position", cdecl.}
proc nativeWindowSetFullscreen(handle: pointer, on: bool) {.importc: abiPrefix & "window_set_fullscreen", cdecl.}
proc nativeWindowSetAlwaysOnTop(handle: pointer, on: bool) {.importc: abiPrefix & "window_set_always_on_top", cdecl.}
proc nativeWindowAttachModal(parent, modal: pointer) {.importc: abiPrefix & "window_attach_modal", cdecl.}
proc nativeWindowDetachModal(parent, modal: pointer) {.importc: abiPrefix & "window_detach_modal", cdecl.}
proc nativeWindowLoadUrl(windowId: int32, url: cstring) {.importc: abiPrefix & "window_load_url", cdecl.}
proc nativeWebviewSetDragRegion(windowId: int32, drag: bool) {.importc: abiPrefix & "webview_set_drag_region", cdecl.}
# beginDrag: Windows-only. macOS drags via the WKWebView's mouseDownCanMoveWindow
# (no explicit call), so the JS gesture that posts "beginDrag" only fires on
# Windows (bootstrap/webview.ts gates on platform=="windows"); this binding is
# gated to match so no darwin symbol is required.
when defined(zappWindows):
  proc nativeWindowBeginDrag(windowId: int32) {.importc: abiPrefix & "window_begin_drag", cdecl.}
proc zapp_window_set_close_guard(id, enabled: cint) {.importc, cdecl.}  # def in callbacks.nim (exportc)

# --- t:4 app-op + shell targets (platform.m / webview.h) -------------------
proc nativeAppQuit(force: bool) {.importc: abiPrefix & "app_quit", cdecl.}
proc nativeAppActivate() {.importc: abiPrefix & "app_activate", cdecl.}
proc nativeSetQuitGuard(enabled: bool) {.importc: abiPrefix & "set_quit_guard", cdecl.}
proc nativeOpenExternal(url: cstring) {.importc: abiPrefix & "open_external", cdecl.}

# --- t:4 shell-path targets (webview.m, compiled; B6a) ---------------------
proc nativeShowItemInFolder(p: cstring) {.importc: abiPrefix & "show_item_in_folder", cdecl.}
proc nativeOpenPath(p: cstring) {.importc: abiPrefix & "open_path", cdecl.}
proc nativeTrashItem(p: cstring) {.importc: abiPrefix & "trash_item", cdecl.}

# --- t:1 screen-query targets (screen.m, already compiled; B6e). Each returns
# a heap char* the caller frees. darwin_window_numeric_id_for_string is already
# importc'd above (B5b). ---
proc nativeScreenListJson(): cstring {.importc: abiPrefix & "screen_list_json", cdecl.}
proc nativeScreenCursorJson(): cstring {.importc: abiPrefix & "screen_cursor_json", cdecl.}
proc nativeScreenForWindowJson(windowId: int32): cstring {.importc: abiPrefix & "screen_for_window_json", cdecl.}
proc nativeWindowsListJson(): cstring {.importc: abiPrefix & "windows_list_json", cdecl.}
proc c_free(p: cstring) {.importc: "free", cdecl.}

# --- t:4 menu targets (menu.m; payload = the FULL bridge envelope, menu.m
# extracts "a"). menu.m builds the NSMenu + icons + click delivery itself. ---
proc nativeMenuSetFromPayload(payloadJson: cstring) {.importc: abiPrefix & "menu_set_from_payload", cdecl.}
proc nativeMenuShowContextFromPayload(payloadJson: cstring, windowId: int32) {.importc: abiPrefix & "menu_show_context_from_payload", cdecl.}

# --- t:4 tray targets (tray.m; payload = the FULL bridge envelope, tray.m
# extracts "a"). tray.m owns the NSStatusItem + icon + menu + click delivery. ---
proc nativeTrayCreateFromPayload(payloadJson: cstring) {.importc: abiPrefix & "tray_create_from_payload", cdecl.}
proc nativeTraySetIconFromPayload(payloadJson: cstring) {.importc: abiPrefix & "tray_set_icon_from_payload", cdecl.}
proc nativeTraySetTitleFromPayload(payloadJson: cstring) {.importc: abiPrefix & "tray_set_title_from_payload", cdecl.}
proc nativeTraySetTooltipFromPayload(payloadJson: cstring) {.importc: abiPrefix & "tray_set_tooltip_from_payload", cdecl.}
proc nativeTraySetMenuFromPayload(payloadJson: cstring) {.importc: abiPrefix & "tray_set_menu_from_payload", cdecl.}
proc nativeTrayDestroyFromPayload(payloadJson: cstring) {.importc: abiPrefix & "tray_destroy_from_payload", cdecl.}
proc nativeTrayAttachWindowFromPayload(payloadJson: cstring) {.importc: abiPrefix & "tray_attach_window_from_payload", cdecl.}
proc nativeTrayDetachWindowFromPayload(payloadJson: cstring) {.importc: abiPrefix & "tray_detach_window_from_payload", cdecl.}

# --- t:6 SYNC (sync.m, B7c). darwin_sync_handle's 2nd arg is the FULL RAW
# envelope ({t:6,m,a}); sync.m:233-242 unwraps the nested "a" itself. ---
proc nativeSyncHandle(action, payloadJson: cstring) {.importc: abiPrefix & "sync_handle", cdecl.}

# --- t:4 dock targets (dock.m; arg-based, not payload). ---
proc nativeDockShowIcon() {.importc: abiPrefix & "dock_show_icon", cdecl.}
proc nativeDockHideIcon() {.importc: abiPrefix & "dock_hide_icon", cdecl.}
proc nativeDockRemoveBadge() {.importc: abiPrefix & "dock_remove_badge", cdecl.}
proc nativeDockResetIcon() {.importc: abiPrefix & "dock_reset_icon", cdecl.}
proc nativeDockSetBadge(label: cstring) {.importc: abiPrefix & "dock_set_badge", cdecl.}
proc nativeDockBounce(bounceType: cint) {.importc: abiPrefix & "dock_bounce", cdecl.}
proc nativeDockSetProgress(permille, mode: cint) {.importc: abiPrefix & "dock_set_progress", cdecl.}
proc nativeDockSetIcon(imagePath: cstring) {.importc: abiPrefix & "dock_set_icon", cdecl.}

# --- t:4 panel (embedded-webview) targets (panel.m, already compiled; B6i).
# Arg-based; embed-gated at the head. ---
proc nativePanelCreate(windowId: int32, panelId, url: cstring, bridge: bool, partition: cstring) {.importc: abiPrefix & "panel_create", cdecl.}
proc nativePanelSetBounds(panelId: cstring, x, y, w, h: int32) {.importc: abiPrefix & "panel_set_bounds", cdecl.}
proc nativePanelLoadUrl(panelId, url: cstring) {.importc: abiPrefix & "panel_load_url", cdecl.}
proc nativePanelEvalJs(panelId, js: cstring) {.importc: abiPrefix & "panel_eval_js", cdecl.}
proc nativePanelPostMessage(panelId, dataJson: cstring) {.importc: abiPrefix & "panel_post_message", cdecl.}
proc nativePanelShow(panelId: cstring) {.importc: abiPrefix & "panel_show", cdecl.}
proc nativePanelHide(panelId: cstring) {.importc: abiPrefix & "panel_hide", cdecl.}
proc nativePanelReload(panelId: cstring) {.importc: abiPrefix & "panel_reload", cdecl.}
proc nativePanelGoBack(panelId: cstring) {.importc: abiPrefix & "panel_go_back", cdecl.}
proc nativePanelGoForward(panelId: cstring) {.importc: abiPrefix & "panel_go_forward", cdecl.}
proc nativePanelDestroy(panelId: cstring) {.importc: abiPrefix & "panel_destroy", cdecl.}

# --- t:4 native-chrome targets (sidebar/inspector/toolbar/popover .m, B8) ----
proc nativeSidebarToggle(windowId: int32) {.importc: abiPrefix & "sidebar_toggle", cdecl.}
proc nativeSidebarCollapse(windowId: int32) {.importc: abiPrefix & "sidebar_collapse", cdecl.}
proc nativeSidebarExpand(windowId: int32) {.importc: abiPrefix & "sidebar_expand", cdecl.}
proc nativeSidebarSetWidth(windowId: int32, width: int32) {.importc: abiPrefix & "sidebar_set_width", cdecl.}
# iPhone master-detail column reveal (iOS UISplitViewController). No-op on
# macOS/iPad-regular where both panes are always visible.
proc nativeSidebarShowContent(windowId: int32) {.importc: abiPrefix & "sidebar_show_content", cdecl.}
proc nativeSidebarShowSidebar(windowId: int32) {.importc: abiPrefix & "sidebar_show_sidebar", cdecl.}
proc nativeSidebarSetCollapsible(windowId: int32, canCollapse: bool) {.importc: abiPrefix & "sidebar_set_collapsible", cdecl.}
proc nativeSidebarSetResizable(windowId: int32, resizable: bool) {.importc: abiPrefix & "sidebar_set_resizable", cdecl.}
proc nativeSidebarSetPresentation(windowId: int32, mode: cstring) {.importc: abiPrefix & "sidebar_set_presentation", cdecl.}
proc nativeSidebarSetTitle(windowId: int32, title: cstring) {.importc: abiPrefix & "sidebar_set_title", cdecl.}
proc nativeInspectorToggle(windowId: int32) {.importc: abiPrefix & "inspector_toggle", cdecl.}
proc nativeInspectorCollapse(windowId: int32) {.importc: abiPrefix & "inspector_collapse", cdecl.}
proc nativeInspectorExpand(windowId: int32) {.importc: abiPrefix & "inspector_expand", cdecl.}
proc nativeInspectorSetWidth(windowId: int32, width: int32) {.importc: abiPrefix & "inspector_set_width", cdecl.}
proc nativeInspectorSetCollapsible(windowId: int32, canCollapse: bool) {.importc: abiPrefix & "inspector_set_collapsible", cdecl.}
proc nativeInspectorSetResizable(windowId: int32, resizable: bool) {.importc: abiPrefix & "inspector_set_resizable", cdecl.}
proc nativeInspectorSetTitle(windowId: int32, title: cstring) {.importc: abiPrefix & "inspector_set_title", cdecl.}
# D sub-cycle Task 1 — engine-aware DevTools show/close (devtools.m; CEF
# opens/closes real Chromium DevTools, WK no-ops — see devtools.m's header).
proc nativeDevtoolsOpen(windowId: int32) {.importc: abiPrefix & "devtools_open", cdecl.}
proc nativeDevtoolsClose(windowId: int32) {.importc: abiPrefix & "devtools_close", cdecl.}
proc nativeToolbarSetItems(windowPtr: pointer, toolbarJson: cstring, hostSlot: int32) {.importc: abiPrefix & "toolbar_set_items", cdecl.}
proc nativeToolbarUpdateItem(windowPtr: pointer, itemJson: cstring) {.importc: abiPrefix & "toolbar_update_item", cdecl.}
proc nativeToolbarRemove(windowPtr: pointer) {.importc: abiPrefix & "toolbar_remove", cdecl.}
proc nativePopoverCreate(windowPtr: pointer, popoverId: cstring, url: cstring,
                           width, height: int32, behavior: cstring,
                           hostSlot, popoverSlot: int32) {.importc: abiPrefix & "popover_create", cdecl.}
proc nativePopoverShow(popoverId: cstring, argsJson: cstring, senderSlot: int32) {.importc: abiPrefix & "popover_show", cdecl.}
proc nativePopoverHide(popoverId: cstring) {.importc: abiPrefix & "popover_hide", cdecl.}
proc nativePopoverDestroy(popoverId: cstring) {.importc: abiPrefix & "popover_destroy", cdecl.}

proc resolveWinId(a: JsonNode, key: string): int32 =
  ## parentId/modalId may be an int OR a "win-<n>" pointer-string; -1 if absent
  ## (router.zc:666-700). Mirrors the int-then-string resolution.
  if a.isNil: return -1
  let v = a{key}
  if v.isNil: return -1
  if v.kind == JInt: return v.getInt(-1).int32
  if v.kind == JString: return nativeWindowNumericIdForString(v.getStr("").cstring)
  -1

proc emitRouteChanged(win: int32, kind: string) =
  ## Build and broadcast a window:route-changed payload. Uses std/json for
  ## correct encoding. params is stored as a JSON string; re-parse to embed as
  ## an object (or null when absent). Mirrors dispatch_event_to_all broadcast
  ## path (no bitmask change).
  let url = routerCurrentUrl(win)
  let paramsStr = routerCurrentParams(win)
  let canBack = routerCanGoBack(win)
  let canFwd = routerCanGoForward(win)
  let windowIdStr = "win-" & $win
  let paramsNode: JsonNode =
    if paramsStr.len > 0:
      try: parseJson(paramsStr)
      except CatchableError: newJNull()
    else:
      newJNull()
  let payload = $(%*{
    "windowId": windowIdStr,
    "url": url,
    "params": paramsNode,
    "canGoBack": canBack,
    "canGoForward": canFwd,
    "kind": kind
  })
  dispatch_event_to_all("window:route-changed".cstring, payload.cstring)

proc zapp_router_pop_from_native*(windowId: int32) {.exportc, cdecl.} =
  ## Called by ios/routing.m's ZappRouteNavDelegate when the user pops a route VC
  ## (back button / edge swipe). Mutate routerstate + broadcast ONLY — no native
  ## op here. The native pop already happened (user gesture); calling a pop op
  ## would double-pop. The new per-action seam never calls this path programmatically.
  if routerPop(windowId):
    emitRouteChanged(windowId, "pop")

proc routeZapp(meth: string, windowId, id: int) =
  ## __zapp:* routes (router.zc:1352-1375).
  if meth == "__zapp:workers-list":
    let json = zapp_workers_registry_list_json()
    sendInvokeResponse(windowId, id, true, (if json.isNil: "[]" else: $json))
    return
  if meth == "__zapp:permissions":
    sendInvokeResponse(windowId, id, true, $permissions_bootstrap_json())
    return
  if meth == "__zapp:windows-list":
    let j = nativeWindowsListJson()
    let idsArr = (if j.isNil: "[]" else: $j)
    if not j.isNil: c_free(j)
    # Parse the array so we can embed it in {"ids":[...]}
    let idsNode = try: parseJson(idsArr) except CatchableError: newJArray()
    sendInvokeResponse(windowId, id, true, $(%*{"ids": idsNode}))
    return
  sendInvokeResponse(windowId, id, false, "UNKNOWN_ZAPP_METHOD")

proc routeApp(meth: string, a: JsonNode, windowId, id: int) =
  ## __app:* routes (router.zc:1377-1415). Login item (macOS); reply the bool as
  ## a JSON literal the runtime JSON.parses.
  if meth == "__app:setLoginItem":
    let enabled = (if a.isNil: false else: a{"enabled"}.getBool(false))
    let ok = nativeSetLoginItem(enabled)
    sendInvokeResponse(windowId, id, true, (if ok: "true" else: "false"))
    return
  if meth == "__app:getLoginItem":
    let ok = nativeGetLoginItem()
    sendInvokeResponse(windowId, id, true, (if ok: "true" else: "false"))
    return
  sendInvokeResponse(windowId, id, false, "UNKNOWN")

proc routeWorker(action: string, a: JsonNode, windowId: int) =
  ## t:5 WORKER envelope — port of native/app/router.zc:router_handle_worker
  ## (1182-1338). Fire-and-forget (no per-action reply).
  ## Args (`a`) come straight from the parsed envelope; nil-safe `a{"…"}` reads.
  let args = if a.isNil: newJObject() else: a
  case action
  of "create":
    # scriptUrl + workerId are required (zc returns if either absent).
    let scriptUrl = args{"scriptUrl"}.getStr("")
    let workerId = args{"workerId"}.getStr("")
    if scriptUrl.len == 0 or workerId.len == 0: return

    # Owner id derived from the window's string id ("win-<n>"); bail if the
    # window has no string id (zc: `if owner_id == NULL return`).
    let ownerId = nativeWindowIdString(windowId.int32)
    if ownerId.isNil: return

    # Per-worker engine selection (G8): string → id, mirroring router.zc:1228-1233.
    # Default -1 = "no preference" (the resolver picks the highest-priority
    # compiled engine — zjs here).
    var engine: int32 = -1
    case args{"engine"}.getStr("")
    of "bare-jsc": engine = 2
    of "bare-v8": engine = 3
    of "bare-quickjs": engine = 4
    of "bare-mqjs": engine = 5
    of "bare-hermes": engine = 6
    of "zjs": engine = 7
    else: discard

    # Optional display name (`new Worker(url, { name })`); "" = leave untouched.
    let name = args{"name"}.getStr("")

    # Dedicated worker.
    discard zapp_worker_registry_add_full_with_engine_and_name(
      workerId.cstring, ownerId, scriptUrl.cstring, engine, name.cstring)

    # app is unused in the zjs-only dispatcher (ABI parity only) — pass nil.
    discard worker_create(nil, scriptUrl.cstring, ownerId, workerId.cstring, engine)

  of "post":
    let workerId = args{"workerId"}.getStr("")
    if workerId.len == 0: return
    let dataJson = args{"data"}.getStr("")
    worker_post_message(workerId.cstring, dataJson.cstring)

  of "terminate":
    let workerId = args{"workerId"}.getStr("")
    if workerId.len == 0: return
    worker_terminate(workerId.cstring)
    zapp_worker_registry_remove(workerId.cstring)

  else: discard      # unknown worker action — no-op (matches the zc fallthrough)

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

when defined(zappIos):
  proc dialogAsyncReply(wid, rid: int32; ok: bool; json: cstring) {.cdecl.} =
    ## iOS dialog completion (UIKit main-thread callback). Extends the FS
    ## allowlist with any picked paths — a no-op for save/message results, which
    ## carry no `paths` array (dialogGrantedPaths returns @[]) — then resolves the
    ## invoke promise. Mirrors router.zc's dialog_open_response_cb_zc. Runs on the
    ## main thread (same as routeDialog), so ORC GC is safe; no foreign-thread init.
    let payload = if json.isNil: "null" else: $json
    if ok and not json.isNil:
      for p in dialogGrantedPaths(payload): fsGrantPath(p)
    sendInvokeResponse(wid.int, rid.int, ok, payload)

proc routeDialog(meth: string, a: JsonNode, windowId, id: int) =
  ## t:1 `__dialog:*`. macOS (else): sync darwin_dialog_* JSON variant, reply
  ## inline, grant picked paths to the FS session allowlist. iOS (zappIos): the
  ## pickers/alerts are async-presentation only — call the async variant and let
  ## dialogAsyncReply resolve the invoke + grant paths from the UIKit callback.
  let optionsJson = (if a.isNil: "{}" else: $a)
  when defined(zappIos):
    case meth
    of "__dialog:open":    dialogOpenFileAsync(windowId, id, optionsJson, dialogAsyncReply)
    of "__dialog:save":    dialogSaveFileAsync(windowId, id, optionsJson, dialogAsyncReply)
    of "__dialog:message": dialogMessageAsync(windowId, id, optionsJson, dialogAsyncReply)
    else: sendInvokeResponse(windowId, id, false, "UNKNOWN_DIALOG")
    # async: dialogAsyncReply replies later — no inline reply here.
  else:
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
    let j = nativeScreenListJson()
    if j.isNil: sendInvokeResponse(windowId, id, true, "[]")
    else:
      sendInvokeResponse(windowId, id, true, $j); c_free(j)
  of "__screen:cursor":
    let j = nativeScreenCursorJson()
    if j.isNil: sendInvokeResponse(windowId, id, false, "null")
    else:
      sendInvokeResponse(windowId, id, true, $j); c_free(j)
  of "__screen:forWindow":
    let ws = a{"windowId"}.getStr("")
    let target = (if ws.len > 0: nativeWindowNumericIdForString(ws.cstring) else: -1'i32)
    let j = nativeScreenForWindowJson(target)
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
    nativePanelCreate(windowId.int32, pid.cstring, url.cstring,
                        a{"bridge"}.getBool(false), partition.cstring)
  of "panelSetBounds":
    nativePanelSetBounds(pid.cstring, a{"x"}.getInt(0).int32, a{"y"}.getInt(0).int32,
                            a{"w"}.getInt(0).int32, a{"h"}.getInt(0).int32)
  of "panelLoadUrl":
    let url = a{"url"}.getStr("")
    nativePanelLoadUrl(pid.cstring, url.cstring)
  of "panelExecJs":
    let code = a{"code"}.getStr("")
    nativePanelEvalJs(pid.cstring, code.cstring)
  of "panelPostMessage":
    let data = a{"data"}.getStr("")
    nativePanelPostMessage(pid.cstring, data.cstring)
  of "panelShow": nativePanelShow(pid.cstring)
  of "panelHide": nativePanelHide(pid.cstring)
  of "panelReload": nativePanelReload(pid.cstring)
  of "panelBack": nativePanelGoBack(pid.cstring)
  of "panelForward": nativePanelGoForward(pid.cstring)
  of "panelDestroy": nativePanelDestroy(pid.cstring)
  else: return false      # "panel"-prefixed but not a real panel action
  return true

proc resolveAccessoryHost(windowId: int): int =
  ## A t:4 window/chrome op from inside a sidebar/inspector/popover pane carries
  ## the pane's transport slot as windowId, which is NOT a real NSWindow. Remap to
  ## the host via the id-string round-trip (router.zc:484-512). Real windows pass
  ## through unchanged.
  if not nativeWindowGetByNumericId(windowId.int32).isNil: return windowId
  let hostStr = nativeWindowIdString(windowId.int32)
  if hostStr.isNil: return windowId
  let hostId = nativeWindowNumericIdForString(hostStr).int
  if hostId >= 0: hostId else: windowId

proc routeWindowAction(action: string, a: JsonNode, rawWindowId: int, payload: string) =
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
      zapp_window_set_js_listener(rawWindowId.cint, evId.cint,
        (if action == "subscribe": 1.cint else: 0.cint))
    return

  # ready: the webview's bridge is up — signal bridge-ready (flushes window.m's
  # deferred first-focus event) + fire the native on_ready callback.
  if action == "ready":
    let wid = nativeWindowIdString(rawWindowId.int32)
    if not wid.isNil: nativeWindowSetBridgeReady(wid)
    zapp_window_trigger_on_ready(rawWindowId.int32)
    return

  # setDragRegion: targets the SENDER's own webview (not the host remap).
  # Each pane (sidebar, inspector, popover) has its own WKWebView with its own
  # mouseDownCanMoveWindow — the drag flag must land on the pane that sent it.
  # darwin_window_get_webview resolves the slot → that pane's WKWebView.
  if action == "setDragRegion":
    # Sender's OWN slot (not the accessory-host remap): each pane's webview has
    # its own mouseDownCanMoveWindow, so the drag flag must land on the pane that
    # sent it. darwin_window_get_webview resolves the slot → that pane's webview.
    let drag = a{"drag"}
    if not drag.isNil:
      nativeWebviewSetDragRegion(rawWindowId.int32, drag.getBool(false))
    return

  # beginDrag: Windows web-driven window drag (custom title bar). The JS gesture
  # only fires on Windows; start the OS move loop on the TOP-LEVEL window (resolve
  # the accessory host so a drag from a pane still moves the whole window).
  when defined(zappWindows):
    if action == "beginDrag":
      nativeWindowBeginDrag(resolveAccessoryHost(rawWindowId).int32)
      return

  # Accessory-pane sender resolution: window + chrome ops from inside a pane
  # target the host window (router.zc:484-512). subscribe/ready/setDragRegion
  # above keep the sender's own slot.
  let windowId = resolveAccessoryHost(rawWindowId)

  # --- id-based window ops (take the numeric id; self-guard in the .m) -------
  if action == "loadUrl":
    let url = (if a.isNil: "" else: a{"url"}.getStr(""))
    if url.len > 0: nativeWindowLoadUrl(windowId.int32, url.cstring)
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
    let pH = nativeWindowGetByNumericId(pNum)
    let mH = nativeWindowGetByNumericId(mNum)
    if pH.isNil or mH.isNil: return
    if action == "attachModal": nativeWindowAttachModal(pH, mH)
    else: nativeWindowDetachModal(pH, mH)
    return

  # --- app ops (platform.m; ungated) ----------------------------------------
  if action == "quit":
    nativeAppQuit(if a.isNil: false else: a{"force"}.getBool(false))
    return
  if action == "activate":
    nativeAppActivate()
    return
  if action == "setQuitGuard":
    nativeSetQuitGuard(if a.isNil: false else: a{"enabled"}.getBool(false))
    return

  # --- openExternal (shell:open — gated at the head) ------------------------
  if action == "openExternal":
    let url = (if a.isNil: "" else: a{"url"}.getStr(""))
    if url.len > 0: nativeOpenExternal(url.cstring)
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
    if action == "showItemInFolder": nativeShowItemInFolder(abs.cstring)
    elif action == "openPath": nativeOpenPath(abs.cstring)
    else: nativeTrashItem(abs.cstring)
    return

  # --- menu ops (menu.m parses the full payload; gated "menu" at the head) ---
  if action == "setMenu":
    nativeMenuSetFromPayload(payload.cstring)
    return
  if action == "showContextMenu":
    nativeMenuShowContextFromPayload(payload.cstring, windowId.int32)
    return

  # --- tray ops (tray.m parses the full payload; gated "tray" at the head) ---
  if action.startsWith("tray:"):
    case action
    of "tray:create": nativeTrayCreateFromPayload(payload.cstring)
    of "tray:setIcon": nativeTraySetIconFromPayload(payload.cstring)
    of "tray:setTitle": nativeTraySetTitleFromPayload(payload.cstring)
    of "tray:setTooltip": nativeTraySetTooltipFromPayload(payload.cstring)
    of "tray:setMenu": nativeTraySetMenuFromPayload(payload.cstring)
    of "tray:destroy": nativeTrayDestroyFromPayload(payload.cstring)
    of "tray:attachWindow": nativeTrayAttachWindowFromPayload(payload.cstring)
    of "tray:detachWindow": nativeTrayDetachWindowFromPayload(payload.cstring)
    else: discard      # unknown tray:* — no-op (matches the zc fallthrough)
    return

  # --- dock ops (dock.m; arg-based; gated "dock" at the head) ---
  if action.startsWith("dock:"):
    case action
    of "dock:showIcon": nativeDockShowIcon()
    of "dock:hideIcon": nativeDockHideIcon()
    of "dock:removeBadge": nativeDockRemoveBadge()
    of "dock:resetIcon": nativeDockResetIcon()
    of "dock:setBadge":
      let label = a{"label"}
      if not label.isNil: nativeDockSetBadge(label.getStr("").cstring)
    of "dock:bounce":
      nativeDockBounce(a{"type"}.getInt(0).cint)
    of "dock:setProgress":
      nativeDockSetProgress(a{"permille"}.getInt(-1).cint, a{"mode"}.getInt(0).cint)
    of "dock:setIcon":
      let path = a{"path"}
      if not path.isNil: nativeDockSetIcon(path.getStr("").cstring)
    else: discard
    return

  # --- panel (embedded-webview) ops (panel.m; embed-gated at the head) ------
  if routePanel(action, a, windowId): return

  # --- native-chrome ops (sidebar/inspector/toolbar/popover; ungated like window ops) ---
  if action.startsWith("sidebar:") or action.startsWith("inspector:"):
    # target = "windowId" arg (a real window) else the resolved sender host
    let widArg = a{"windowId"}.getStr("")
    let target = (if widArg.len > 0: nativeWindowNumericIdForString(widArg.cstring) else: windowId.int32)
    let width = a{"width"}.getInt(0).int32
    let flag = a{"value"}.getBool(true)  # setCollapsible/setResizable bool
    case action
    of "sidebar:toggle": nativeSidebarToggle(target)
    of "sidebar:collapse": nativeSidebarCollapse(target)
    of "sidebar:expand": nativeSidebarExpand(target)
    of "sidebar:setWidth": nativeSidebarSetWidth(target, width)
    of "sidebar:showContent": nativeSidebarShowContent(target)
    of "sidebar:showSidebar": nativeSidebarShowSidebar(target)
    of "sidebar:setCollapsible": nativeSidebarSetCollapsible(target, flag)
    of "sidebar:setResizable": nativeSidebarSetResizable(target, flag)
    of "sidebar:setPresentation": nativeSidebarSetPresentation(target, a{"mode"}.getStr("automatic").cstring)
    of "sidebar:setTitle": nativeSidebarSetTitle(target, a{"title"}.getStr("").cstring)
    of "inspector:toggle": nativeInspectorToggle(target)
    of "inspector:collapse": nativeInspectorCollapse(target)
    of "inspector:expand": nativeInspectorExpand(target)
    of "inspector:setWidth": nativeInspectorSetWidth(target, width)
    of "inspector:setCollapsible": nativeInspectorSetCollapsible(target, flag)
    of "inspector:setResizable": nativeInspectorSetResizable(target, flag)
    of "inspector:setTitle": nativeInspectorSetTitle(target, a{"title"}.getStr("").cstring)
    else: discard
    return

  # --- DevTools ops (devtools.m; D sub-cycle Task 1). Same target resolution
  # as sidebar:/inspector: above — "windowId" arg (a real window) else the
  # resolved sender host. Engine-aware: no-ops on WK (system Develop menu).
  if action.startsWith("devtools:"):
    let widArg = a{"windowId"}.getStr("")
    let target = (if widArg.len > 0: nativeWindowNumericIdForString(widArg.cstring) else: windowId.int32)
    case action
    of "devtools:open": nativeDevtoolsOpen(target)
    of "devtools:close": nativeDevtoolsClose(target)
    else: discard
    return

  if action.startsWith("toolbar:"):
    let widArg = a{"windowId"}.getStr("")
    let target = (if widArg.len > 0: nativeWindowNumericIdForString(widArg.cstring) else: windowId.int32)
    let h = nativeWindowGetByNumericId(target)
    if h.isNil: return
    case action
    of "toolbar:setItems":
      let tj = a{"toolbarJson"}.getStr("")
      if tj.len > 0: nativeToolbarSetItems(h, tj.cstring, target)
    of "toolbar:updateItem":
      let ij = a{"itemJson"}.getStr("")
      if ij.len > 0: nativeToolbarUpdateItem(h, ij.cstring)
    of "toolbar:remove": nativeToolbarRemove(h)
    else: discard
    return
  if action.startsWith("router:"):
    # target: explicit windowId arg takes priority (same resolution as toolbar:*)
    let widArg = (if a.isNil: "" else: a{"windowId"}.getStr(""))
    let target = (if widArg.len > 0: nativeWindowNumericIdForString(widArg.cstring) else: windowId.int32)
    if a.isNil or target < 0: return  # I1+M1: dead-window guard + nil-a guard (hasKey below is not nil-safe)
    case action
    of "router:push":
      let url = a{"url"}.getStr("")
      let params = (if a.hasKey("params"): $a["params"] else: "")
      # R2' per-route chrome (#771 T8): collect push options into one compact
      # JSON object. Keys: navbarHidden, title, toolbarJson. Built BEFORE
      # routerPush so routerstate persists it per entry — router:forward
      # replays the stored chrome when the entry is re-entered. Platform-
      # neutral build (pure JSON); only the seam call below is iOS-gated.
      var chrome = newJObject()
      let navbar = a{"navbar"}
      if not navbar.isNil and navbar.kind == JObject:
        chrome["navbarHidden"] = newJBool(navbar{"hidden"}.getBool(false))
      if a.hasKey("title") and a["title"].kind == JString:
        chrome["title"] = a["title"]
      if a.hasKey("toolbarJson") and a["toolbarJson"].kind == JString:
        chrome["toolbarJson"] = a["toolbarJson"]
      let chromeStr = (if chrome.len > 0: $chrome else: "")
      routerPush(target, url, params, chromeStr)
      emitRouteChanged(target, "push")
      when defined(zappIos):
        zapp_ios_push_route_vc(target, url.cstring, chromeStr.cstring)
    of "router:pop":
      if routerPop(target):
        emitRouteChanged(target, "pop")
        when defined(zappIos): zapp_ios_pop_route_vc(target)
    of "router:forward":
      if routerForward(target):
        emitRouteChanged(target, "forward")
        # Forward re-enters a route (depth increases) — native must push a route
        # VC for the forward URL, same seam as the push arm. routerstate was
        # mutated FIRST, so didShow sees nativeRouteDepth == wantRouteDepth
        # (no pop_from_native misfire), identical to the push flow.
        when defined(zappIos):
          let fwdUrl = routerCurrentUrl(target)   # new current = the forward entry
          # R2' (#771 T8): forward re-enters the entry with the SAME chrome it
          # was pushed with — routerstate persists chrome_json per entry, so a
          # back-then-forward onto a navbar:{hidden} route re-enters chrome-less
          # (and a titled/toolbar-override route keeps its chrome). Single-step
          # contract: routerForward advanced the cursor by exactly one, so this
          # pushes exactly one VC per forward call.
          let fwdChrome = routerCurrentChrome(target)
          zapp_ios_push_route_vc(target, fwdUrl.cstring, fwdChrome.cstring)
    of "router:replace":
      let url = a{"url"}.getStr("")
      let params = (if a.hasKey("params"): $a["params"] else: "")
      routerReplace(target, url, params)
      emitRouteChanged(target, "replace")
      # On iOS a lateral section switch happens after popToRoot (sidebar-pane.ts).
      # replace at depth > 1 pops back to content defensively (idempotent if already
      # at content); the content webview re-renders via emitRouteChanged above.
      when defined(zappIos): zapp_ios_pop_to_content(target)
    of "router:popToRoot":
      if routerPopToRoot(target):
        emitRouteChanged(target, "popToRoot")
        when defined(zappIos): zapp_ios_pop_to_content(target)
    else: discard
    return
  if action.startsWith("popover:"):
    let pid = a{"popoverId"}.getStr("")
    if pid.len == 0: return
    case action
    of "popover:show":
      let argsJson = $a
      nativePopoverShow(pid.cstring, argsJson.cstring, windowId.int32)
    of "popover:hide": nativePopoverHide(pid.cstring)
    of "popover:destroy": nativePopoverDestroy(pid.cstring)
    else: discard      # popover:create deferred (needs a Nim window-slot allocator)
    return

  # --- handle-based window ops (resolve the NSWindow from the numeric id) ---
  let h = nativeWindowGetByNumericId(windowId.int32)
  if h.isNil: return                       # window gone — nothing to act on
  case action
  of "show": nativeWindowShow(h)
  of "hide": nativeWindowHide(h)
  of "minimize": nativeWindowMinimize(h)
  of "maximize": nativeWindowMaximize(h)
  of "zoom": nativeWindowZoom(h)
  of "setFocus": nativeWindowFocus(h)
  of "close":
    # clear the close guard first (router.zc:652-654): force_close is just
    # [NSWindow close], which fires windowShouldClose:; a set guard would veto
    # it. Window.close() is the documented force path, so it must override.
    zapp_window_set_close_guard(windowId.cint, 0.cint)
    nativeWindowForceClose(h)
  of "setTitle":
    let title = a{"title"}
    if not title.isNil: nativeWindowSetTitle(h, title.getStr("").cstring)
  of "setSize":
    let w = a{"width"}; let ht = a{"height"}      # getFloat: zc stores numbers as
    if not w.isNil and not ht.isNil:              # double, truncates to int (parity)
      nativeWindowSetSize(h, w.getFloat(0).int32, ht.getFloat(0).int32)
  of "setPosition":
    let x = a{"x"}; let y = a{"y"}
    if not x.isNil and not y.isNil:
      nativeWindowSetPosition(h, x.getFloat(0).int32, y.getFloat(0).int32)
  of "setFullscreen":
    let on = a{"on"}
    if not on.isNil: nativeWindowSetFullscreen(h, on.getBool(false))
  of "setAlwaysOnTop":
    let on = a{"on"}
    if not on.isNil: nativeWindowSetAlwaysOnTop(h, on.getBool(false))
  else: discard

proc routeMessage*(msg: string, windowId: int) =
  ## Entry point for a single webview->native message. Owns parse + dispatch +
  ## response so app.nim's C-ABI handler stays a thin shim.
  let parsed = parseBridge(msg)
  if parsed.isNone: return
  let f = parsed.get

  if f.t == 3:        # EMIT envelope (protocol.zc:24) — JS Events.emit broadcast
    # f.a is already the parsed args object (the zc extracts "a" from the full
    # envelope; we already have it). Serialize it for the _onEvent payload;
    # "null" when absent. Mirrors router.zc:311-325 -> dispatch_event_to_all.
    dispatch_event_to_all(f.m.cstring, (if f.a.isNil: "null" else: $f.a).cstring)
    return

  # t:4 fire-and-forget window/app action — dispatched (+ permission-gated) in
  # routeWindowAction.
  if f.t == 4:
    routeWindowAction(f.m, f.a, windowId, msg)
    return

  # t:5 WORKER envelope (protocol.zc:26) — new Worker(url) lifecycle
  # (create/post/terminate), routed to routeWorker
  # (port of router.zc:router_handle_worker). Fire-and-forget.
  if f.t == 5:
    routeWorker(f.m, f.a, windowId)
    return

  if f.t == 6:        # SYNC envelope (protocol.zc:27) — Sync.wait/notify/cancel
    nativeSyncHandle(f.m.cstring, msg.cstring)   # msg = full raw envelope (== zc parsed.payload); sync.m unwraps "a"
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

  if f.m == "__router:state":
    # Resolve target window (from "windowId" arg, else the sender).
    let ws = (if f.a.isNil: "" else: f.a{"windowId"}.getStr(""))
    let target = (if ws.len > 0: nativeWindowNumericIdForString(ws.cstring) else: windowId.int32)
    let url = routerCurrentUrl(target)
    let paramsStr = routerCurrentParams(target)
    let paramsNode: JsonNode =
      if paramsStr.len > 0:
        try: parseJson(paramsStr)
        except CatchableError: newJNull()
      else:
        newJNull()
    let state = $(%*{
      "url": url,
      "params": paramsNode,
      "canGoBack": routerCanGoBack(target),
      "canGoForward": routerCanGoForward(target)
    })
    sendInvokeResponse(windowId, f.id, true, state)
    return

  if f.m == "__window:create":
    let o = WindowOptions(title: "Zapp")
    if not f.a.isNil: windowOptsApplyJson(o, f.a)
    let newId = createWindow(o).id   # createWindow calls routerSeed(id, "/") internally
    sendInvokeResponse(windowId, f.id, true, "{\"windowId\":\"win-" & $newId & "\"}")
    return

  if f.m == "__popover:create":
    var target = windowId.int32
    var url = ""
    var behavior = "transient"
    var pw: int32 = 320
    var ph: int32 = 400
    if not f.a.isNil and f.a.kind == JObject:
      let widv = f.a{"windowId"}
      if not widv.isNil and widv.kind == JString:
        let resolved = nativeWindowNumericIdForString(widv.getStr.cstring)
        if resolved >= 0: target = resolved
      let urlv = f.a{"url"}
      if not urlv.isNil and urlv.kind == JString: url = urlv.getStr
      let bv = f.a{"behavior"}
      if not bv.isNil and bv.kind == JString: behavior = bv.getStr
      let wv = f.a{"width"}
      if not wv.isNil and (wv.kind == JInt or wv.kind == JFloat): pw = wv.getFloat.int32
      let hv = f.a{"height"}
      if not hv.isNil and (hv.kind == JInt or hv.kind == JFloat): ph = hv.getFloat.int32
    if url.len > 0:
      let slot = allocSlot()
      let host = nativeWindowGetByNumericId(target)
      if host != nil:
        let pid = "pop-" & $slot
        nativePopoverCreate(host, pid.cstring, url.cstring, pw, ph,
                              behavior.cstring, target, slot)
        sendInvokeResponse(windowId, f.id, true, "{\"popoverId\":\"" & pid & "\"}")
        return
    sendInvokeResponse(windowId, f.id, false, "[zapp] popover: window not found or url missing")
    return

  let res = invokeService(f.m, f.a)
  if res.isSome:
    sendInvokeResponse(windowId, f.id, true, res.get)
  else:
    # Wire-identical to the inline sub-gate-A bridge: the error payload is the
    # bare token "NOT_FOUND" (bootstrap/webview.ts builds Error(payload) from it,
    # so the message must stay unquoted, not JSON-encoded).
    sendInvokeResponse(windowId, f.id, false, "NOT_FOUND")
