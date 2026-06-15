## THROWAWAY (deleted in a later task). Proves Nim {.compile.}s an ObjC .m with
## ARC, links Cocoa, and calls into it. Compiles only platform.m here.
##
## platform.m references three system frameworks beyond Cocoa (IOKit power
## sources, ServiceManagement login items) plus a handful of cross-module
## symbols that live OUTSIDE the darwin .m layer:
##   - zapp_app_dispatch        -> app/app_events.zc  (Zen-C, no .m)
##   - service_run_shutdown_all -> service/service.zc  (Zen-C, no .m)
##   - darwin_notification_setup_delegate -> notification.m
##   - darwin_webview_eval_all  -> webview.m
## Pulling in notification.m/webview.m would cascade the whole platform
## subsystem AND still leave the two .zc-only symbols unresolved. For a build-
## mechanism smoke test we stub all four (emit C below). This proves the
## {.compile.} ObjC+ARC path links and runs; it does NOT prove the full app.
{.passL: "-framework Cocoa -framework CoreFoundation " &
         "-framework IOKit -framework ServiceManagement".}
{.compile: ("../platform/darwin/platform.m", "-fobjc-arc").}

# Minimal C stubs for cross-module symbols platform.m references but that
# live in .zc / other .m files we deliberately don't compile here.
{.emit: """
int  zapp_app_dispatch(int event_id, const char* data) { (void)event_id; (void)data; return 0; }
void service_run_shutdown_all(void) {}
void darwin_notification_setup_delegate(void) {}
void darwin_webview_eval_all(const char* js) { (void)js; }
""".}

import platform

platformInit("nim-smoke")
echo "darwin_platform_init returned — ObjC-via-Nim build works"
# Do NOT call platformRun (it blocks in NSApp run); init proves linkage.
