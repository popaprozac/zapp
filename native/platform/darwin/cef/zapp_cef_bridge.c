// Zapp CEF host (macOS) — the RENDER-process half of the `zapp` bridge.
//
// Promoted from the proven GO spike (`spikes/cef-macos/bridge.c` — see
// docs/superpowers/specs/2026-07-05-cef-webengine-production-slice-macos-
// design.md and spikes/cef-macos/FINDINGS.md, Task 4). Renamed cefspike_ ->
// zapp_cef_, "spike" dropped. R1 rewired the spike's `greet`-stub protocol to
// the REAL Zapp bridge contract.
//
// This is the render half of "does the Zapp JS<->native contract map onto
// CEF." CEF's own promise plumbing (CefMessageRouter / window.cefQuery) is
// C++-only (libcef_dll_wrapper); this is on the raw C API. Two CEF processes
// cooperate, but far more thinly than the spike:
//
//   * RENDER process (this file, compiled into the Helper subprocess via
//     zapp_cef_mac_helper.c) — owns the V8 context. It (a) binds one native
//     V8 function __zappSendNative(str) that ships the raw bridge envelope to
//     the browser as a "zapp:invoke" process message, and (b) evals the REAL
//     Zapp doc-start bootstrap (the compiled bootstrap/webview.ts, PLUS the
//     Symbol.for('zapp.*') carriers, PLUS a webkit.messageHandlers.zapp shim
//     that routes the runtime's post() to __zappSendNative). The Helper runs
//     no Nim and can't build any of that; the BROWSER process builds the whole
//     doc-start string (reusing zapp_webview_bootstrap_script() /
//     permissions_bootstrap_json() / service_get_manifest_json() / etc., see
//     zapp_cef_host.m) and hands it here via CEF's create-browser extra_info
//     (delivered to on_browser_created).
//
//   * BROWSER process (zapp_cef_client.c) — hands the envelope to the REAL Nim
//     router and delivers the result back by eval'ing into the page (via
//     darwin_window_eval_js's CEF branch -> zapp_cef_eval_in_window). There is
//     NO reverse "zapp:result" process message — the render side never handles
//     a reply, so this file no longer implements on_process_message_received.
//
// Message protocol (the ONE name both processes must agree on):
//   "zapp:invoke"  RENDER -> BROWSER   args [0]=envelope:str  ({t,id,m,a} JSON)
//
// The runtime resolves its own promise: bootstrap/webview.ts's _onInvokeResult
// is called by the JS the router eval's back into the page — no render-side
// promise map is needed here.

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zapp_cef_refcount.h"
#include "zapp_cef.h"

#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_process_message_capi.h"
#include "include/capi/cef_render_process_handler_capi.h"
#include "include/capi/cef_v8_capi.h"
#include "include/capi/cef_values_capi.h"

// The doc-start bootstrap string is built in the BROWSER process (it needs
// zapp_webview_bootstrap_script() + the native carrier sources, none of which
// the Helper links) and handed to this render process via CEF create-browser
// extra_info -> on_browser_created. Stashed here (single browser this slice)
// and eval'd in on_context_created. strdup'd copy owned by this process for
// its lifetime; never freed (process-lifetime, single browser).
static char* g_bootstrap_js = NULL;

// Process-message name — the cross-process contract hinges on this literal
// matching zapp_cef_client.c exactly.
#define ZAPP_MSG_INVOKE "zapp:invoke"
// extra_info key carrying the doc-start bootstrap JS (must match
// zapp_cef_host.m's set_string key).
#define ZAPP_EXTRA_BOOTSTRAP_KEY "zappBootstrap"

// ---------------------------------------------------------------------------
// Small cef_string helpers (mirrors zapp_cef_scheme_handler.c's usage; CEF
// strings are UTF-16 in this SDK build — see
// cef_binary/include/internal/cef_string.h).
// ---------------------------------------------------------------------------

// Fill a zeroed cef_string_t (UTF-16) from a UTF-8 C string. Caller must
// cef_string_clear() it. |out| must be zeroed before the first call.
static void cef_str_set_utf8(cef_string_t* out, const char* utf8) {
  cef_string_utf8_to_utf16(utf8, strlen(utf8), out);
}

