// CEF spike (Task 1) — the browser-process cef_app_t.
//
// Adapted from cefsimple_capi/simple_app.c. T0 shipped a no-op cef_app_t (no
// browser-process handler): the browser is created from main.nim after
// cef_initialize returns (see cefSpikeMain), so the app carried no handlers.
//
// Task 1 (message-loop coexistence risk gate) adds two handler surfaces:
//
//   1. on_before_command_line_processing — appends --use-mock-keychain for the
//      browser process so Chromium's OSCrypt "Safe Storage" keychain prompt
//      doesn't interrupt the dev run (human hit it at GATE 0). PRODUCTION SEED:
//      real webEngine:"chromium" needs an actual encrypted-storage policy, not
//      a mock keychain — this is a dev-run convenience only.
//
//   2. get_browser_process_handler — returns a cef_browser_process_handler_t
//      whose on_schedule_message_pump_work() is the heart of CEF's EXTERNAL
//      MESSAGE PUMP: called from any thread when CEF has queued work for the
//      browser UI thread, it hands the requested delay to cefspike_pump_schedule
//      (mac_entry.m), which schedules a cef_do_message_loop_work() on the main
//      NSRunLoop. This is what lets NSApplication own the loop (via [NSApp run])
//      while CEF is pumped cooperatively — see mac_entry.m for the pump.

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "cef_refcount.h"
#include "cef_spike.h"

// cef_app_capi.h (via cef_spike.h) already pulls in the browser-process-handler
// and command-line capi headers, so both struct layouts are available here.

// ---------------------------------------------------------------------------
// Browser-process handler — owns the external-message-pump scheduling callback.
// ---------------------------------------------------------------------------

typedef struct _cefspike_bph_t {
  // MUST be first member — CEF base structure.
  cef_browser_process_handler_t handler;
  atomic_int ref_count;
} cefspike_bph_t;

IMPLEMENT_REFCOUNTING_SIMPLE(cefspike_bph_t, cefspike_bph, ref_count)

// Called from ANY thread when CEF has scheduled work for the browser main (UI)
// thread. |delay_ms| <= 0 means "soon"; > 0 means "after this delay, cancelling
// any pending pump". We forward to the ObjC pump, which hops to the main thread
// and drives cef_do_message_loop_work() from the NSRunLoop.
void CEF_CALLBACK cefspike_bph_on_schedule_message_pump_work(
    cef_browser_process_handler_t* self, int64_t delay_ms) {
  (void)self;
  cefspike_pump_schedule(delay_ms);
}

static cefspike_bph_t* cefspike_bph_create(void) {
  cefspike_bph_t* bph = (cefspike_bph_t*)calloc(1, sizeof(cefspike_bph_t));
  CHECK(bph);

  INIT_CEF_BASE_REFCOUNTED(&bph->handler.base, cef_browser_process_handler_t,
                           cefspike_bph);
  bph->handler.on_schedule_message_pump_work =
      cefspike_bph_on_schedule_message_pump_work;

  atomic_store(&bph->ref_count, 1);
  return bph;
}

// ---------------------------------------------------------------------------
// App.
// ---------------------------------------------------------------------------

typedef struct _cefspike_app_t {
  // MUST be first member — CEF base structure.
  cef_app_t app;
  atomic_int ref_count;
  cefspike_bph_t* bph;  // owned; released on the app's last release.
} cefspike_app_t;

// add_ref / has_one_ref / has_at_least_one_ref (release is hand-written below
// so it can release the owned browser-process handler first).
IMPLEMENT_REFCOUNTING_MANUAL(cefspike_app_t, cefspike_app, ref_count)

int CEF_CALLBACK cefspike_app_release(cef_base_ref_counted_t* self) {
  cefspike_app_t* app = (cefspike_app_t*)self;
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
void CEF_CALLBACK cefspike_app_on_before_command_line_processing(
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
cefspike_app_get_browser_process_handler(cef_app_t* self) {
  cefspike_app_t* app = (cefspike_app_t*)self;
  if (app->bph) {
    // Add a reference before returning — CEF releases it when done.
    app->bph->handler.base.add_ref(&app->bph->handler.base);
    return &app->bph->handler;
  }
  return NULL;
}

cef_app_t* cefspike_app_create(void) {
  cefspike_app_t* app = (cefspike_app_t*)calloc(1, sizeof(cefspike_app_t));
  CHECK(app);

  INIT_CEF_BASE_REFCOUNTED(&app->app.base, cef_app_t, cefspike_app);
  app->app.on_before_command_line_processing =
      cefspike_app_on_before_command_line_processing;
  app->app.get_browser_process_handler =
      cefspike_app_get_browser_process_handler;

  app->bph = cefspike_bph_create();
  CHECK(app->bph);

  atomic_store(&app->ref_count, 1);
  return &app->app;
}
