// Zapp CEF host (macOS) — the "zapp" custom scheme: registration + a
// scheme-handler-factory/resource-handler pair that serves Zapp's REAL
// embedded-asset table (`zapp_embedded_assets[]`) on zapp://.
//
// Promoted + REWRITTEN from the proven GO spike
// (`spikes/cef-macos/scheme_handler.c` — see docs/superpowers/specs/
// 2026-07-05-cef-webengine-production-slice-macos-design.md and
// spikes/cef-macos/FINDINGS.md, Task 3). Renamed cefspike_ -> zapp_cef_,
// "spike" dropped. Unlike the rest of the promoted CEF machinery (copied
// verbatim), THIS file's serving logic is rewritten: the spike served
// exactly two compile-time-embedded assets (assets/index.html,
// assets/data.json.br) handed over once via a since-removed
// cefspike_scheme_set_assets() call; this version serves the REAL,
// CLI-generated embedded-asset table instead — the same
// `extern ZappEmbeddedAsset zapp_embedded_assets[]` /
// `zapp_embedded_assets_count` weak-extern table
// native/platform/darwin/webview.m's ZappAssetSchemeHandler already serves
// on WKWebView's zapp:// scheme. The lookup (host+path -> normalized
// relative path -> table scan) and the brotli-decode path
// (`is_brotli && uncompressed_len > 0` -> Apple's libcompression
// `compression_decode_buffer(..., COMPRESSION_BROTLI)`) mirror
// ZappAssetSchemeHandler exactly — see webview.m lines ~170-283 — rather
// than the spike's Homebrew libbrotlidec dependency (dropped entirely; not
// linked here).
//
// Dev mode: zapp_build_use_embedded_assets() returns 0 when the CLI didn't
// bake assets into the binary (dev server mode). Unlike webview.m — which
// falls back to reading files off disk in that case — this scheme handler
// does NOT attempt a filesystem fallback: the factory's create() returns
// NULL immediately (CEF's idiom for "no handler"; see the dev-mode hook
// below). Zapp's `webEngine:"chromium"` dev flow is expected to point the
// browser directly at Vite's resolved devUrl (http://localhost:<port>)
// rather than navigating to zapp:// at all — that URL choice is a later
// task's job (zapp_cef_create_browser_in_view, in zapp_cef_host.m, just
// hosts whatever URL string it's given).
//
// Three pieces, in the order CEF calls them (unchanged shape from the spike):
//
//   1. zapp_cef_register_zapp_scheme() — wired to cef_app_t::
//      on_register_custom_schemes (zapp_cef_app.c for the browser process; a
//      minimal standalone cef_app_t in zapp_cef_mac_helper.c for the Helper
//      subprocess). CEF calls this in EVERY process, BEFORE cef_initialize
//      returns, and requires identical registration across all of them — so
//      this function is deliberately self-contained (only CEF string/scheme
//      headers + zapp_cef_refcount.h; no dependency on the browser-process
//      handler or the ObjC pump), letting it link cleanly into the Helper too.
//
//   2. zapp_cef_install_scheme_handler_factory() — called from
//      zapp_cef_app.c's browser-process handler on_context_initialized
//      (browser process only, after cef_initialize). Registers a
//      cef_scheme_handler_factory_t whose create() looks up the request path
//      in the real embedded-asset table (or returns NULL in dev mode).
//
// Refcounting for both the factory and the resource handler follows the SAME
// pattern the spike established (zapp_cef_refcount.h's
// IMPLEMENT_REFCOUNTING_SIMPLE / _MANUAL) — calloc'd struct-of-callbacks,
// atomic ref_count, free() on last release. The resource handler uses the
// MANUAL variant (unlike the spike's SIMPLE one) so its release() can also
// free an owned brotli-decode buffer when one was allocated — the spike
// never owned its own data (it pointed into static globals), so it never
// needed this.
//
// LEAK FIX (this task): the spike's final review (FINDINGS.md, "Production
// seeds") flagged that the resource handler's `request`/`callback` (open())
// and `response` (get_response_headers()) params — all `refptr_diff` per the
// libcef_dll translator (verified directly against
// cef_binary/libcef_dll/cpptoc/resource_handler_cpptoc.cc, same rigor as the
// bridge's ownership finding) — were never released, i.e. LEAKED on every
// request. Fixed below. The same translator source shows skip()'s and
// read()'s `callback` params are ALSO refptr_diff (same leak family, just
// not named in the original finding) — fixed too, since this file's resource
// handler was already being rewritten wholesale for the real asset table.

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>  // strcasecmp
#include <stdint.h>

