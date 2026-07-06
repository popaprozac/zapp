// CEF spike (Task 4) — the RENDER-process half of the `zapp` bridge.
//
// This is the make-or-break file for "does the Zapp JS<->native contract map
// onto CEF." CEF's own promise plumbing (CefMessageRouter / window.cefQuery)
// is C++-only (libcef_dll_wrapper); we're on the raw C API, so we hand-roll the
// equivalent with cef_v8 + cef_process_message. Two CEF processes cooperate:
//
//   * RENDER process (this file, compiled into the Helper subprocess via
//     mac_helper.c) — owns the V8 context. It injects the document-start
//     bootstrap that defines window.zapp.invoke(), binds a native V8 function
//     (__zappSendNative) that ships a "zapp:invoke" process message to the
//     browser, and — on the "zapp:result" reply — resolves the JS promise.
//
//   * BROWSER process (cef_client.c) — runs the STUB service and ships the
//     "zapp:result" reply back. See cef_client.c's on_process_message_received.
//
// Message protocol (both processes must agree on the NAMES):
//   "zapp:invoke"  RENDER -> BROWSER   args [0]=id:int, [1]=name:str, [2]=argsJSON:str
//   "zapp:result"  BROWSER -> RENDER   args [0]=id:int, [1]=resultJSON:str
//
// Native->JS delivery uses frame->execute_java_script("window.__zappResolve(
// <id>, <resultJSON>)") — the "simplest robust path" from the task brief. It
// sidesteps storing a cef_v8_context_t across the async round-trip: the render
// frame handed to on_process_message_received is enough to re-enter JS. The
// resolver is defined by the same document-start bootstrap.
//
// WHY the bootstrap JS lives in a C string here (rather than a bootstrap/*.ts
// through codegen, per the usual Zapp convention): the render handler runs in
// the Helper subprocess, which does NOT run Nim and never staticRead()s an
// asset. bridge.c is the only code that reaches the render V8 context, so the
// bootstrap has to compile INTO the Helper binary. See FINDINGS Task 4.

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cef_refcount.h"
#include "cef_spike.h"

#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_process_message_capi.h"
#include "include/capi/cef_render_process_handler_capi.h"
#include "include/capi/cef_v8_capi.h"
#include "include/capi/cef_values_capi.h"

// ---------------------------------------------------------------------------
// Document-start bootstrap. Defines window.zapp.invoke(name, args) -> Promise,
// an id->{resolve,reject} pending map, and the window.__zappResolve/__zappReject
// hooks the render handler calls via execute_java_script. invoke() marshals to
// the native binding window.__zappSendNative(id, name, JSON.stringify(args)),
// which bridge.c installs on the global before this runs.
// ---------------------------------------------------------------------------

static const char* kZappBootstrapJS =
    "(function () {\n"
    "  if (window.zapp && window.zapp.__installed) return;\n"
    "  var pending = Object.create(null);\n"
    "  var nextId = 1;\n"
    "  window.__zappResolve = function (id, result) {\n"
    "    var cb = pending[id];\n"
    "    if (!cb) return;\n"
    "    delete pending[id];\n"
    "    cb.resolve(result);\n"
    "  };\n"
    "  window.__zappReject = function (id, message) {\n"
    "    var cb = pending[id];\n"
    "    if (!cb) return;\n"
    "    delete pending[id];\n"
    "    cb.reject(new Error(message));\n"
    "  };\n"
    "  window.zapp = {\n"
    "    __installed: true,\n"
    "    invoke: function (name, args) {\n"
    "      return new Promise(function (resolve, reject) {\n"
    "        var id = nextId++;\n"
    "        pending[id] = { resolve: resolve, reject: reject };\n"
    "        try {\n"
    "          window.__zappSendNative(id, name, JSON.stringify(args || {}));\n"
    "        } catch (e) {\n"
    "          delete pending[id];\n"
    "          reject(e);\n"
    "        }\n"
    "      });\n"
    "    }\n"
    "  };\n"
    "})();\n";

// Process-message names — the whole cross-process contract hinges on these two
// string literals matching cef_client.c exactly.
#define ZAPP_MSG_INVOKE "zapp:invoke"
#define ZAPP_MSG_RESULT "zapp:result"

// ---------------------------------------------------------------------------
// Small cef_string helpers (mirrors scheme_handler.c's usage; CEF strings are
// UTF-16 in this SDK build — see cef_binary/include/internal/cef_string.h).
// ---------------------------------------------------------------------------

