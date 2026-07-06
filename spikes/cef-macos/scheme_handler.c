// CEF spike (Task 3) — the "zapp" custom scheme: registration + a
// scheme-handler-factory/resource-handler pair that serves two embedded
// assets, plus the native-brotli-decode probe (Zapp's "size cost buys perf"
// bet: ship brotli-compressed assets and let the engine decode them, instead
// of decompressing ourselves).
//
// Three pieces, in the order CEF calls them:
//
//   1. cefspike_register_zapp_scheme() — wired to cef_app_t::
//      on_register_custom_schemes (cef_app.c for the browser process; a
//      minimal standalone cef_app_t in mac_helper.c for the Helper
//      subprocess). CEF calls this in EVERY process, BEFORE cef_initialize
//      returns, and requires identical registration across all of them — so
//      this function is deliberately self-contained (only CEF string/scheme
//      headers + cef_refcount.h; no dependency on the browser-process handler
//      or the ObjC pump), letting it link cleanly into the Helper too.
//
//   2. cefspike_install_scheme_handler_factory() — called from cef_app.c's
//      browser-process handler on_context_initialized (browser process only,
//      after cef_initialize). Registers a cef_scheme_handler_factory_t whose
//      create() inspects the request URL and returns a
//      cefspike_resource_handler_t for the two known asset URLs, or NULL
//      (default handling — CEF has none for a custom scheme, so this
//      surfaces as a network error, out of scope for this task).
//
//   3. cefspike_scheme_set_assets() — called once from main.nim before
//      cef_initialize, handing over pointers to the embedded asset bytes.
//      main.nim staticRead()s the committed assets/index.html and
//      assets/data.json.br at NIM COMPILE TIME and passes the resulting
//      static-storage buffers here; this file never touches the filesystem.
//      assets/data.json.br is the brotli-compressed form of assets/data.json
//      (see compress-assets.ts) — the resource handler serves those bytes
//      AS-IS with Content-Encoding: br. It does NOT decompress: the probe is
//      whether Chromium's own network stack decodes br for a custom-scheme
//      response, same as it would for a real HTTP response.
//
// Refcounting for both the factory and the resource handler follows the SAME
// pattern T0 established (cef_refcount.h's IMPLEMENT_REFCOUNTING_SIMPLE) —
// calloc'd struct-of-callbacks, atomic ref_count, free() on last release.

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cef_refcount.h"
#include "cef_spike.h"

// cef_spike.h (via cef_app_capi.h) already pulls in cef_scheme_capi.h, which
// in turn pulls in cef_resource_handler_capi.h / cef_response_capi.h /
// cef_request_capi.h — everything this file needs for scheme/factory/handler
// struct layout.

// ---------------------------------------------------------------------------
// 1. Scheme registration (runs in EVERY process).
// ---------------------------------------------------------------------------

void cefspike_register_zapp_scheme(cef_scheme_registrar_t* registrar) {
  const char* name = "zapp";
  cef_string_t scheme_name;
  memset(&scheme_name, 0, sizeof(scheme_name));
  cef_string_utf8_to_utf16(name, strlen(name), &scheme_name);

  // STANDARD: parse as scheme://host/path (zapp://app/index.html needs a
  // host component). SECURE: no mixed-content warnings (treated like https).
  // CORS_ENABLED + FETCH_ENABLED: index.html's fetch("zapp://app/data.json")
  // — same-origin here, but these are the flags a real webEngine:"chromium"
  // asset scheme would want for cross-origin fetches too.
  int options = CEF_SCHEME_OPTION_STANDARD | CEF_SCHEME_OPTION_SECURE |
                CEF_SCHEME_OPTION_CORS_ENABLED | CEF_SCHEME_OPTION_FETCH_ENABLED;

  if (!registrar->add_custom_scheme(registrar, &scheme_name, options)) {
    fprintf(stderr, "[cef-spike] add_custom_scheme(zapp) failed\n");
  }
  cef_string_clear(&scheme_name);
}

// ---------------------------------------------------------------------------
// Embedded asset storage (browser process only — set once via
// cefspike_scheme_set_assets before cef_initialize; see main.nim).
// ---------------------------------------------------------------------------

static const unsigned char* g_index_html = NULL;
static int g_index_html_len = 0;
static const unsigned char* g_data_json_br = NULL;
static int g_data_json_br_len = 0;

void cefspike_scheme_set_assets(const char* index_html, int index_html_len,
                                const void* data_json_br,
                                int data_json_br_len) {
  g_index_html = (const unsigned char*)index_html;
  g_index_html_len = index_html_len;
  g_data_json_br = (const unsigned char*)data_json_br;
  g_data_json_br_len = data_json_br_len;
}