// Apple's libcompression — the SAME brotli decoder
// native/platform/darwin/webview.m's ZappAssetSchemeHandler links
// (`compression_decode_buffer` + `COMPRESSION_BROTLI`; see webview.m's
// #import <compression.h>). NOT the spike's Homebrew libbrotlidec — that
// dependency is dropped entirely in this rewrite. T2 must link `-lcompression`
// for this translation unit (cli/src/build-config.ts already does this for
// the main app target via `//> macos: link: -lcompression`).
#include <compression.h>

#include "zapp_cef_refcount.h"
#include "zapp_cef.h"

// cef_parse_url / cef_urlparts_t — used to split the request URL into
// host+path the same way NSURL splits zapp://index.html for
// ZappAssetSchemeHandler (see zapp_cef_normalize_request_path below). The
// full cef_urlparts_t struct definition is already visible transitively via
// zapp_cef.h's cef_app_capi.h -> cef_base_capi.h -> cef_types.h chain; this
// include just brings in cef_parse_url's declaration.
#include "include/capi/cef_parser_capi.h"

// ---------------------------------------------------------------------------
// Real embedded-asset table — LOCAL MIRROR of the layout the CLI generates
// (cli/src/assets.ts -> .zapp/zapp_assets.zc's ZappEmbeddedAsset, linked in
// by a later task's build integration) and of
// native/platform/darwin/webview.m's own local mirror
// (ZappAssetSchemeHandler). Weak externs let the final link succeed even
// when no asset table is linked (dev mode -> a count-0 stub table, or no
// table at all, per zapp_build_use_embedded_assets() below).
// ---------------------------------------------------------------------------
typedef struct {
  const char* path;
  uint8_t* data;
  int len;
  int uncompressed_len;
  int is_brotli;
} ZappEmbeddedAsset;
extern ZappEmbeddedAsset zapp_embedded_assets[] __attribute__((weak));
extern int zapp_embedded_assets_count __attribute__((weak));

// Build-time config function (generated by the CLI into
// zapp_build_config.zc; see webview.m). Returns 0 in dev mode.
extern int zapp_build_use_embedded_assets(void);

// ---------------------------------------------------------------------------
// MIME lookup — C port of webview.m's zapp_mime_for_path (same extension
// table + default; case-insensitive).
// ---------------------------------------------------------------------------
static const char* zapp_cef_mime_for_path(const char* path) {
  static const struct { const char* ext; const char* mime; } table[] = {
      {"html", "text/html"},       {"htm", "text/html"},
      {"css", "text/css"},         {"js", "application/javascript"},
      {"mjs", "application/javascript"}, {"json", "application/json"},
      {"png", "image/png"},        {"jpg", "image/jpeg"},
      {"jpeg", "image/jpeg"},      {"gif", "image/gif"},
      {"svg", "image/svg+xml"},    {"ico", "image/x-icon"},
      {"woff", "font/woff"},       {"woff2", "font/woff2"},
      {"ttf", "font/ttf"},         {"wasm", "application/wasm"},
  };
  const char* dot = strrchr(path, '.');
  if (dot == NULL || dot[1] == '\0') {
    return "application/octet-stream";
  }
  const char* ext = dot + 1;
  for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
    if (strcasecmp(ext, table[i].ext) == 0) {
      return table[i].mime;
    }
  }
  return "application/octet-stream";
}

