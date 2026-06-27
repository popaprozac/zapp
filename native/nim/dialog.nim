## Dialogs — native file/save/message dialogs. Port of native/dialog/dialog.zc
## (the native-first typed wrappers) PLUS the webview JSON-variant path that
## router.zc handles inline. MAIN-THREAD (webview->native); idiomatic Nim.
##
## NB: darwin_dialog_* are defined in native/platform/darwin/dialog.m, compiled
## by the build root (zapp.nim) — NOT self-compiled here, so dialog_test.nim can
## stub the C-ABI without pulling in dialog.m + Foundation (the B6a rule).
import std/json

# --- C-ABI: dialog.m (dialog.h) -------------------------------------------
# JSON variants — the webview path: options JSON in, result JSON out. The
# returned const char* is NOT caller-owned (do not free; mirrors router.zc).
proc darwin_dialog_open_file(o: cstring): cstring {.importc, cdecl.}
proc darwin_dialog_save_file(o: cstring): cstring {.importc, cdecl.}
proc darwin_dialog_message(o: cstring): cstring {.importc, cdecl.}
# Typed variants — the native-first path (dialog.zc parity).
proc darwin_dialog_open_file_typed(t: cstring, m, d: bool): cstring {.importc, cdecl.}
proc darwin_dialog_save_file_typed(t, n: cstring): cstring {.importc, cdecl.}
proc darwin_dialog_message_typed(m, t: cstring, s: cint): cint {.importc, cdecl.}
proc darwin_dialog_message_buttons_typed(m, t: cstring, s: cint,
                                         b1, b2, b3: cstring): cint {.importc, cdecl.}

# --- Webview JSON wrappers (used by router.nim's routeDialog) --------------
# Each takes the options object as a JSON string and returns the result JSON
# string ("" on a nil/error return — routeDialog maps that to UNKNOWN_DIALOG).
proc dialogOpenFile*(optionsJson: string): string =
  let r = darwin_dialog_open_file(optionsJson.cstring)
  if r.isNil: "" else: $r

proc dialogSaveFile*(optionsJson: string): string =
  let r = darwin_dialog_save_file(optionsJson.cstring)
  if r.isNil: "" else: $r

proc dialogMessage*(optionsJson: string): string =
  let r = darwin_dialog_message(optionsJson.cstring)
  if r.isNil: "" else: $r

# --- Granted-path extraction (mirror router.zc:router_grant_paths_from_dialog)
proc dialogGrantedPaths*(resultJson: string): seq[string] =
  ## Parse an open-dialog result `{"cancelled":bool,"paths":[...]}` and return the
  ## picked paths ([] if cancelled / malformed / empty). routeDialog fsGrantPath's
  ## each so FS/shell-path ops can act on a user-picked file.
  result = @[]
  var root: JsonNode
  try: root = parseJson(resultJson)
  except CatchableError: return
  if root.kind != JObject or root{"cancelled"}.getBool(false): return
  let paths = root{"paths"}
  if paths.isNil or paths.kind != JArray: return
  for p in paths:
    if p.kind == JString and p.getStr("").len > 0: result.add(p.getStr(""))

# --- Native-first typed wrappers (dialog.zc parity; no webview caller) -----
proc dialogOpenFileTyped*(title: string): string =
  $darwin_dialog_open_file_typed(title.cstring, false, false)
proc dialogOpenFolder*(title: string): string =
  $darwin_dialog_open_file_typed(title.cstring, false, true)
proc dialogSaveFileTyped*(title, defaultName: string): string =
  $darwin_dialog_save_file_typed(title.cstring, defaultName.cstring)
proc dialogMessageInfo*(msg: string): int =
  darwin_dialog_message_typed(msg.cstring, "".cstring, 0.cint).int
proc dialogMessageWithTitle*(msg, title: string, style: int): int =
  darwin_dialog_message_typed(msg.cstring, title.cstring, style.cint).int
proc dialogConfirm*(msg, btnYes, btnNo: string): int =
  darwin_dialog_message_buttons_typed(msg.cstring, "".cstring, 0.cint,
                                      btnYes.cstring, btnNo.cstring, "".cstring).int

# --- iOS async dialog path (compile-gated; -d:zappIos) ---------------------
# iOS dialogs are async-presentation only: UIDocumentPickerViewController (open/
# save) and UIAlertController (message) cannot run modally. The real impls live
# in native/platform/ios/dialog.m (darwin_dialog_*_async). The reply callback is
# supplied by router.nim (which owns sendInvokeResponse + the FS grant) — keeping
# dialog.nim a bridge-free leaf. options_json is consumed synchronously by the C
# fn before it returns (it parses to NSData up front), so the cstring is valid for
# the call's duration.
when defined(zappIos):
  type ZappDialogCb* = proc(wid, rid: int32; ok: bool; json: cstring) {.cdecl.}
  proc darwin_dialog_open_file_async(windowId, requestId: int32;
                                     optionsJson: cstring; cb: ZappDialogCb) {.importc, cdecl.}
  proc darwin_dialog_save_file_async(windowId, requestId: int32;
                                     optionsJson: cstring; cb: ZappDialogCb) {.importc, cdecl.}
  proc darwin_dialog_message_async(windowId, requestId: int32;
                                   optionsJson: cstring; cb: ZappDialogCb) {.importc, cdecl.}

  proc dialogOpenFileAsync*(windowId, id: int; optionsJson: string; cb: ZappDialogCb) =
    darwin_dialog_open_file_async(windowId.int32, id.int32, optionsJson.cstring, cb)
  proc dialogSaveFileAsync*(windowId, id: int; optionsJson: string; cb: ZappDialogCb) =
    darwin_dialog_save_file_async(windowId.int32, id.int32, optionsJson.cstring, cb)
  proc dialogMessageAsync*(windowId, id: int; optionsJson: string; cb: ZappDialogCb) =
    darwin_dialog_message_async(windowId.int32, id.int32, optionsJson.cstring, cb)