// ---------------------------------------------------------------------------
// V8 handler — backs window.__zappSendNative(envelope). |envelope| is the raw
// `{t,id,m,a}` bridge string (bootstrap/webview.ts's post() argument, routed
// here by the webkit.messageHandlers.zapp shim the browser-built bootstrap
// installs). We forward it VERBATIM as the single arg of a "zapp:invoke"
// process message to the browser — no parsing here; the Nim router owns that.
// Runs on the render main thread inside a V8 callback, so it may create process
// messages and touch the current frame directly.
// ---------------------------------------------------------------------------

typedef struct _zapp_cef_v8_handler_t {
  cef_v8_handler_t handler;  // MUST be first.
  atomic_int ref_count;
} zapp_cef_v8_handler_t;

IMPLEMENT_REFCOUNTING_SIMPLE(zapp_cef_v8_handler_t, zapp_cef_v8_handler,
                             ref_count)

int CEF_CALLBACK zapp_cef_v8_handler_execute(
    cef_v8_handler_t* self, const cef_string_t* name,
    cef_v8_value_t* object, size_t argumentsCount,
    cef_v8_value_t* const* arguments, cef_v8_value_t** retval,
    cef_string_t* exception) {
  (void)self;
  (void)name;
  (void)retval;

  if (argumentsCount >= 1 && arguments[0] != NULL) {
    // The envelope is UTF-16 already; forward it straight into the message
    // argument list (set_string takes a cef_string_t*, and
    // cef_string_userfree_t IS a cef_string_t*).
    cef_string_userfree_t js_env = arguments[0]->get_string_value(arguments[0]);

    // The current V8 context knows its frame — no need to have stored one.
    cef_v8_context_t* ctx = cef_v8_context_get_current_context();
    cef_frame_t* frame = (ctx != NULL) ? ctx->get_frame(ctx) : NULL;

    if (frame != NULL) {
      cef_string_t msg_name;
      memset(&msg_name, 0, sizeof(msg_name));
      cef_str_set_utf8(&msg_name, ZAPP_MSG_INVOKE);
      cef_process_message_t* msg = cef_process_message_create(&msg_name);
      cef_string_clear(&msg_name);

      cef_list_value_t* args = msg->get_argument_list(msg);
      if (js_env != NULL) {
        args->set_string(args, 0, js_env);
      } else {
        args->set_null(args, 0);
      }
      args->base.release(&args->base);

      // send_process_message's message param is refptr_same — it CONSUMES our
      // |msg| reference (and the header notes |msg| is invalidated after). |msg|
      // came from cef_process_message_create with ref=1 (ours), so this transfers
      // it to CEF. Do NOT release |msg| afterward — that was a double-release.
      frame->send_process_message(frame, PID_BROWSER, msg);
      frame->base.release(&frame->base);
    } else {
      fprintf(stderr,
              "[zapp-cef][render] __zappSendNative: no current frame\n");
    }

    if (ctx != NULL) {
      ctx->base.release(&ctx->base);
    }
    if (js_env != NULL) {
      cef_string_userfree_free(js_env);
    }
  } else {
    cef_str_set_utf8(exception, "__zappSendNative expects (envelope)");
  }

  // Release the owned callback params (CEF C-API: these arrive as refptr_diff /
  // refptr_vec_diff — ownership transferred to the callee, same convention as
  // the life-span handler's browser param). retval is left undefined — the JS
  // wrapper ignores it.
  if (object != NULL) {
    object->base.release(&object->base);
  }
  for (size_t i = 0; i < argumentsCount; i++) {
    if (arguments[i] != NULL) {
      arguments[i]->base.release(&arguments[i]->base);
    }
  }
  return 1;  // handled.
}

static cef_v8_handler_t* zapp_cef_v8_handler_create(void) {
  zapp_cef_v8_handler_t* h =
      (zapp_cef_v8_handler_t*)calloc(1, sizeof(zapp_cef_v8_handler_t));
  CHECK(h);
  INIT_CEF_BASE_REFCOUNTED(&h->handler.base, cef_v8_handler_t,
                           zapp_cef_v8_handler);
  h->handler.execute = zapp_cef_v8_handler_execute;
  atomic_store(&h->ref_count, 1);
  return &h->handler;
}