// ---------------------------------------------------------------------------
// Request-URL -> normalized asset lookup path. Mirrors
// ZappAssetSchemeHandler's host+path derivation exactly (webview.m lines
// ~176-198): a STANDARD-scheme request for e.g. `zapp://index.html` parses
// with host="index.html" and an empty/"/" path (no explicit path segment
// after the "host"), so the host itself is treated as the path in that case;
// `zapp://app/some/asset.js`-shaped requests use the path directly. Blocks
// path traversal ("..") the same way. Returns a malloc'd "/xxx" absolute
// lookup key (caller frees) matching zapp_embedded_assets[i].path's format,
// or NULL if the request contains a path-traversal attempt.
// ---------------------------------------------------------------------------
static char* zapp_cef_normalize_request_path(const char* host,
                                             const char* path) {
  const char* rel = (path != NULL && path[0] != '\0') ? path : "/";
  char* host_rel = NULL;

  int rel_is_root = (rel[0] == '\0' || strcmp(rel, "/") == 0);
  if (rel_is_root && host != NULL && host[0] != '\0') {
    size_t need = strlen(host) + 2;
    host_rel = (char*)malloc(need);
    CHECK(host_rel);
    snprintf(host_rel, need, "/%s", host);
    rel = host_rel;
  }

  if (rel[0] == '\0' || strcmp(rel, "/") == 0) {
    free(host_rel);
    return strdup("/index.html");
  }

  // Strip ALL leading slashes (mirrors the `while ([rel hasPrefix:@"/"])`
  // loop in webview.m), then re-add exactly one for the lookup key.
  const char* p = rel;
  while (*p == '/') {
    p++;
  }

  if (strstr(p, "..") != NULL) {
    free(host_rel);
    return NULL;  // path traversal — caller responds 403.
  }

  size_t need = strlen(p) + 2;
  char* out = (char*)malloc(need);
  CHECK(out);
  snprintf(out, need, "/%s", p);
  free(host_rel);
  return out;
}

// ---------------------------------------------------------------------------
// cef_resource_handler_t — serves one in-memory response: an embedded asset
// (200), a path-traversal rejection (403), or a not-found (404). The
// open/get_response_headers/skip/read/cancel vtable mirrors the spike
// (CEF 144.0.29 / Chromium 144.0.7559.256's current, non-deprecated slots);
// process_request/read_response are left NULL (only invoked as a fallback if
// open/read aren't implemented, per the header's own doc comment).
// ---------------------------------------------------------------------------

typedef struct _zapp_cef_asset_resource_handler_t {
  // MUST be first member — CEF base structure.
  cef_resource_handler_t handler;
  atomic_int ref_count;
  uint8_t* data;          // bytes to serve.
  int owns_data;          // if nonzero, |data| is malloc'd (a brotli-decode
                          // buffer or a literal error body) and freed on the
                          // handler's last release; otherwise |data| points
                          // into the embedded asset's static/binary-resident
                          // bytes and must NOT be freed.
  int length;             // wire length to serve.
  int offset;             // bytes already handed to CEF via read().
  int status;             // 200 / 403 / 404.
  const char* mime_type;  // static string literal, e.g. "text/html".
} zapp_cef_asset_resource_handler_t;

// MANUAL (not SIMPLE) refcounting: release must also free an owned
// brotli-decode buffer, which the spike's resource handler never had (see
// file header).
IMPLEMENT_REFCOUNTING_MANUAL(zapp_cef_asset_resource_handler_t,
                             zapp_cef_asset_resource_handler, ref_count)

int CEF_CALLBACK zapp_cef_asset_resource_handler_release(
    cef_base_ref_counted_t* self) {
  zapp_cef_asset_resource_handler_t* h =
      (zapp_cef_asset_resource_handler_t*)self;
  int count = atomic_fetch_sub(&h->ref_count, 1) - 1;
  if (count == 0) {
    if (h->owns_data && h->data != NULL) {
      free(h->data);
    }
    free(h);
    return 1;
  }
  return 0;
}

int CEF_CALLBACK zapp_cef_asset_resource_handler_open(
    cef_resource_handler_t* self, struct _cef_request_t* request,
    int* handle_request, struct _cef_callback_t* callback) {
  (void)self;
  *handle_request = 1;  // handle synchronously, right now.
  // LEAK FIX: |request| and |callback| are refptr_diff (CEF hands us owned
  // references — verified against
  // libcef_dll/cpptoc/resource_handler_cpptoc.cc: both params are tagged
  // `type: refptr_diff`). We handle everything synchronously and never need
  // either beyond this call, so release them here instead of leaking (the
  // spike's final-review finding).
  if (request != NULL) {
    request->base.release(&request->base);
  }
  if (callback != NULL) {
    callback->base.release(&callback->base);
  }
  return 1;
}

void CEF_CALLBACK zapp_cef_asset_resource_handler_get_response_headers(
    cef_resource_handler_t* self, struct _cef_response_t* response,
    int64_t* response_length, cef_string_t* redirectUrl) {
  (void)redirectUrl;
  zapp_cef_asset_resource_handler_t* h =
      (zapp_cef_asset_resource_handler_t*)self;

  response->set_status(response, h->status);

  cef_string_t mime;
  memset(&mime, 0, sizeof(mime));
  cef_string_utf8_to_utf16(h->mime_type, strlen(h->mime_type), &mime);
  response->set_mime_type(response, &mime);
  cef_string_clear(&mime);

  *response_length = h->length;

  fprintf(stderr, "[zapp-cef] zapp:// serving %d bytes, status=%d, mime=%s\n",
          h->length, h->status, h->mime_type);

  // LEAK FIX: |response| is also refptr_diff (same translator verification
  // as open()'s params above) — release our owned reference now that we've
  // written the fields CEF reads back afterward via its own separate
  // reference to the same object.
  if (response != NULL) {
    response->base.release(&response->base);
  }
}

