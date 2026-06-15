## Nim build root. Compiles the untouched darwin platform layer, links the
## frameworks it needs, satisfies platform.m's cross-module callbacks, and boots
## the app. Window / bridge / service / worker layers land in later tasks.
##
## platform.m (`native/platform/darwin/platform.m`) is REUSED UNTOUCHED and
## reaches OUT to four symbols that have no home in the darwin .m layer. For this
## walking-skeleton boot we satisfy each with a Nim {.exportc, cdecl.} stub
## (NOT {.emit.} — Nim is the host language now). Each is marked TEMP with the
## task/module that replaces it.
{.passL: "-framework Cocoa -framework WebKit -framework CoreFoundation -framework JavaScriptCore -framework Security -framework IOKit -framework ServiceManagement".}
{.compile: ("../platform/darwin/platform.m", "-fobjc-arc").}

import app

# --- TEMP platform.m callback dependencies (replaced as their modules land) ---

# zapp_app_dispatch — was app/app_events.zc. Fans an app event out to native
# callbacks + workers; returns the count fired. No subscribers yet, so 0.
# TEMP until the event/dispatch layer lands.
proc zapp_app_dispatch(eventId: cint, data: cstring): cint {.exportc, cdecl.} =
  discard eventId
  discard data
  0

# service_run_shutdown_all — was service/service.zc. Tears down services in
# reverse order at quit. No services yet. TEMP until service.nim.
proc service_run_shutdown_all() {.exportc, cdecl.} =
  discard

# darwin_webview_eval_all — defined in webview.m; platform.m references it to
# broadcast JS into every webview. Not compiling webview.m yet, so stub it.
# TEMP until the webview/bridge layer lands.
proc darwin_webview_eval_all(js: cstring) {.exportc, cdecl.} =
  discard js

# darwin_notification_setup_delegate — defined in notification.m; platform.m
# calls it on launch to install the UN delegate. Not compiling notification.m
# yet. TEMP until the notification layer lands.
proc darwin_notification_setup_delegate() {.exportc, cdecl.} =
  discard

let a = newApp("Zapp Nim Skeleton")
quit(a.run())
