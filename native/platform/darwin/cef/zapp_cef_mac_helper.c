// Zapp CEF host (macOS) — the Helper subprocess entry point.
//
// Promoted from the proven GO spike (`spikes/cef-macos/mac_helper.c` — see
// docs/superpowers/specs/2026-07-05-cef-webengine-production-slice-macos-
// design.md and spikes/cef-macos/FINDINGS.md, Tasks 0/3/4). Renamed
// cefspike_ -> zapp_cef_, "spike" dropped. CEF's multi-process model launches
// render/GPU/utility subprocesses from a separate Helper executable bundled
// at Contents/Frameworks/<name> Helper*.app (T2's build step assembles the
// helper variants). This is that executable: it just runs
// cef_execute_process and returns its exit code.
//
// Divergences from the CEF reference (cefsimple_capi/process_helper_mac.c),
// unchanged from the spike:
//   - No cef_scoped_sandbox_initialize (no_sandbox dev build).
//   - No cef_scoped_library_loader_* — the framework is linked directly with
//     an rpath (@executable_path/../../../ resolves to the main app's
//     Frameworks/).
//
// cef_app_t::on_register_custom_schemes is called in EVERY process — browser
// AND renderer/GPU/utility, i.e. THIS Helper executable — and CEF requires
// identical scheme registration everywhere. So this file builds a minimal,
// standalone cef_app_t (same manual refcounting pattern as zapp_cef_app.c)
// whose ONLY job is that callback, wired to the same
// zapp_cef_register_zapp_scheme() the browser process uses
// (zapp_cef_scheme_handler.c). It deliberately does NOT reuse
// zapp_cef_app.c's zapp_cef_app_create: that app's browser-process handler
// calls zapp_cef_pump_schedule (zapp_cef_mac_entry.m, the ObjC
// external-message-pump owner), which this Helper build does not compile —
// pulling it in would mean linking Cocoa/NSApplication scaffolding into a
// renderer/GPU child process for no reason. zapp_cef_scheme_handler.c has no
// such dependency, so it links cleanly here.
//
// The RENDER-process half of the `zapp` bridge runs HERE. The render
// subprocess IS this Helper executable, so this app also returns a
// render-process handler (zapp_cef_bridge.c) from get_render_process_handler
// — CEF calls that on the render main thread and drives the handler's
// on_context_created (bootstrap + V8 binding) and
// on_process_message_received ("zapp:result"). zapp_cef_bridge.c is compiled
// into this Helper build (see T2's build integration); it, like
// zapp_cef_scheme_handler.c, has no ObjC/Cocoa dependency.

#include <stdatomic.h>
#include <stdlib.h>

#include "zapp_cef_refcount.h"
#include "zapp_cef.h"

#include "include/capi/cef_app_capi.h"
#include "include/cef_api_hash.h"
#include "include/cef_version.h"

typedef struct _zapp_cef_helper_app_t {
  // MUST be first member — CEF base structure.
  cef_app_t app;
  atomic_int ref_count;
  cef_render_process_handler_t* rph;  // owned; released on the app's last release.
} zapp_cef_helper_app_t;

// add_ref / has_one_ref / has_at_least_one_ref (release is hand-written below
// so it can release the owned render-process handler first — same pattern as
// zapp_cef_app.c's zapp_cef_app).
IMPLEMENT_REFCOUNTING_MANUAL(zapp_cef_helper_app_t, zapp_cef_helper_app,
                             ref_count)

int CEF_CALLBACK zapp_cef_helper_app_release(cef_base_ref_counted_t* self) {
  zapp_cef_helper_app_t* app = (zapp_cef_helper_app_t*)self;
  int count = atomic_fetch_sub(&app->ref_count, 1) - 1;
  if (count == 0) {
    if (app->rph) {
      app->rph->base.release(&app->rph->base);
    }
    free(app);
    return 1;
  }
  return 0;
}

void CEF_CALLBACK zapp_cef_helper_app_on_register_custom_schemes(
    cef_app_t* self, cef_scheme_registrar_t* registrar) {
  (void)self;
  zapp_cef_register_zapp_scheme(registrar);
}

// Hand CEF the bridge's render-process handler (zapp_cef_bridge.c). Called on
// the render main thread.
cef_render_process_handler_t* CEF_CALLBACK
zapp_cef_helper_app_get_render_process_handler(cef_app_t* self) {
  zapp_cef_helper_app_t* app = (zapp_cef_helper_app_t*)self;
  if (app->rph) {
    // Add a reference before returning — CEF releases it when done.
    app->rph->base.add_ref(&app->rph->base);
    return app->rph;
  }
  return NULL;
}

static cef_app_t* zapp_cef_helper_app_create(void) {
  zapp_cef_helper_app_t* app =
      (zapp_cef_helper_app_t*)calloc(1, sizeof(zapp_cef_helper_app_t));
  CHECK(app);

  INIT_CEF_BASE_REFCOUNTED(&app->app.base, cef_app_t, zapp_cef_helper_app);
  app->app.on_register_custom_schemes =
      zapp_cef_helper_app_on_register_custom_schemes;
  app->app.get_render_process_handler =
      zapp_cef_helper_app_get_render_process_handler;

  app->rph = zapp_cef_render_process_handler_create();
  CHECK(app->rph);

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

  cef_app_t* app = zapp_cef_helper_app_create();
  return cef_execute_process(&main_args, app, NULL);
}