int CEF_CALLBACK zapp_cef_asset_resource_handler_skip(
    cef_resource_handler_t* self, int64_t bytes_to_skip,
    int64_t* bytes_skipped, struct _cef_resource_skip_callback_t* callback) {
  zapp_cef_asset_resource_handler_t* h =
      (zapp_cef_asset_resource_handler_t*)self;
  int64_t remaining = (int64_t)h->length - (int64_t)h->offset;
  int64_t skip = bytes_to_skip < remaining ? bytes_to_skip : remaining;
  if (skip < 0) {
    skip = 0;
  }
  h->offset += (int)skip;
  *bytes_skipped = skip;
  // LEAK FIX: same refptr_diff family as open()'s |callback| — skip() is
  // always serviced synchronously here (->cont() is never invoked), so
  // release our owned reference immediately.
  if (callback != NULL) {
    callback->base.release(&callback->base);
  }
  return 1;  // in-memory data — always available immediately.
}

int CEF_CALLBACK zapp_cef_asset_resource_handler_read(
    cef_resource_handler_t* self, void* data_out, int bytes_to_read,
    int* bytes_read, struct _cef_resource_read_callback_t* callback) {
  zapp_cef_asset_resource_handler_t* h =
      (zapp_cef_asset_resource_handler_t*)self;
  int remaining = h->length - h->offset;
  int result;
  if (remaining <= 0) {
    *bytes_read = 0;
    result = 0;  // response complete.
  } else {
    int n = bytes_to_read < remaining ? bytes_to_read : remaining;
    memcpy(data_out, h->data + h->offset, (size_t)n);
    h->offset += n;
    *bytes_read = n;
    result = 1;
  }
  // LEAK FIX: same refptr_diff family — read() is always serviced
  // synchronously here.
  if (callback != NULL) {
    callback->base.release(&callback->base);
  }
  return result;
}

void CEF_CALLBACK zapp_cef_asset_resource_handler_cancel(
    cef_resource_handler_t* self) {
  (void)self;  // nothing request-scoped to clean up; an owned decode buffer
               // (if any) is freed by release() above, not here.
}

static cef_resource_handler_t* zapp_cef_asset_resource_handler_create(
    uint8_t* data, int owns_data, int length, int status,
    const char* mime_type) {
  zapp_cef_asset_resource_handler_t* h =
      (zapp_cef_asset_resource_handler_t*)calloc(
          1, sizeof(zapp_cef_asset_resource_handler_t));
  CHECK(h);

  INIT_CEF_BASE_REFCOUNTED(&h->handler.base, cef_resource_handler_t,
                           zapp_cef_asset_resource_handler);
  h->handler.open = zapp_cef_asset_resource_handler_open;
  h->handler.get_response_headers =
      zapp_cef_asset_resource_handler_get_response_headers;
  h->handler.skip = zapp_cef_asset_resource_handler_skip;
  h->handler.read = zapp_cef_asset_resource_handler_read;
  h->handler.cancel = zapp_cef_asset_resource_handler_cancel;

  h->data = data;
  h->owns_data = owns_data;
  h->length = length;
  h->offset = 0;
  h->status = status;
  h->mime_type = mime_type;

  atomic_store(&h->ref_count, 1);
  return &h->handler;
}

// ---------------------------------------------------------------------------
// cef_scheme_handler_factory_t — looks the request path up in the real
// embedded-asset table.
// ---------------------------------------------------------------------------

typedef struct _zapp_cef_scheme_factory_t {
  // MUST be first member — CEF base structure.
  cef_scheme_handler_factory_t factory;
  atomic_int ref_count;
} zapp_cef_scheme_factory_t;

IMPLEMENT_REFCOUNTING_SIMPLE(zapp_cef_scheme_factory_t, zapp_cef_scheme_factory,
                             ref_count)