// ---------------------------------------------------------------------------
// Render process handler. (No native->JS delivery lives here anymore: the
// router eval's the invoke result straight into the page from the BROWSER
// process via darwin_window_eval_js -> zapp_cef_eval_in_window, so the render
// side never handles a reply message and needs no JSON escaping.)
// ---------------------------------------------------------------------------

typedef struct _zapp_cef_rph_t {
  cef_render_process_handler_t handler;  // MUST be first.
  atomic_int ref_count;
} zapp_cef_rph_t;

IMPLEMENT_REFCOUNTING_SIMPLE(zapp_cef_rph_t, zapp_cef_rph, ref_count)

// on_browser_created: stash the doc-start bootstrap JS the browser process
// passed via create-browser extra_info (key ZAPP_EXTRA_BOOTSTRAP_KEY). This
// fires before any V8 context is created, so g_bootstrap_js is set by the time
// on_context_created (below) needs it.
void CEF_CALLBACK zapp_cef_rph_on_browser_created(
    cef_render_process_handler_t* self, cef_browser_t* browser,
    cef_dictionary_value_t* extra_info) {
  (void)self;

  if (extra_info != NULL) {
    cef_string_t key;
    memset(&key, 0, sizeof(key));
    cef_str_set_utf8(&key, ZAPP_EXTRA_BOOTSTRAP_KEY);
    // get_string returns a userfree cef_string_t (owned — free it after copy).
    cef_string_userfree_t val = extra_info->get_string(extra_info, &key);
    cef_string_clear(&key);
    if (val != NULL) {
      cef_string_utf8_t u;
      memset(&u, 0, sizeof(u));
      cef_string_utf16_to_utf8(val->str, val->length, &u);
      cef_string_userfree_free(val);
      if (u.str != NULL) {
        if (g_bootstrap_js != NULL) {
          free(g_bootstrap_js);  // re-create (cross-origin) — replace.
        }
        g_bootstrap_js = strdup(u.str);
      }
      cef_string_utf8_clear(&u);
    }
  }

  // Release the owned callback params (refptr_diff — same convention as the
  // life-span handler's browser param). extra_info is likewise an owned ref.
  browser->base.release(&browser->base);
  if (extra_info != NULL) {
    extra_info->base.release(&extra_info->base);
  }
}

