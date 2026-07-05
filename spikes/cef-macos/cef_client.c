// CEF spike (Task 0) — the cef_client_t and its life-span handler.
//
// Adapted from cefsimple_capi/simple_handler.c + simple_life_span_handler.c,
// trimmed to a LIFE-SPAN-ONLY client (no display/load handlers this task) and
// simplified to a single browser (the reference's browser_list is dropped — the
// spike opens exactly one window, so on_before_close just quits the loop).
//
// Also hosts two small construction helpers used by main.nim's create-browser
// call: a UTF-8 -> cef_string_t and a zeroed cef_browser_settings_t. They live
// here (rather than in Nim) so struct layout comes straight from the CEF headers.

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "cef_refcount.h"
#include "cef_spike.h"

// Forward declaration.
typedef struct _cefspike_life_span_handler_t cefspike_life_span_handler_t;

typedef struct _cefspike_client_t {
  // MUST be first member — CEF base structure.
  cef_client_t client;
  atomic_int ref_count;
  cefspike_life_span_handler_t* life_span_handler;
} cefspike_client_t;

struct _cefspike_life_span_handler_t {
  // MUST be first member — CEF base structure.
  cef_life_span_handler_t handler;
  atomic_int ref_count;
};

//
// Life-span handler.
//

IMPLEMENT_REFCOUNTING_SIMPLE(cefspike_life_span_handler_t,
                             cefspike_life_span_handler,
                             ref_count)

void CEF_CALLBACK
cefspike_life_span_on_after_created(cef_life_span_handler_t* self,
                                    cef_browser_t* browser) {
  (void)self;
  fprintf(stderr, "[cef-spike] browser created\n");
  // Release the callback parameter (we don't retain the browser for T0).
  browser->base.release(&browser->base);
}

int CEF_CALLBACK cefspike_life_span_do_close(cef_life_span_handler_t* self,
                                             cef_browser_t* browser) {
  (void)self;
  // Release the callback parameter before returning.
  browser->base.release(&browser->base);
  // Return 0 to allow the close to proceed.
  return 0;
}

void CEF_CALLBACK
cefspike_life_span_on_before_close(cef_life_span_handler_t* self,
                                   cef_browser_t* browser) {
  (void)self;
  browser->base.release(&browser->base);
  // Single-window spike: the only browser has closed. Task 1 runs the external
  // message pump under [NSApp run] (not cef_run_message_loop), so stop the NSApp
  // loop rather than calling cef_quit_message_loop (which only applies to
  // cef_run_message_loop). cefSpikeMain then falls through to cef_shutdown.
  fprintf(stderr, "[cef-spike] browser closing — stopping NSApp loop\n");
  cefspike_quit_main_loop();
}

static cefspike_life_span_handler_t* cefspike_life_span_handler_create(void) {
  cefspike_life_span_handler_t* h = (cefspike_life_span_handler_t*)calloc(
      1, sizeof(cefspike_life_span_handler_t));
  CHECK(h);

  INIT_CEF_BASE_REFCOUNTED(&h->handler.base, cef_life_span_handler_t,
                           cefspike_life_span_handler);
  h->handler.on_after_created = cefspike_life_span_on_after_created;
  h->handler.do_close = cefspike_life_span_do_close;
  h->handler.on_before_close = cefspike_life_span_on_before_close;

  atomic_store(&h->ref_count, 1);
  return h;
}

//
// Client.
//

IMPLEMENT_REFCOUNTING_MANUAL(cefspike_client_t, cefspike_client, ref_count)

int CEF_CALLBACK cefspike_client_release(cef_base_ref_counted_t* self) {
  cefspike_client_t* client = (cefspike_client_t*)self;
  int count = atomic_fetch_sub(&client->ref_count, 1) - 1;
  if (count == 0) {
    if (client->life_span_handler) {
      client->life_span_handler->handler.base.release(
          &client->life_span_handler->handler.base);
    }
    free(client);
    return 1;
  }
  return 0;
}

cef_life_span_handler_t* CEF_CALLBACK
cefspike_client_get_life_span_handler(cef_client_t* self) {
  cefspike_client_t* client = (cefspike_client_t*)self;
  if (client->life_span_handler) {
    // Add a reference before returning — CEF releases it when done.
    client->life_span_handler->handler.base.add_ref(
        &client->life_span_handler->handler.base);
    return &client->life_span_handler->handler;
  }
  return NULL;
}

cef_client_t* cefspike_client_create(void) {
  cefspike_client_t* client =
      (cefspike_client_t*)calloc(1, sizeof(cefspike_client_t));
  CHECK(client);

  INIT_CEF_BASE_REFCOUNTED(&client->client.base, cef_client_t, cefspike_client);
  client->client.get_life_span_handler = cefspike_client_get_life_span_handler;

  client->life_span_handler = cefspike_life_span_handler_create();
  CHECK(client->life_span_handler);

  atomic_store(&client->ref_count, 1);
  return &client->client;
}

//
// Small construction helpers for the create-browser call.
//

cef_string_t* cefspike_make_cef_string(const char* utf8) {
  static cef_string_t s;
  memset(&s, 0, sizeof(s));
  cef_string_utf8_to_utf16(utf8, strlen(utf8), &s);
  return &s;
}

cef_browser_settings_t* cefspike_make_browser_settings(void) {
  static cef_browser_settings_t bs;
  memset(&bs, 0, sizeof(bs));
  bs.size = sizeof(cef_browser_settings_t);
  return &bs;
}