// Fill a zeroed cef_string_t (UTF-16) from a UTF-8 C string. Caller must
// cef_string_clear() it. |out| must be zeroed before the first call.
static void cef_str_set_utf8(cef_string_t* out, const char* utf8) {
  cef_string_utf8_to_utf16(utf8, strlen(utf8), out);
}

// ---------------------------------------------------------------------------
// V8 handler — backs window.__zappSendNative(id, name, argsJSON). Runs on the
// render main thread inside a V8 callback, so it may create process messages
// and touch the current frame directly.
// ---------------------------------------------------------------------------

typedef struct _cefspike_v8_handler_t {
  cef_v8_handler_t handler;  // MUST be first.
  atomic_int ref_count;
} cefspike_v8_handler_t;

IMPLEMENT_REFCOUNTING_SIMPLE(cefspike_v8_handler_t, cefspike_v8_handler,
                             ref_count)

int CEF_CALLBACK cefspike_v8_handler_execute(
    cef_v8_handler_t* self, const cef_string_t* name,
    cef_v8_value_t* object, size_t argumentsCount,
    cef_v8_value_t* const* arguments, cef_v8_value_t** retval,
    cef_string_t* exception) {
  (void)self;
  (void)name;
  (void)retval;

  if (argumentsCount >= 3 && arguments[0] != NULL && arguments[1] != NULL &&
      arguments[2] != NULL) {
    int id = arguments[0]->get_int_value(arguments[0]);
    // name + argsJSON are UTF-16 already; forward them straight into the
    // message argument list (set_string takes a cef_string_t*, and
    // cef_string_userfree_t IS a cef_string_t*).
    cef_string_userfree_t js_name = arguments[1]->get_string_value(arguments[1]);
    cef_string_userfree_t js_args = arguments[2]->get_string_value(arguments[2]);

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
      args->set_int(args, 0, id);
      if (js_name != NULL) {
        args->set_string(args, 1, js_name);
      } else {
        args->set_null(args, 1);
      }
      if (js_args != NULL) {
        args->set_string(args, 2, js_args);
      } else {
        args->set_null(args, 2);
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
              "[cef-spike][render] __zappSendNative: no current frame\n");
    }

    if (ctx != NULL) {
      ctx->base.release(&ctx->base);
    }
    if (js_name != NULL) {
      cef_string_userfree_free(js_name);
    }
    if (js_args != NULL) {
      cef_string_userfree_free(js_args);
    }
  } else {
    cef_str_set_utf8(exception, "__zappSendNative expects (id, name, argsJSON)");
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

static cef_v8_handler_t* cefspike_v8_handler_create(void) {
  cefspike_v8_handler_t* h =
      (cefspike_v8_handler_t*)calloc(1, sizeof(cefspike_v8_handler_t));
  CHECK(h);
  INIT_CEF_BASE_REFCOUNTED(&h->handler.base, cef_v8_handler_t,
                           cefspike_v8_handler);
  h->handler.execute = cefspike_v8_handler_execute;
  atomic_store(&h->ref_count, 1);
  return &h->handler;
}

// ---------------------------------------------------------------------------
// JSON string escaping — for the native->JS delivery. resultJSON arrives as a
// JSON *value* (the browser already quoted+escaped it), so on the render side
// we splice it verbatim into "window.__zappResolve(<id>, <resultJSON>)". No
// escaping needed here; the browser owns it. (See cef_client.c.)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Render process handler.
// ---------------------------------------------------------------------------

typedef struct _cefspike_rph_t {
  cef_render_process_handler_t handler;  // MUST be first.
  atomic_int ref_count;
} cefspike_rph_t;

IMPLEMENT_REFCOUNTING_SIMPLE(cefspike_rph_t, cefspike_rph, ref_count)

// Document-start: (a) bind the native function on the global, then (b) run the
// bootstrap. Binding first means __zappSendNative already exists when any later
// page script calls window.zapp.invoke().
void CEF_CALLBACK cefspike_rph_on_context_created(
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

      cef_v8_handler_t* v8h = cefspike_v8_handler_create();
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
        // crashed the render process HERE (the T4 blank-screen bug). Same rule
        // as send_process_message below.
        global->set_value_bykey(global, &key, fn, V8_PROPERTY_ATTRIBUTE_NONE);
        cef_string_clear(&key);
      } else {
        fprintf(stderr, "[cef-spike][render] create_function returned NULL "
                        "(binding skipped)\n");
      }
      global->base.release(&global->base);
    } else {
      fprintf(stderr, "[cef-spike][render] get_global returned NULL\n");
    }

    // (b) Run the document-start bootstrap IN this freshly-created context via
    // context->eval (synchronous, scoped to THIS context) rather than
    // frame->execute_java_script — keeps injection off the frame's async script
    // path while we're still inside on_context_created.
    cef_string_t code, url;
    memset(&code, 0, sizeof(code));
    memset(&url, 0, sizeof(url));
    cef_str_set_utf8(&code, kZappBootstrapJS);
    cef_v8_value_t* eval_ret = NULL;
    cef_v8_exception_t* eval_exc = NULL;
    context->eval(context, &code, &url, 0, &eval_ret, &eval_exc);
    cef_string_clear(&code);
    if (eval_ret != NULL) {
      eval_ret->base.release(&eval_ret->base);
    }
    if (eval_exc != NULL) {
      eval_exc->base.release(&eval_exc->base);
    }

    context->exit(context);
  } else {
    fprintf(stderr, "[cef-spike][render] context->enter failed\n");
  }

  fprintf(stderr, "[cef-spike][render] bridge bootstrap injected "
                  "(window.zapp.invoke ready)\n");

  // Release the owned callback params (refptr_diff — same convention as the
  // life-span handler's browser param).
  browser->base.release(&browser->base);
  frame->base.release(&frame->base);
  context->base.release(&context->base);
}

