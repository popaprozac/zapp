## Notifications — webview Notification surface. Ports the JSON/async variants
## router.zc handles inline (native/notification/notification.zc is the separate
## native-first typed API, deferred). MAIN-THREAD (webview->native); idiomatic.
##
## NB: darwin_notification_* are defined in native/platform/darwin/notification.m,
## compiled by the build root (zapp.nim) — NOT self-compiled here (the B6a rule).
import bridge          # sendInvokeResponse — the async callback bridges to it

# Async invoke-response callback signature: void(wid, rid, ok, json).
type NotifCallback = proc(wid, rid: int32, ok: bool, json: cstring) {.cdecl.}

# --- C-ABI: notification.m (notification.h + router.zc inline externs) -----
# Async (resolve later via the callback):
proc darwin_notification_request_permission(wid, rid: int32, cb: NotifCallback) {.importc, cdecl.}
proc darwin_notification_show(opts: cstring, wid, rid: int32, cb: NotifCallback) {.importc, cdecl.}
proc darwin_notification_schedule(opts: cstring, wid, rid: int32, cb: NotifCallback) {.importc, cdecl.}
# Sync:
proc darwin_notification_get_permission(): cstring {.importc, cdecl.}
proc darwin_notification_cancel(id: cstring) {.importc, cdecl.}
proc darwin_notification_cancel_all() {.importc, cdecl.}
proc darwin_notification_register_category(catId, actionsJson: cstring) {.importc, cdecl.}
proc darwin_notification_remove_category(catId: cstring) {.importc, cdecl.}
proc darwin_notification_remove_delivered_json(json: cstring) {.importc, cdecl.}
proc darwin_notification_remove_all_delivered() {.importc, cdecl.}
proc darwin_notification_update_json(json: cstring) {.importc, cdecl.}
proc darwin_notification_set_bridge_ready() {.importc, cdecl.}

# Async invoke-response callback (mirror router.zc's file-scope notif_response_cb):
# notification.m calls this (on the main thread — it marshals) once the prompt /
# post resolves; bridge it to the webview invoke reply. Plain cdecl proc (passed
# by address as the C function pointer); no exportc needed (no .m references it
# by name — the async fns receive it as a param).
proc notifResponseCb(wid, rid: int32, ok: bool, json: cstring) {.cdecl.} =
  sendInvokeResponse(wid.int, rid.int, ok, (if json.isNil: "" else: $json))

# --- Thin wrappers (used by router.nim's routeNotification) ----------------
proc notifRequestPermission*(windowId, id: int) =
  darwin_notification_request_permission(windowId.int32, id.int32, notifResponseCb)
proc notifShow*(optionsJson: string, windowId, id: int) =
  darwin_notification_show(optionsJson.cstring, windowId.int32, id.int32, notifResponseCb)
proc notifSchedule*(optionsJson: string, windowId, id: int) =
  darwin_notification_schedule(optionsJson.cstring, windowId.int32, id.int32, notifResponseCb)
proc notifGetPermission*(): string =
  let r = darwin_notification_get_permission()
  if r.isNil: "" else: $r
proc notifCancel*(id: string) = darwin_notification_cancel(id.cstring)
proc notifCancelAll*() = darwin_notification_cancel_all()
proc notifRegisterCategory*(catId, actionsJson: string) =
  darwin_notification_register_category(catId.cstring, actionsJson.cstring)
proc notifRemoveCategory*(catId: string) = darwin_notification_remove_category(catId.cstring)
proc notifRemoveDelivered*(json: string) = darwin_notification_remove_delivered_json(json.cstring)
proc notifRemoveAllDelivered*() = darwin_notification_remove_all_delivered()
proc notifUpdate*(json: string) = darwin_notification_update_json(json.cstring)
proc notifSetBridgeReady*() = darwin_notification_set_bridge_ready()
