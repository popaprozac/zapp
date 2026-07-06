// Zapp CEF host (macOS) — the cef_client_t and its life-span handler.
//
// Promoted from the proven GO spike (`spikes/cef-macos/cef_client.c` — see
// docs/superpowers/specs/2026-07-05-cef-webengine-production-slice-macos-
// design.md and spikes/cef-macos/FINDINGS.md, Tasks 0 + 4 + 5). Renamed
// cefspike_ -> zapp_cef_, "spike" dropped. A LIFE-SPAN-ONLY + bridge-stub
// client (no display/load handlers this task; simplified to a single
// browser — see zapp_cef_life_span_on_before_close).
//
// Also hosts two small construction helpers used by the browser-creation
// call: a UTF-8 -> cef_string_t and a zeroed cef_browser_settings_t. They
// live here (rather than in the caller) so struct layout comes straight from
// the CEF headers.

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zapp_cef_refcount.h"
#include "zapp_cef.h"

// The browser-process half of the `zapp` bridge (below) handles the
// "zapp:invoke" process message. These pull in the process-message /
// list-value / frame vtables it needs.
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_process_message_capi.h"
#include "include/capi/cef_values_capi.h"

// Forward declaration.
typedef struct _zapp_cef_life_span_handler_t zapp_cef_life_span_handler_t;

typedef struct _zapp_cef_client_t {
  // MUST be first member — CEF base structure.
  cef_client_t client;
  atomic_int ref_count;
  zapp_cef_life_span_handler_t* life_span_handler;
} zapp_cef_client_t;

struct _zapp_cef_life_span_handler_t {
  // MUST be first member — CEF base structure.
  cef_life_span_handler_t handler;
  atomic_int ref_count;
};

//
// Life-span handler.
//

IMPLEMENT_REFCOUNTING_SIMPLE(zapp_cef_life_span_handler_t,
                             zapp_cef_life_span_handler,
                             ref_count)

// The currently-hosted browser, retained across its lifetime so a future
// native->page push mechanism (a worker event, an async bridge reply, etc.)
// can reach the page — see zapp_cef_get_active_browser in zapp_cef.h.
// |browser| handed to on_after_created is an OWNED ref (CEF C-API callback
// params are transferred to the callee — verified against the libcef_dll
// translator source, see spikes/cef-macos/FINDINGS.md's ownership finding);
// releasing it immediately (as an earlier iteration of this spike did) would
// leave nothing to reach the page later, so it's kept instead and released
// in on_before_close.
static cef_browser_t* g_active_browser = NULL;

cef_browser_t* zapp_cef_get_active_browser(void) {
  return g_active_browser;
}

void CEF_CALLBACK
zapp_cef_life_span_on_after_created(cef_life_span_handler_t* self,
                                    cef_browser_t* browser) {
  (void)self;
  fprintf(stderr, "[zapp-cef] browser created\n");
  // Keep the owned ref instead of releasing it — see
  // zapp_cef_get_active_browser above.
  g_active_browser = browser;
}

int CEF_CALLBACK zapp_cef_life_span_do_close(cef_life_span_handler_t* self,
                                             cef_browser_t* browser) {
  (void)self;
  // Release the callback parameter before returning.
  browser->base.release(&browser->base);
  // Return 0 to allow the close to proceed.
  return 0;
}

void CEF_CALLBACK
zapp_cef_life_span_on_before_close(cef_life_span_handler_t* self,
                                   cef_browser_t* browser) {
  (void)self;
  // Release the EXTRA ref kept alive since on_after_created — a DIFFERENT
  // owned ref than the |browser| parameter below (CEF hands a fresh owned
  // ref to each callback invocation, per the same convention).
  if (g_active_browser == browser) {
    g_active_browser = NULL;
    browser->base.release(&browser->base);
  }
  browser->base.release(&browser->base);
  // Single-window host: the only browser has closed. The external message
  // pump runs under [NSApp run] (not cef_run_message_loop), so stop the
  // NSApp loop rather than calling cef_quit_message_loop (which only applies
  // to cef_run_message_loop). The caller then falls through to cef_shutdown.
  fprintf(stderr, "[zapp-cef] browser closing — stopping NSApp loop\n");
  zapp_cef_quit_main_loop();
}

static zapp_cef_life_span_handler_t* zapp_cef_life_span_handler_create(void) {
  zapp_cef_life_span_handler_t* h = (zapp_cef_life_span_handler_t*)calloc(
      1, sizeof(zapp_cef_life_span_handler_t));
  CHECK(h);

  INIT_CEF_BASE_REFCOUNTED(&h->handler.base, cef_life_span_handler_t,
                           zapp_cef_life_span_handler);
  h->handler.on_after_created = zapp_cef_life_span_on_after_created;
  h->handler.do_close = zapp_cef_life_span_do_close;
  h->handler.on_before_close = zapp_cef_life_span_on_before_close;

  atomic_store(&h->ref_count, 1);
  return h;
}

