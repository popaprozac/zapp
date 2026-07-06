// Zapp CEF host (macOS) — the browser-process cef_app_t.
//
// Promoted from the proven GO spike (`spikes/cef-macos/cef_app.c` — see
// docs/superpowers/specs/2026-07-05-cef-webengine-production-slice-macos-
// design.md and spikes/cef-macos/FINDINGS.md, Tasks 1 + 3). Renamed
// cefspike_ -> zapp_cef_, "spike" dropped; the CEF machinery itself is
// unchanged (per this task's brief: copy + rename, don't rewrite).
//
// Two handler surfaces (originally the spike's message-loop-coexistence risk
// gate, Task 1):
//
//   1. on_before_command_line_processing — appends --use-mock-keychain for
//      the browser process so Chromium's OSCrypt "Safe Storage" keychain
//      prompt doesn't interrupt a dev run. PRODUCTION SEED: kept dev-only per
//      the brief — a real webEngine:"chromium" ship needs an actual
//      encrypted-storage policy, not a mock keychain; this convenience
//      should be gated out of release builds by a later task.
//
//   2. get_browser_process_handler — returns a cef_browser_process_handler_t
//      whose on_schedule_message_pump_work() is the heart of CEF's EXTERNAL
//      MESSAGE PUMP: called from any thread when CEF has queued work for the
//      browser UI thread, it hands the requested delay to
//      zapp_cef_pump_schedule (zapp_cef_mac_entry.m), which schedules a
//      cef_do_message_loop_work() on the main NSRunLoop. This is what lets
//      NSApplication own the loop (via [NSApp run]) while CEF is pumped
//      cooperatively — see zapp_cef_mac_entry.m for the pump.
//
// Two more handler surfaces (originally Task 3 — custom scheme + brotli
// probe; the scheme now serves Zapp's real embedded-asset table instead of
// the spike's two hardcoded assets, see zapp_cef_scheme_handler.c):
//
//   3. on_register_custom_schemes — CEF calls this in EVERY process, before
//      init, and requires identical registration across all of them.
//      Forwards to zapp_cef_register_zapp_scheme (zapp_cef_scheme_handler.c),
//      which is also wired into a separate minimal cef_app_t in
//      zapp_cef_mac_helper.c for the Helper subprocess (that file can't
//      reuse THIS cef_app_t: the browser-process handler below references
//      the ObjC pump, which the Helper build does not compile).
//
//   4. the browser-process handler's on_context_initialized — fires once,
//      synchronously, after cef_initialize's internal setup completes.
//      Installs the "zapp" scheme handler factory
//      (zapp_cef_install_scheme_handler_factory, zapp_cef_scheme_handler.c)
//      — this must happen AFTER init (the factory registers with the global
//      request context, which does not exist before init) but the scheme
//      itself must be registered BEFORE init (step 3), hence the two
//      separate hooks.

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "zapp_cef_refcount.h"
#include "zapp_cef.h"

// cef_app_capi.h (via zapp_cef.h) already pulls in the browser-process-
// handler and command-line capi headers, so both struct layouts are
// available here.

// ---------------------------------------------------------------------------
// Browser-process handler — owns the external-message-pump scheduling callback.
// ---------------------------------------------------------------------------

typedef struct _zapp_cef_bph_t {
  // MUST be first member — CEF base structure.
  cef_browser_process_handler_t handler;
  atomic_int ref_count;
} zapp_cef_bph_t;

IMPLEMENT_REFCOUNTING_SIMPLE(zapp_cef_bph_t, zapp_cef_bph, ref_count)

// Called from ANY thread when CEF has scheduled work for the browser main (UI)
// thread. |delay_ms| <= 0 means "soon"; > 0 means "after this delay, cancelling
// any pending pump". We forward to the ObjC pump, which hops to the main thread
// and drives cef_do_message_loop_work() from the NSRunLoop.
void CEF_CALLBACK zapp_cef_bph_on_schedule_message_pump_work(
    cef_browser_process_handler_t* self, int64_t delay_ms) {
  (void)self;
  zapp_cef_pump_schedule(delay_ms);
}

// Fires once, synchronously, after CEF's internal init completes. Installs
// the "zapp" scheme handler factory (the scheme ITSELF was already
// registered pre-init via on_register_custom_schemes below).
void CEF_CALLBACK zapp_cef_bph_on_context_initialized(
    cef_browser_process_handler_t* self) {
  (void)self;
  zapp_cef_install_scheme_handler_factory();
}