// ---------------------------------------------------------------------------
// 2a. cef_resource_handler_t — serves one in-memory asset (open/
// get_response_headers/skip/read/cancel; the two deprecated slots
// process_request/read_response are left NULL, per CEF's own vtable comment:
// they're only invoked if a handler does NOT implement open()/read()).
// ---------------------------------------------------------------------------

typedef struct _cefspike_resource_handler_t {
  // MUST be first member — CEF base structure.
  cef_resource_handler_t handler;
  atomic_int ref_count;
  const unsigned char* data;      // NOT owned — points into an embedded asset.
  int length;                     // total bytes to serve (the WIRE length —
                                   // for data.json this is the COMPRESSED
                                   // length; Content-Encoding: br means the
                                   // wire body is the brotli bytes, not the
                                   // decoded size).
  int offset;                     // bytes already handed to CEF via read().
  const char* mime_type;          // static string literal, e.g. "text/html".
  const char* content_encoding;   // static string literal ("br") or NULL.
} cefspike_resource_handler_t;

IMPLEMENT_REFCOUNTING_SIMPLE(cefspike_resource_handler_t,
                             cefspike_resource_handler, ref_count)

int CEF_CALLBACK cefspike_resource_handler_open(cef_resource_handler_t* self,
                                                struct _cef_request_t* request,
                                                int* handle_request,
                                                struct _cef_callback_t* callback) {
  (void)self;
  (void)request;
  (void)callback;
  *handle_request = 1;  // handle synchronously, right now.
  return 1;
}

void CEF_CALLBACK cefspike_resource_handler_get_response_headers(
    cef_resource_handler_t* self, struct _cef_response_t* response,
    int64_t* response_length, cef_string_t* redirectUrl) {
  (void)redirectUrl;
  cefspike_resource_handler_t* h = (cefspike_resource_handler_t*)self;

  response->set_status(response, 200);

  cef_string_t mime;
  memset(&mime, 0, sizeof(mime));
  cef_string_utf8_to_utf16(h->mime_type, strlen(h->mime_type), &mime);
  response->set_mime_type(response, &mime);
  cef_string_clear(&mime);

  if (h->content_encoding != NULL) {
    cef_string_t name, value;
    memset(&name, 0, sizeof(name));
    memset(&value, 0, sizeof(value));
    const char* header_name = "Content-Encoding";
    cef_string_utf8_to_utf16(header_name, strlen(header_name), &name);
    cef_string_utf8_to_utf16(h->content_encoding, strlen(h->content_encoding),
                             &value);
    response->set_header_by_name(response, &name, &value, /*overwrite=*/1);
    cef_string_clear(&name);
    cef_string_clear(&value);
  }

  *response_length = h->length;

  fprintf(stderr,
          "[cef-spike] zapp:// serving %d bytes, mime=%s, encoding=%s\n",
          h->length, h->mime_type, h->content_encoding ? h->content_encoding
                                                        : "(none)");
}

int CEF_CALLBACK cefspike_resource_handler_skip(
    cef_resource_handler_t* self, int64_t bytes_to_skip,
    int64_t* bytes_skipped, struct _cef_resource_skip_callback_t* callback) {
  (void)callback;
  cefspike_resource_handler_t* h = (cefspike_resource_handler_t*)self;
  int64_t remaining = (int64_t)h->length - (int64_t)h->offset;
  int64_t skip = bytes_to_skip < remaining ? bytes_to_skip : remaining;
  if (skip < 0) {
    skip = 0;
  }
  h->offset += (int)skip;
  *bytes_skipped = skip;
  return 1;  // in-memory data — always available immediately.
}

int CEF_CALLBACK cefspike_resource_handler_read(
    cef_resource_handler_t* self, void* data_out, int bytes_to_read,
    int* bytes_read, struct _cef_resource_read_callback_t* callback) {
  (void)callback;
  cefspike_resource_handler_t* h = (cefspike_resource_handler_t*)self;
  int remaining = h->length - h->offset;
  if (remaining <= 0) {
    *bytes_read = 0;
    return 0;  // response complete.
  }
  int n = bytes_to_read < remaining ? bytes_to_read : remaining;
  memcpy(data_out, h->data + h->offset, (size_t)n);
  h->offset += n;
  *bytes_read = n;
  return 1;
}

void CEF_CALLBACK cefspike_resource_handler_cancel(cef_resource_handler_t* self) {
  (void)self;  // nothing to clean up — data is static/embedded, not owned.
}

