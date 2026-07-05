// CEF spike (Task 0) — the browser-process cef_app_t.
//
// Adapted from cefsimple_capi/simple_app.c, trimmed to the minimum for T0: a
// no-op cef_app_t with no browser-process handler. The reference creates the
// browser inside browser_process_handler.on_context_initialized; the spike
// instead drives browser creation from main.nim after cef_initialize returns
// (see cefSpikeMain), so the app itself carries no handlers here. calloc zeroes
// every cef_app_t getter (get_browser_process_handler, get_render_process_handler,
// on_before_command_line_processing, ...), which CEF reads as "not implemented".

#include <stdatomic.h>
#include <stdlib.h>

#include "cef_refcount.h"
#include "cef_spike.h"

typedef struct _cefspike_app_t {
  // MUST be first member — CEF base structure.
  cef_app_t app;
  atomic_int ref_count;
} cefspike_app_t;

// add_ref / release(free) / has_one_ref / has_at_least_one_ref.
IMPLEMENT_REFCOUNTING_SIMPLE(cefspike_app_t, cefspike_app, ref_count)

cef_app_t* cefspike_app_create(void) {
  cefspike_app_t* app = (cefspike_app_t*)calloc(1, sizeof(cefspike_app_t));
  CHECK(app);

  INIT_CEF_BASE_REFCOUNTED(&app->app.base, cef_app_t, cefspike_app);

  // No handlers wired for T0 — the browser is created from Nim after init.

  atomic_store(&app->ref_count, 1);
  return &app->app;
}