// "zapp:result" reply from the browser process -> resolve the JS promise.
int CEF_CALLBACK cefspike_rph_on_process_message_received(
    cef_render_process_handler_t* self, cef_browser_t* browser,
    cef_frame_t* frame, cef_process_id_t source_process,
    cef_process_message_t* message) {
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

  if (name_utf8.str != NULL && strcmp(name_utf8.str, ZAPP_MSG_RESULT) == 0) {
    cef_list_value_t* args = message->get_argument_list(message);
    int id = args->get_int(args, 0);

    // resultJSON is already a JSON value (browser-escaped) — convert to UTF-8.
    cef_string_userfree_t result = args->get_string(args, 1);
    cef_string_utf8_t result_utf8;
    memset(&result_utf8, 0, sizeof(result_utf8));
    if (result != NULL) {
      cef_string_utf16_to_utf8(result->str, result->length, &result_utf8);
      cef_string_userfree_free(result);
    }
    args->base.release(&args->base);

    const char* result_json = result_utf8.str ? result_utf8.str : "null";
    // Heap-allocate the JS call (avoid the stack-buffer truncation family of
    // bugs — see the dispatch/JSON buffer lessons in the Zapp memory).
    size_t need = strlen("window.__zappResolve(, );") + 24 /* id */ +
                  strlen(result_json) + 1;
    char* js = (char*)malloc(need);
    CHECK(js);
    snprintf(js, need, "window.__zappResolve(%d, %s);", id, result_json);

    cef_string_t code, empty;
    memset(&code, 0, sizeof(code));
    memset(&empty, 0, sizeof(empty));
    cef_str_set_utf8(&code, js);
    frame->execute_java_script(frame, &code, &empty, 0);
    cef_string_clear(&code);
    free(js);

    fprintf(stderr, "[cef-spike][render] zapp:result id=%d -> resolving JS\n",
            id);
    cef_string_utf8_clear(&result_utf8);
    handled = 1;
  }

  cef_string_utf8_clear(&name_utf8);

  // Release the owned callback params (refptr_diff).
  browser->base.release(&browser->base);
  frame->base.release(&frame->base);
  message->base.release(&message->base);
  return handled;
}

// ---------------------------------------------------------------------------
// Factory — called from mac_helper.c (the Helper/render subprocess entry).
// Returns with ref count 1; the Helper app owns it and releases on teardown.
// ---------------------------------------------------------------------------

cef_render_process_handler_t* cefspike_render_process_handler_create(void) {
  cefspike_rph_t* rph = (cefspike_rph_t*)calloc(1, sizeof(cefspike_rph_t));
  CHECK(rph);
  INIT_CEF_BASE_REFCOUNTED(&rph->handler.base, cef_render_process_handler_t,
                           cefspike_rph);
  rph->handler.on_context_created = cefspike_rph_on_context_created;
  rph->handler.on_process_message_received =
      cefspike_rph_on_process_message_received;
  atomic_store(&rph->ref_count, 1);
  return &rph->handler;
}