struct _cef_resource_handler_t* CEF_CALLBACK zapp_cef_scheme_factory_create(
    struct _cef_scheme_handler_factory_t* self, struct _cef_browser_t* browser,
    struct _cef_frame_t* frame, const cef_string_t* scheme_name,
    struct _cef_request_t* request) {
  (void)self;
  (void)scheme_name;

  // Dev-mode hook: when the CLI's build config says assets are NOT baked in
  // (dev-server mode), don't serve zapp:// at all — a later task points the
  // browser directly at Vite's resolved devUrl instead of navigating here.
  // Returning NULL is the CEF idiom for "no handler" (a benign network error
  // if this ever DID get requested in dev, which the window-creation branch
  // avoids by construction).
  if (!zapp_build_use_embedded_assets()) {
    // Still release the owned refptr_diff params below before returning —
    // see the end-of-function release block.
    goto done_no_handler;
  }

  {
    cef_string_userfree_t req_url = request->get_url(request);
    if (req_url == NULL) {
      goto done_no_handler;
    }

    cef_urlparts_t parts;
    memset(&parts, 0, sizeof(parts));
    parts.size = sizeof(parts);
    int parsed = cef_parse_url(req_url, &parts);
    cef_string_userfree_free(req_url);
    if (!parsed) {
      goto done_no_handler;
    }

    cef_string_utf8_t host_utf8, path_utf8;
    memset(&host_utf8, 0, sizeof(host_utf8));
    memset(&path_utf8, 0, sizeof(path_utf8));
    cef_string_utf16_to_utf8(parts.host.str, parts.host.length, &host_utf8);
    cef_string_utf16_to_utf8(parts.path.str, parts.path.length, &path_utf8);

    char* lookup_path = zapp_cef_normalize_request_path(
        host_utf8.str ? host_utf8.str : "", path_utf8.str ? path_utf8.str : "");

    cef_string_utf8_clear(&host_utf8);
    cef_string_utf8_clear(&path_utf8);
    // cef_urlparts_t owns its string fields (cef_parse_url allocates them via
    // cef_string_set) — clear all ten, mirroring the C++ wrapper's
    // CefURLPartsTraits::clear (cef_types_wrappers.h).
    cef_string_clear(&parts.spec);
    cef_string_clear(&parts.scheme);
    cef_string_clear(&parts.username);
    cef_string_clear(&parts.password);
    cef_string_clear(&parts.host);
    cef_string_clear(&parts.port);
    cef_string_clear(&parts.origin);
    cef_string_clear(&parts.path);
    cef_string_clear(&parts.query);
    cef_string_clear(&parts.fragment);

    cef_resource_handler_t* handler = NULL;

    if (lookup_path == NULL) {
      // Path-traversal attempt — mirrors ZappAssetSchemeHandler's 403.
      static const char kForbidden[] = "Forbidden";
      handler = zapp_cef_asset_resource_handler_create(
          (uint8_t*)kForbidden, /*owns_data=*/0, (int)strlen(kForbidden), 403,
          "text/plain");
    } else {
      // Embedded-asset lookup + brotli decode. The weak-symbol address check
      // (not a compile-time #ifdef — that can't see a macro #define'd in the
      // generated table's *separate* translation unit) guards the case where
      // no asset table is linked; the generated table always links the
      // symbols (count 0 in dev, already excluded above), so this is true in
      // any real build. Mirrors webview.m's ZappAssetSchemeHandler exactly.
      if (&zapp_embedded_assets_count != NULL) {
        for (int i = 0; i < zapp_embedded_assets_count; i++) {
          if (strcmp(zapp_embedded_assets[i].path, lookup_path) == 0) {
            const char* mime = zapp_cef_mime_for_path(lookup_path);
            if (zapp_embedded_assets[i].is_brotli &&
                zapp_embedded_assets[i].uncompressed_len > 0) {
              size_t out_len = (size_t)zapp_embedded_assets[i].uncompressed_len;
              uint8_t* out = (uint8_t*)malloc(out_len);
              CHECK(out);
              size_t decoded = compression_decode_buffer(
                  out, out_len, zapp_embedded_assets[i].data,
                  (size_t)zapp_embedded_assets[i].len, NULL,
                  COMPRESSION_BROTLI);
              handler = zapp_cef_asset_resource_handler_create(
                  out, /*owns_data=*/1, (int)decoded, 200, mime);
            } else {
              handler = zapp_cef_asset_resource_handler_create(
                  zapp_embedded_assets[i].data, /*owns_data=*/0,
                  zapp_embedded_assets[i].len, 200, mime);
            }
            break;
          }
        }
      }

      if (handler == NULL) {
        fprintf(stderr, "[zapp-cef] zapp:// not found: %s\n", lookup_path);
        static const char kNotFound[] = "Not Found";
        handler = zapp_cef_asset_resource_handler_create(
            (uint8_t*)kNotFound, /*owns_data=*/0, (int)strlen(kNotFound), 404,
            "text/plain");
      }
    }

    free(lookup_path);

    // Release the owned refptr_diff params (verified against
    // libcef_dll/cpptoc/scheme_handler_factory_cpptoc.cc: |request| is
    // `refptr_diff`; |browser|/|frame| are "unverified" — i.e. may be NULL —
    // but are wrapped the same CToCpp_Wrap way, so release them too when
    // present). Our RETURNED |handler| is `refptr_same` — CEF consumes that
    // reference, so it is NOT released here.
    request->base.release(&request->base);
    if (browser != NULL) {
      browser->base.release(&browser->base);
    }
    if (frame != NULL) {
      frame->base.release(&frame->base);
    }
    return handler;
  }

done_no_handler:
  request->base.release(&request->base);
  if (browser != NULL) {
    browser->base.release(&browser->base);
  }
  if (frame != NULL) {
    frame->base.release(&frame->base);
  }
  return NULL;
}