//
// The `zapp` bridge, BROWSER-process half.
//
// The render process (zapp_cef_bridge.c) ships a "zapp:invoke" process
// message with [id:int, name:str, argsJSON:str]; we run a STUB service (real
// router wiring is a later task), then ship a "zapp:result" reply with
// [id:int, resultJSON:str] back to PID_RENDERER via the same frame.
// resultJSON is a JSON *value* (quoted+escaped string) so the render side can
// splice it straight into window.__zappResolve(id, <value>). Message names
// MUST match zapp_cef_bridge.c.
//

#define ZAPP_MSG_INVOKE "zapp:invoke"
#define ZAPP_MSG_RESULT "zapp:result"

// UTF-16 userfree -> malloc'd UTF-8 C string (caller frees; NULL-safe).
static char* zapp_cef_utf8_dup(cef_string_userfree_t s) {
  if (s == NULL) {
    return NULL;
  }
  cef_string_utf8_t u;
  memset(&u, 0, sizeof(u));
  cef_string_utf16_to_utf8(s->str, s->length, &u);
  char* dup = (u.str != NULL) ? strdup(u.str) : NULL;
  cef_string_utf8_clear(&u);
  return dup;
}

// Encode |s| as a JSON string value (surrounding quotes + minimal escaping).
// Heap-allocated (worst case each byte -> "\uXXXX"); caller frees.
static char* zapp_cef_json_quote(const char* s) {
  size_t n = strlen(s);
  char* out = (char*)malloc(n * 6 + 3);
  CHECK(out);
  char* p = out;
  *p++ = '"';
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)s[i];
    switch (c) {
      case '"':  *p++ = '\\'; *p++ = '"'; break;
      case '\\': *p++ = '\\'; *p++ = '\\'; break;
      case '\n': *p++ = '\\'; *p++ = 'n'; break;
      case '\r': *p++ = '\\'; *p++ = 'r'; break;
      case '\t': *p++ = '\\'; *p++ = 't'; break;
      default:
        if (c < 0x20) {
          p += sprintf(p, "\\u%04x", c);
        } else {
          *p++ = (char)c;
        }
    }
  }
  *p++ = '"';
  *p = '\0';
  return out;
}

// Spike-grade extractor: find "field" then read the following JSON string
// value. No nested-escape handling — enough for {"name":"World"}. Returns a
// malloc'd copy of the value (caller frees) or NULL if absent/non-string.
// PRODUCTION SEED: a later task should route real args/results through the
// same typed C-ABI Zapp already uses for WKWebView instead of this ad-hoc
// string surgery (see FINDINGS.md's "JSON at the boundary" note).
static char* zapp_cef_json_str_field(const char* json, const char* field) {
  if (json == NULL) {
    return NULL;
  }
  size_t flen = strlen(field);
  char* key = (char*)malloc(flen + 3);
  CHECK(key);
  key[0] = '"';
  memcpy(key + 1, field, flen);
  key[flen + 1] = '"';
  key[flen + 2] = '\0';
  const char* at = strstr(json, key);
  free(key);
  if (at == NULL) {
    return NULL;
  }
  at += flen + 2;  // past "field"
  while (*at == ' ' || *at == '\t' || *at == ':') {
    at++;
  }
  if (*at != '"') {
    return NULL;  // only string values handled
  }
  at++;
  const char* end = at;
  while (*end != '\0' && *end != '"') {
    end++;
  }
  size_t vlen = (size_t)(end - at);
  char* val = (char*)malloc(vlen + 1);
  CHECK(val);
  memcpy(val, at, vlen);
  val[vlen] = '\0';
  return val;
}

// STUB service registry — knows exactly one: greet. Returns a malloc'd JSON
// value (quoted string) ready for window.__zappResolve; frees. Real-router
// wiring (replacing this stub with Zapp's actual service registry) is a
// later task.
static char* zapp_cef_run_stub_service(const char* name, const char* args_json) {
  if (name != NULL && strcmp(name, "greet") == 0) {
    char* who = zapp_cef_json_str_field(args_json, "name");
    char* plain;
    if (who != NULL && who[0] != '\0') {
      size_t need = strlen("Hello from Zapp! (to )") + strlen(who) + 1;
      plain = (char*)malloc(need);
      CHECK(plain);
      snprintf(plain, need, "Hello from Zapp! (to %s)", who);
    } else {
      plain = strdup("Hello from Zapp!");
      CHECK(plain);
    }
    free(who);
    char* json = zapp_cef_json_quote(plain);
    free(plain);
    return json;
  }
  size_t need = strlen("Unknown service: ") + (name ? strlen(name) : 6) + 1;
  char* plain = (char*)malloc(need);
  CHECK(plain);
  snprintf(plain, need, "Unknown service: %s", name ? name : "(null)");
  char* json = zapp_cef_json_quote(plain);
  free(plain);
  return json;
}

