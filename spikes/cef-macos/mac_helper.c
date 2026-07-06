// CEF spike (Task 0) — the macOS Helper subprocess entry point.
//
// Adapted from cefsimple_capi/process_helper_mac.c. CEF's multi-process model
// launches render/GPU/utility subprocesses from a separate Helper executable
// bundled at Contents/Frameworks/<name> Helper*.app (build.sh assembles five
// variants). This is that executable: it just runs cef_execute_process and
// returns its exit code.
//
// Divergences from the reference (spike, non-sandbox, direct-linked framework):
//   - No cef_scoped_sandbox_initialize (no_sandbox dev build).
//   - No cef_scoped_library_loader_* — the framework is linked directly with an
//     rpath (@executable_path/../../../ resolves to the main app's Frameworks/).
//
// Task 3 (custom scheme + brotli probe): a NULL cef_app_t is no longer fine.
// cef_app_t::on_register_custom_schemes is called in EVERY process — browser
// AND renderer/GPU/utility, i.e. THIS Helper executable — and CEF requires
// identical scheme registration everywhere. So this file now builds a
// minimal, standalone cef_app_t (same manual refcounting pattern as T0/T1's
// cef_app.c) whose ONLY job is that callback, wired to the same
// cefspike_register_zapp_scheme() the browser process uses (scheme_handler.c).
// It deliberately does NOT reuse cef_app.c's cefspike_app_create: that app's
// browser-process handler calls cefspike_pump_schedule (mac_entry.m, the ObjC
// external-message-pump owner), which this Helper build does not compile —
// pulling it in would mean linking Cocoa/NSApplication scaffolding into a
// renderer/GPU child process for no reason. scheme_handler.c has no such
// dependency, so it links cleanly here.

#include <stdatomic.h>
#include <stdlib.h>

#include "cef_refcount.h"
#include "cef_spike.h"

#include "include/capi/cef_app_capi.h"
#include "include/cef_api_hash.h"
#include "include/cef_version.h"

typedef struct _cefspike_helper_app_t {
  // MUST be first member — CEF base structure.
  cef_app_t app;
  atomic_int ref_count;
} cefspike_helper_app_t;

IMPLEMENT_REFCOUNTING_SIMPLE(cefspike_helper_app_t, cefspike_helper_app,
                             ref_count)

void CEF_CALLBACK cefspike_helper_app_on_register_custom_schemes(
    cef_app_t* self, cef_scheme_registrar_t* registrar) {
  (void)self;
  cefspike_register_zapp_scheme(registrar);
}

static cef_app_t* cefspike_helper_app_create(void) {
  cefspike_helper_app_t* app =
      (cefspike_helper_app_t*)calloc(1, sizeof(cefspike_helper_app_t));
  CHECK(app);

  INIT_CEF_BASE_REFCOUNTED(&app->app.base, cef_app_t, cefspike_helper_app);
  app->app.on_register_custom_schemes =
      cefspike_helper_app_on_register_custom_schemes;

  atomic_store(&app->ref_count, 1);
  return &app->app;
}

int main(int argc, char* argv[]) {
  // Configure the CEF API version before any other CEF call (guarded for older
  // SDKs that predate API versioning).
#ifdef CEF_API_VERSION
  cef_api_hash(CEF_API_VERSION, 0);
#endif

  cef_main_args_t main_args;
  main_args.argc = argc;
  main_args.argv = argv;

  cef_app_t* app = cefspike_helper_app_create();
  return cef_execute_process(&main_args, app, NULL);
}