static cef_resource_handler_t* cefspike_resource_handler_create(
    const unsigned char* data, int length, const char* mime_type,
    const char* content_encoding) {
  cefspike_resource_handler_t* h = (cefspike_resource_handler_t*)calloc(
      1, sizeof(cefspike_resource_handler_t));
  CHECK(h);

  INIT_CEF_BASE_REFCOUNTED(&h->handler.base, cef_resource_handler_t,
                           cefspike_resource_handler);
  h->handler.open = cefspike_resource_handler_open;
  h->handler.get_response_headers = cefspike_resource_handler_get_response_headers;
  h->handler.skip = cefspike_resource_handler_skip;
  h->handler.read = cefspike_resource_handler_read;
  h->handler.cancel = cefspike_resource_handler_cancel;

  h->data = data;
  h->length = length;
  h->offset = 0;
  h->mime_type = mime_type;
  h->content_encoding = content_encoding;

  atomic_store(&h->ref_count, 1);
  return &h->handler;
}

// ---------------------------------------------------------------------------
// 2b. cef_scheme_handler_factory_t — maps a request URL to one of the two
// known assets.
// ---------------------------------------------------------------------------

typedef struct _cefspike_scheme_factory_t {
  // MUST be first member — CEF base structure.
  cef_scheme_handler_factory_t factory;
  atomic_int ref_count;
} cefspike_scheme_factory_t;

IMPLEMENT_REFCOUNTING_SIMPLE(cefspike_scheme_factory_t, cefspike_scheme_factory,
                             ref_count)

struct _cef_resource_handler_t* CEF_CALLBACK cefspike_scheme_factory_create(
    struct _cef_scheme_handler_factory_t* self, struct _cef_browser_t* browser,
    struct _cef_frame_t* frame, const cef_string_t* scheme_name,
    struct _cef_request_t* request) {
  (void)self;
  (void)browser;
  (void)frame;
  (void)scheme_name;

  cef_string_userfree_t url = request->get_url(request);
  cef_string_utf8_t utf8;
  memset(&utf8, 0, sizeof(utf8));
  if (url != NULL) {
    cef_string_utf16_to_utf8(url->str, url->length, &utf8);
    cef_string_userfree_free(url);
  }

  cef_resource_handler_t* handler = NULL;
  if (utf8.str != NULL) {
    if (strcmp(utf8.str, "zapp://app/index.html") == 0) {
      handler = cefspike_resource_handler_create(g_index_html, g_index_html_len,
                                                 "text/html", NULL);
    } else if (strcmp(utf8.str, "zapp://app/data.json") == 0) {
      handler = cefspike_resource_handler_create(
          g_data_json_br, g_data_json_br_len, "application/json", "br");
    } else {
      fprintf(stderr, "[cef-spike] zapp:// unhandled request: %s\n", utf8.str);
    }
  }
  cef_string_utf8_clear(&utf8);
  return handler;
}

static cef_scheme_handler_factory_t* cefspike_scheme_factory_create_instance(
    void) {
  cefspike_scheme_factory_t* f = (cefspike_scheme_factory_t*)calloc(
      1, sizeof(cefspike_scheme_factory_t));
  CHECK(f);

  INIT_CEF_BASE_REFCOUNTED(&f->factory.base, cef_scheme_handler_factory_t,
                           cefspike_scheme_factory);
  f->factory.create = cefspike_scheme_factory_create;

  atomic_store(&f->ref_count, 1);
  return &f->factory;
}

// ---------------------------------------------------------------------------
// 3. Install the factory (browser process only, AFTER cef_initialize — see
// cef_app.c's on_context_initialized).
// ---------------------------------------------------------------------------

void cefspike_install_scheme_handler_factory(void) {
  const char* scheme = "zapp";
  cef_string_t scheme_str;
  memset(&scheme_str, 0, sizeof(scheme_str));
  cef_string_utf8_to_utf16(scheme, strlen(scheme), &scheme_str);

  // Ref count 1 -> transferred to CEF by cef_register_scheme_handler_factory,
  // same convention as cefspike_app_create/cefspike_client_create (T0/T1).
  cef_scheme_handler_factory_t* factory = cefspike_scheme_factory_create_instance();
  int ok = cef_register_scheme_handler_factory(&scheme_str, NULL, factory);
  cef_string_clear(&scheme_str);

  if (!ok) {
    fprintf(stderr,
            "[cef-spike] cef_register_scheme_handler_factory(zapp) failed\n");
  } else {
    fprintf(stderr, "[cef-spike] zapp:// scheme handler factory registered "
                    "(index.html=%d bytes, data.json.br=%d bytes)\n",
            g_index_html_len, g_data_json_br_len);
  }
}
