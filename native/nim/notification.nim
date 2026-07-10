## Notifications — webview Notification surface. Ports the JSON/async variants
## router.zc handles inline (native/notification/notification.zc is the separate
## native-first typed API, deferred). MAIN-THREAD (webview->native); idiomatic.
##
## NB: darwin_notification_* are defined in native/platform/darwin/notification.m,
## compiled by the build root (zapp.nim) — NOT self-compiled here (the B6a rule).
import bridge          # sendInvokeResponse — the async callback bridges to it
import nativeabi

# Async invoke-response callback signature: void(wid, rid, ok, json).
type NotifCallback = proc(wid, rid: int32, ok: bool, json: cstring) {.cdecl.}

# --- C-ABI: notification.m (notification.h + router.zc inline externs) -----
# Async (resolve later via the callback):
proc nativeNotificationRequestPermission(wid, rid: int32, cb: NotifCallback) {.importc: abiPrefix & "notification_request_permission", cdecl.}
proc nativeNotificationShow(opts: cstring, wid, rid: int32, cb: NotifCallback) {.importc: abiPrefix & "notification_show", cdecl.}
proc nativeNotificationSchedule(opts: cstring, wid, rid: int32, cb: NotifCallback) {.importc: abiPrefix & "notification_schedule", cdecl.}
# Sync:
proc nativeNotificationGetPermission(): cstring {.importc: abiPrefix & "notification_get_permission", cdecl.}
proc nativeNotificationCancel(id: cstring) {.importc: abiPrefix & "notification_cancel", cdecl.}
proc nativeNotificationCancelAll() {.importc: abiPrefix & "notification_cancel_all", cdecl.}
proc nativeNotificationRegisterCategory(catId, actionsJson: cstring) {.importc: abiPrefix & "notification_register_category", cdecl.}
proc nativeNotificationRemoveCategory(catId: cstring) {.importc: abiPrefix & "notification_remove_category", cdecl.}
proc nativeNotificationRemoveDeliveredJson(json: cstring) {.importc: abiPrefix & "notification_remove_delivered_json", cdecl.}
proc nativeNotificationRemoveAllDelivered() {.importc: abiPrefix & "notification_remove_all_delivered", cdecl.}
proc nativeNotificationUpdateJson(json: cstring) {.importc: abiPrefix & "notification_update_json", cdecl.}
proc nativeNotificationSetBridgeReady() {.importc: abiPrefix & "notification_set_bridge_ready", cdecl.}

# Async invoke-response callback (mirror router.zc's file-scope notif_response_cb):
# notification.m calls this (on the main thread — it marshals) once the prompt /
# post resolves; bridge it to the webview invoke reply. Plain cdecl proc (passed
# by address as the C function pointer); no exportc needed (no .m references it
# by name — the async fns receive it as a param).
proc notifResponseCb(wid, rid: int32, ok: bool, json: cstring) {.cdecl.} =
  sendInvokeResponse(wid.int, rid.int, ok, (if json.isNil: "" else: $json))

# --- Thin wrappers (used by router.nim's routeNotification) ----------------
proc notifRequestPermission*(windowId, id: int) =
  nativeNotificationRequestPermission(windowId.int32, id.int32, notifResponseCb)
proc notifShow*(optionsJson: string, windowId, id: int) =
  nativeNotificationShow(optionsJson.cstring, windowId.int32, id.int32, notifResponseCb)
proc notifSchedule*(optionsJson: string, windowId, id: int) =
  nativeNotificationSchedule(optionsJson.cstring, windowId.int32, id.int32, notifResponseCb)
proc notifGetPermission*(): string =
  let r = nativeNotificationGetPermission()
  if r.isNil: "" else: $r
proc notifCancel*(id: string) = nativeNotificationCancel(id.cstring)
proc notifCancelAll*() = nativeNotificationCancelAll()
proc notifRegisterCategory*(catId, actionsJson: string) =
  nativeNotificationRegisterCategory(catId.cstring, actionsJson.cstring)
proc notifRemoveCategory*(catId: string) = nativeNotificationRemoveCategory(catId.cstring)
proc notifRemoveDelivered*(json: string) = nativeNotificationRemoveDeliveredJson(json.cstring)
proc notifRemoveAllDelivered*() = nativeNotificationRemoveAllDelivered()
proc notifUpdate*(json: string) = nativeNotificationUpdateJson(json.cstring)
proc notifSetBridgeReady*() = nativeNotificationSetBridgeReady()