int CEF_CALLBACK zapp_cef_client_on_process_message_received(
    cef_client_t* self, cef_browser_t* browser, cef_frame_t* frame,
    cef_process_id_t source_process, cef_process_message_t* message) {
  (void)self;
  (void)browser;
  (void)source_process;

  int handled = 0;
  cef_string_userfree_t msg_name = message->get_name(message);
  cef_string_utf8_t name_utf8;
  memset(&name_utf8, 0, sizeof(name_utf8));
  if (msg_name != NULL) {
    cef_string_utf16_to_utf8(msg_name->str, msg_name->length, &name_utf8);
    cef_string_userfree_free(msg_name);
  }

  if (name_utf8.str != NULL && strcmp(name_utf8.str, ZAPP_MSG_INVOKE) == 0) {
    cef_list_value_t* args = message->get_argument_list(message);
    int id = args->get_int(args, 0);
    cef_string_userfree_t s_name = args->get_string(args, 1);
    cef_string_userfree_t s_args = args->get_string(args, 2);
    char* service = zapp_cef_utf8_dup(s_name);
    char* argjson = zapp_cef_utf8_dup(s_args);
    if (s_name != NULL) {
      cef_string_userfree_free(s_name);
    }
    if (s_args != NULL) {
      cef_string_userfree_free(s_args);
    }
    args->base.release(&args->base);

    fprintf(stderr,
            "[zapp-cef][browser] zapp:invoke id=%d service=%s args=%s\n", id,
            service ? service : "(null)", argjson ? argjson : "(null)");

    char* result_json = zapp_cef_run_stub_service(service, argjson);

    // Build + ship the "zapp:result" reply back to the render process.
    cef_string_t reply_name;
    memset(&reply_name, 0, sizeof(reply_name));
    cef_string_utf8_to_utf16(ZAPP_MSG_RESULT, strlen(ZAPP_MSG_RESULT),
                             &reply_name);
    cef_process_message_t* reply = cef_process_message_create(&reply_name);
    cef_string_clear(&reply_name);

    cef_list_value_t* rargs = reply->get_argument_list(reply);
    rargs->set_int(rargs, 0, id);
    cef_string_t rjson;
    memset(&rjson, 0, sizeof(rjson));
    cef_string_utf8_to_utf16(result_json, strlen(result_json), &rjson);
    rargs->set_string(rargs, 1, &rjson);
    cef_string_clear(&rjson);
    rargs->base.release(&rargs->base);

    // REFCOUNT: send_process_message's message param is refptr_same — it
    // CONSUMES our |reply| reference (translator Unwraps it with an added ref
    // the receiver releases; the header also notes |reply| is invalidated
    // after). |reply| came from cef_process_message_create with ref=1 (ours),
    // so this transfers it to CEF. Do NOT release |reply| afterward — that
    // would be a double-release (same over-release family as the
    // on_context_created set_value_bykey crash zapp_cef_bridge.c avoids).
    frame->send_process_message(frame, PID_RENDERER, reply);

    fprintf(stderr, "[zapp-cef][browser] zapp:result id=%d -> %s\n", id,
            result_json);

    free(service);
    free(argjson);
    free(result_json);
    handled = 1;
  }

  cef_string_utf8_clear(&name_utf8);

  // Release the owned callback params (CEF C-API refptr_diff — same
  // convention as the life-span handler's browser param). We never retain
  // browser/frame beyond this call; the reply was already shipped via
  // |frame| above.
  browser->base.release(&browser->base);
  frame->base.release(&frame->base);
  message->base.release(&message->base);
  return handled;
}

//
// Client.
//

IMPLEMENT_REFCOUNTING_MANUAL(zapp_cef_client_t, zapp_cef_client, ref_count)

int CEF_CALLBACK zapp_cef_client_release(cef_base_ref_counted_t* self) {
  zapp_cef_client_t* client = (zapp_cef_client_t*)self;
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
zapp_cef_client_get_life_span_handler(cef_client_t* self) {
  zapp_cef_client_t* client = (zapp_cef_client_t*)self;
  if (client->life_span_handler) {
    // Add a reference before returning — CEF releases it when done.
    client->life_span_handler->handler.base.add_ref(
        &client->life_span_handler->handler.base);
    return &client->life_span_handler->handler;
  }
  return NULL;
}

cef_client_t* zapp_cef_client_create(void) {
  zapp_cef_client_t* client =
      (zapp_cef_client_t*)calloc(1, sizeof(zapp_cef_client_t));
  CHECK(client);

  INIT_CEF_BASE_REFCOUNTED(&client->client.base, cef_client_t, zapp_cef_client);
  client->client.get_life_span_handler = zapp_cef_client_get_life_span_handler;
  // Browser-process half of the bridge (handles "zapp:invoke").
  client->client.on_process_message_received =
      zapp_cef_client_on_process_message_received;

  client->life_span_handler = zapp_cef_life_span_handler_create();
  CHECK(client->life_span_handler);

  atomic_store(&client->ref_count, 1);
  return &client->client;
}

//
// Small construction helpers for the create-browser call.
//

cef_string_t* zapp_cef_make_cef_string(const char* utf8) {
  static cef_string_t s;
  memset(&s, 0, sizeof(s));
  cef_string_utf8_to_utf16(utf8, strlen(utf8), &s);
  return &s;
}

cef_browser_settings_t* zapp_cef_make_browser_settings(void) {
  static cef_browser_settings_t bs;
  memset(&bs, 0, sizeof(bs));
  bs.size = sizeof(cef_browser_settings_t);
  return &bs;
}