static cef_scheme_handler_factory_t* zapp_cef_scheme_factory_create_instance(
    void) {
  zapp_cef_scheme_factory_t* f = (zapp_cef_scheme_factory_t*)calloc(
      1, sizeof(zapp_cef_scheme_factory_t));
  CHECK(f);

  INIT_CEF_BASE_REFCOUNTED(&f->factory.base, cef_scheme_handler_factory_t,
                           zapp_cef_scheme_factory);
  f->factory.create = zapp_cef_scheme_factory_create;

  atomic_store(&f->ref_count, 1);
  return &f->factory;
}

// ---------------------------------------------------------------------------
// 1. Scheme registration (runs in EVERY process).
// ---------------------------------------------------------------------------

void zapp_cef_register_zapp_scheme(cef_scheme_registrar_t* registrar) {
  const char* name = "zapp";
  cef_string_t scheme_name;
  memset(&scheme_name, 0, sizeof(scheme_name));
  cef_string_utf8_to_utf16(name, strlen(name), &scheme_name);

  // STANDARD: parses as scheme://host/path (so zapp://index.html and
  // zapp://app/some/asset.js both parse; see
  // zapp_cef_normalize_request_path's host-as-path handling above). SECURE:
  // no mixed-content warnings (treated like https). CORS_ENABLED +
  // FETCH_ENABLED: page-originated fetch("zapp://...") calls are permitted.
  int options = CEF_SCHEME_OPTION_STANDARD | CEF_SCHEME_OPTION_SECURE |
                CEF_SCHEME_OPTION_CORS_ENABLED | CEF_SCHEME_OPTION_FETCH_ENABLED;

  if (!registrar->add_custom_scheme(registrar, &scheme_name, options)) {
    fprintf(stderr, "[zapp-cef] add_custom_scheme(zapp) failed\n");
  }
  cef_string_clear(&scheme_name);
}

// ---------------------------------------------------------------------------
// 2. Install the factory (browser process only, AFTER cef_initialize — see
// zapp_cef_app.c's on_context_initialized).
// ---------------------------------------------------------------------------

void zapp_cef_install_scheme_handler_factory(void) {
  const char* scheme = "zapp";
  cef_string_t scheme_str;
  memset(&scheme_str, 0, sizeof(scheme_str));
  cef_string_utf8_to_utf16(scheme, strlen(scheme), &scheme_str);

  // Ref count 1 -> transferred to CEF by cef_register_scheme_handler_factory
  // (refptr_same — consumed), same convention as zapp_cef_app_create /
  // zapp_cef_client_create.
  cef_scheme_handler_factory_t* factory = zapp_cef_scheme_factory_create_instance();
  int ok = cef_register_scheme_handler_factory(&scheme_str, NULL, factory);
  cef_string_clear(&scheme_str);

  if (!ok) {
    fprintf(stderr,
            "[zapp-cef] cef_register_scheme_handler_factory(zapp) failed\n");
  } else {
    fprintf(stderr,
            "[zapp-cef] zapp:// scheme handler factory registered "
            "(embedded assets: %s)\n",
            zapp_build_use_embedded_assets() ? "on" : "off (dev mode)");
  }
}