// Document-start: (a) bind the native function on the global, then (b) eval the
// browser-built bootstrap (shim + Symbol.for('zapp.*') carriers + the real
// compiled bootstrap/webview.ts). Binding first means __zappSendNative already
// exists when the shim (and any later page script) references it.
void CEF_CALLBACK zapp_cef_rph_on_context_created(
    cef_render_process_handler_t* self, cef_browser_t* browser,
    cef_frame_t* frame, cef_v8_context_t* context) {
  (void)self;

  // Every V8 result below is NULL-guarded so a failed create/get can never
  // NULL-deref (crash) the render process.

  // (a) Bind window.__zappSendNative = <native function>. get_global() requires
  // the context to be entered.
  if (context->enter(context)) {
    cef_v8_value_t* global = context->get_global(context);
    if (global != NULL) {
      cef_string_t fn_name;
      memset(&fn_name, 0, sizeof(fn_name));
      cef_str_set_utf8(&fn_name, "__zappSendNative");

      cef_v8_handler_t* v8h = zapp_cef_v8_handler_create();
      cef_v8_value_t* fn = cef_v8_value_create_function(&fn_name, v8h);
      // create_function RETAINS the handler (refptr_diff, CppToC_Wrap adds a
      // ref) — so drop our construction ref.
      v8h->base.release(&v8h->base);
      cef_string_clear(&fn_name);

      if (fn != NULL) {
        cef_string_t key;
        memset(&key, 0, sizeof(key));
        cef_str_set_utf8(&key, "__zappSendNative");
        // REFCOUNT (load-bearing): set_value_bykey's value param is refptr_same
        // — it CONSUMES the reference we pass (the translator Unwraps it with an
        // added ref the receiver releases). |fn| came from create_function with
        // ref=1 (ours), so passing it here transfers that ref to |global|. We
        // must NOT release |fn| afterward — doing so was a double-release that
        // crashed the render process HERE in the original spike (the T4
        // blank-screen bug). Same rule as send_process_message below.
        global->set_value_bykey(global, &key, fn, V8_PROPERTY_ATTRIBUTE_NONE);
        cef_string_clear(&key);
      } else {
        fprintf(stderr, "[zapp-cef][render] create_function returned NULL "
                        "(binding skipped)\n");
      }
      global->base.release(&global->base);
    } else {
      fprintf(stderr, "[zapp-cef][render] get_global returned NULL\n");
    }

    // (b) Eval the browser-built doc-start bootstrap IN this freshly-created
    // context via context->eval (synchronous, scoped to THIS context) rather
    // than frame->execute_java_script — keeps injection off the frame's async
    // script path while we're still inside on_context_created. The string
    // installs the webkit.messageHandlers.zapp shim (-> __zappSendNative), the
    // Symbol.for('zapp.*') carriers, and the real bridge (bootstrap/webview.ts).
    if (g_bootstrap_js != NULL) {
      cef_string_t code, url;
      memset(&code, 0, sizeof(code));
      memset(&url, 0, sizeof(url));
      cef_str_set_utf8(&code, g_bootstrap_js);
      cef_v8_value_t* eval_ret = NULL;
      cef_v8_exception_t* eval_exc = NULL;
      context->eval(context, &code, &url, 0, &eval_ret, &eval_exc);
      cef_string_clear(&code);
      if (eval_exc != NULL) {
        // Surface a bootstrap error rather than silently blanking — the page
        // would have no bridge and every Services.invoke would hang.
        cef_string_userfree_t emsg = eval_exc->get_message(eval_exc);
        cef_string_utf8_t eu;
        memset(&eu, 0, sizeof(eu));
        if (emsg != NULL) {
          cef_string_utf16_to_utf8(emsg->str, emsg->length, &eu);
          cef_string_userfree_free(emsg);
        }
        fprintf(stderr, "[zapp-cef][render] bootstrap eval exception: %s\n",
                eu.str ? eu.str : "(unknown)");
        cef_string_utf8_clear(&eu);
        eval_exc->base.release(&eval_exc->base);
      }
      if (eval_ret != NULL) {
        eval_ret->base.release(&eval_ret->base);
      }
    } else {
      fprintf(stderr, "[zapp-cef][render] no bootstrap (extra_info missing) — "
                      "bridge NOT installed\n");
    }

    context->exit(context);
  } else {
    fprintf(stderr, "[zapp-cef][render] context->enter failed\n");
  }

  fprintf(stderr, "[zapp-cef][render] bridge bootstrap injected "
                  "(zapp.bridge ready)\n");

  // Release the owned callback params (refptr_diff — same convention as the
  // life-span handler's browser param).
  browser->base.release(&browser->base);
  frame->base.release(&frame->base);
  context->base.release(&context->base);
}

// ---------------------------------------------------------------------------
// Factory — called from zapp_cef_mac_helper.c (the Helper/render subprocess
// entry). Returns with ref count 1; the Helper app owns it and releases on
// teardown. NB no on_process_message_received: the browser answers by eval'ing
// the result into the page (darwin_window_eval_js -> zapp_cef_eval_in_window),
// not by sending the render process a reply message.
// ---------------------------------------------------------------------------

cef_render_process_handler_t* zapp_cef_render_process_handler_create(void) {
  zapp_cef_rph_t* rph = (zapp_cef_rph_t*)calloc(1, sizeof(zapp_cef_rph_t));
  CHECK(rph);
  INIT_CEF_BASE_REFCOUNTED(&rph->handler.base, cef_render_process_handler_t,
                           zapp_cef_rph);
  rph->handler.on_browser_created = zapp_cef_rph_on_browser_created;
  rph->handler.on_context_created = zapp_cef_rph_on_context_created;
  atomic_store(&rph->ref_count, 1);
  return &rph->handler;
}