static zapp_cef_bph_t* zapp_cef_bph_create(void) {
  zapp_cef_bph_t* bph = (zapp_cef_bph_t*)calloc(1, sizeof(zapp_cef_bph_t));
  CHECK(bph);

  INIT_CEF_BASE_REFCOUNTED(&bph->handler.base, cef_browser_process_handler_t,
                           zapp_cef_bph);
  bph->handler.on_schedule_message_pump_work =
      zapp_cef_bph_on_schedule_message_pump_work;
  bph->handler.on_context_initialized = zapp_cef_bph_on_context_initialized;

  atomic_store(&bph->ref_count, 1);
  return bph;
}

// ---------------------------------------------------------------------------
// App.
// ---------------------------------------------------------------------------

typedef struct _zapp_cef_app_t {
  // MUST be first member — CEF base structure.
  cef_app_t app;
  atomic_int ref_count;
  zapp_cef_bph_t* bph;  // owned; released on the app's last release.
} zapp_cef_app_t;

// add_ref / has_one_ref / has_at_least_one_ref (release is hand-written below
// so it can release the owned browser-process handler first).
IMPLEMENT_REFCOUNTING_MANUAL(zapp_cef_app_t, zapp_cef_app, ref_count)

int CEF_CALLBACK zapp_cef_app_release(cef_base_ref_counted_t* self) {
  zapp_cef_app_t* app = (zapp_cef_app_t*)self;
  int count = atomic_fetch_sub(&app->ref_count, 1) - 1;
  if (count == 0) {
    if (app->bph) {
      app->bph->handler.base.release(&app->bph->handler.base);
    }
    free(app);
    return 1;
  }
  return 0;
}

// Append --use-mock-keychain for the browser process (process_type is NULL for
// the browser process; non-NULL/non-empty for renderer/GPU/utility children).
// PRODUCTION SEED (dev-only): see the file header — a shipping
// webEngine:"chromium" build needs a real encrypted-storage policy instead.
void CEF_CALLBACK zapp_cef_app_on_before_command_line_processing(
    cef_app_t* self, const cef_string_t* process_type,
    cef_command_line_t* command_line) {
  (void)self;
  if (process_type != NULL && process_type->length != 0) {
    return;  // child process — leave its command line alone.
  }
  const char* name = "use-mock-keychain";
  cef_string_t sw;
  memset(&sw, 0, sizeof(sw));
  cef_string_utf8_to_utf16(name, strlen(name), &sw);
  command_line->append_switch(command_line, &sw);
  cef_string_clear(&sw);
}

cef_browser_process_handler_t* CEF_CALLBACK
zapp_cef_app_get_browser_process_handler(cef_app_t* self) {
  zapp_cef_app_t* app = (zapp_cef_app_t*)self;
  if (app->bph) {
    // Add a reference before returning — CEF releases it when done.
    app->bph->handler.base.add_ref(&app->bph->handler.base);
    return &app->bph->handler;
  }
  return NULL;
}

// Called in EVERY process, before init. Forwards to the shared,
// self-contained registration function in zapp_cef_scheme_handler.c (also
// wired into the Helper subprocess's own minimal cef_app_t — see
// zapp_cef_mac_helper.c).
void CEF_CALLBACK zapp_cef_app_on_register_custom_schemes(
    cef_app_t* self, cef_scheme_registrar_t* registrar) {
  (void)self;
  zapp_cef_register_zapp_scheme(registrar);
}

cef_app_t* zapp_cef_app_create(void) {
  zapp_cef_app_t* app = (zapp_cef_app_t*)calloc(1, sizeof(zapp_cef_app_t));
  CHECK(app);

  INIT_CEF_BASE_REFCOUNTED(&app->app.base, cef_app_t, zapp_cef_app);
  app->app.on_before_command_line_processing =
      zapp_cef_app_on_before_command_line_processing;
  app->app.get_browser_process_handler =
      zapp_cef_app_get_browser_process_handler;
  app->app.on_register_custom_schemes = zapp_cef_app_on_register_custom_schemes;

  app->bph = zapp_cef_bph_create();
  CHECK(app->bph);

  atomic_store(&app->ref_count, 1);
  return &app->app;
}
