// Zapp CEF host (macOS) — the cef_client_t and its life-span handler.
//
// Promoted from the proven GO spike (`spikes/cef-macos/cef_client.c` — see
// docs/superpowers/specs/2026-07-05-cef-webengine-production-slice-macos-
// design.md and spikes/cef-macos/FINDINGS.md, Tasks 0 + 4 + 5). Renamed
// cefspike_ -> zapp_cef_, "spike" dropped. A LIFE-SPAN + REAL-ROUTER-bridge
// client (no display/load handlers this task; simplified to a single
// browser — see zapp_cef_life_span_on_before_close).
//
// R1 rewired the spike's `greet` STUB to the REAL Nim router: the
// browser-process "zapp:invoke" handler no longer parses/answers itself — it
// hands the raw `{t,id,m,a}` envelope string straight to
// zapp_handle_message_from_window (the SAME entry webview.m's
// didReceiveScriptMessage calls for WKWebView), with the CEF window's slot as
// window_id. The router answers via sendInvokeResponse ->
// darwin_window_eval_js, whose CEF branch (window.m) delivers back through
// zapp_cef_eval_in_window (defined here) — so there is no reverse "zapp:result"
// process message anymore; the result is eval'd into the page directly, the
// same shape the spike's zjs_worker.c used to push to the page.
//
// Also hosts two small construction helpers used by the browser-creation
// call: a UTF-8 -> cef_string_t and a zeroed cef_browser_settings_t. They
// live here (rather than in the caller) so struct layout comes straight from
// the CEF headers.

#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zapp_cef_refcount.h"
#include "zapp_cef.h"

// window.m defines this (its zapp_webviews[] dispatch table); not visible
// here since window.m isn't included. Guarded so a future shared header
// doesn't collide — mirror the value EXACTLY (window.m:102).
#ifndef ZAPP_MAX_WINDOW_CALLBACKS
#define ZAPP_MAX_WINDOW_CALLBACKS 64
#endif

// The browser-process half of the `zapp` bridge (below) handles the
// "zapp:invoke" process message. These pull in the process-message /
// list-value / frame vtables it needs.
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_process_message_capi.h"
#include "include/capi/cef_values_capi.h"

// The REAL Nim router entry — the exact symbol webview.m's
// didReceiveScriptMessage calls (native/nim/app.nim, {.exportc,cdecl.}). Marshal
// identically: (app, raw envelope C string, window_id). |app| is discarded by
// the Nim handler; app_get_active() (native/nim/zapp.nim, a non-NULL sentinel)
// mirrors the WKWebView call site exactly.
extern void zapp_handle_message_from_window(void* app, char* msg,
                                            int32_t window_id);
extern void* app_get_active(void);

// Forward declaration.
typedef struct _zapp_cef_life_span_handler_t zapp_cef_life_span_handler_t;

typedef struct _zapp_cef_client_t {
  // MUST be first member — CEF base structure.
  cef_client_t client;
  atomic_int ref_count;
  int32_t slot;               // Zapp window slot this browser hosts (multi-window).
  zapp_cef_life_span_handler_t* life_span_handler;
} zapp_cef_client_t;

struct _zapp_cef_life_span_handler_t {
  // MUST be first member — CEF base structure.
  cef_life_span_handler_t handler;
  atomic_int ref_count;
  int32_t slot;                      // same slot as the owning client.
};

//
// Life-span handler.
//

IMPLEMENT_REFCOUNTING_SIMPLE(zapp_cef_life_span_handler_t,
                             zapp_cef_life_span_handler,
                             ref_count)

// One browser per Zapp window slot — the exact mirror of window.m's
// zapp_webviews[]. Registered in on_after_created, cleared in on_before_close /
// the window-destroy path. Read by the targeted eval (by slot) and the
// broadcast fan-out (all live entries). Main-thread only (CEF UI thread ==
// the external-pump main thread), so no lock — same as zapp_webviews[].
static cef_browser_t* zapp_cef_browsers[ZAPP_MAX_WINDOW_CALLBACKS] = {0};

static int zapp_cef_slot_ok(int32_t slot) {
  return slot >= 0 && slot < ZAPP_MAX_WINDOW_CALLBACKS;
}

cef_browser_t* zapp_cef_browser_for_slot(int32_t slot) {
  return zapp_cef_slot_ok(slot) ? zapp_cef_browsers[slot] : NULL;
}

// window.m is CEF-header-free (plain-C externs only, no cef_browser_t type), so
// it can't spell `zapp_cef_browser_for_slot(slot) != NULL`. This bool predicate
// gives windowShouldClose: the same liveness check without pulling the CEF
// headers into that translation unit.
int zapp_cef_has_browser_for_slot(int32_t slot) {
  return zapp_cef_browser_for_slot(slot) != NULL;
}

// TASK 2 (DEFER-pattern close): per-slot "this browser is being torn down as
// part of closing its host NSWindow" flag. The canonical CEF-macOS close is:
// windowShouldClose: sets this flag, defers the NSWindow close (returns NO),
// and gracefully closes the browser; on_before_close then triggers the REAL
// [window close], which RE-ENTERS windowShouldClose:. That second pass reads
// this flag and returns YES immediately — no re-dispatch of the close event, no
// second defer. Cleared once the window has actually closed (windowWillClose:),
// so a future window reusing the slot starts clean. Main-thread only, same
// discipline as zapp_cef_browsers[].
static int zapp_cef_closing[ZAPP_MAX_WINDOW_CALLBACKS] = {0};

int zapp_cef_is_closing(int32_t slot) {
  return zapp_cef_slot_ok(slot) ? zapp_cef_closing[slot] : 0;
}

void zapp_cef_set_closing(int32_t slot, int v) {
  if (zapp_cef_slot_ok(slot)) zapp_cef_closing[slot] = v ? 1 : 0;
}

//
// browser <-> Zapp window_id mapping + native->JS eval (see zapp_cef.h).
//
// Multi-window: each browser is keyed by the Zapp window slot it hosts
// (zapp_cef_browsers[] above). The slot is baked onto the client/life-span
// handler at create time (zapp_cef_client_create) and read by the bridge
// (below) to pass the correct window_id into zapp_handle_message_from_window,
// mirroring webview.m's darwin_window_id_for_webview.
//

// Run |js| in the CEF page NOW (caller guarantees the CEF UI/main thread).
// |browser|->get_main_frame is an OWNED ref (release once). execute_java_script
// takes a cef_string_t* it copies (NOT consumed) — it is CEF's cross-process
// analogue of WKWebView's evaluateJavaScript: and, called from the browser
// process, is routed to the render frame (same mechanism the spike's
// zjs_worker.c push used).
static void zapp_cef_eval_now(cef_browser_t* b, const char* js) {
  if (b == NULL || js == NULL) return;
  cef_frame_t* frame = b->get_main_frame(b);
  if (frame == NULL) return;
  cef_string_t code, empty;
  memset(&code, 0, sizeof(code));
  memset(&empty, 0, sizeof(empty));
  cef_string_utf8_to_utf16(js, strlen(js), &code);
  frame->execute_java_script(frame, &code, &empty, 0);
  cef_string_clear(&code);
  // get_main_frame returned an owned ref — release it.
  frame->base.release(&frame->base);
}

int zapp_cef_eval_in_window(int32_t slot, const char* js) {
  cef_browser_t* b = zapp_cef_browser_for_slot(slot);
  if (js == NULL || b == NULL) return 0;   // not handled → caller may fall through
  if (pthread_main_np() != 0) {
    // Already on the main (== CEF UI) thread — run inline to preserve
    // invoke-result ordering (matches darwin_window_eval_js's own inline path).
    zapp_cef_eval_now(b, js);
  } else {
    // A worker thread called sendInvokeResponse. execute_java_script must run
    // on the UI thread; copy |js| (the caller may free it right after this
    // returns) and hop. dispatch/blocks are C-available on Darwin (the spike's
    // zjs_worker.c used the same pattern). Re-look-up the browser by slot at
    // eval time (rather than capturing |b| here) — a window can close between
    // this worker-thread call and the main-thread hop.
    char* copy = strdup(js);
    if (copy == NULL) {
      return 1;  // handled (OOM — drop rather than touch the WKWebView path).
    }
    int32_t s = slot;
    dispatch_async(dispatch_get_main_queue(), ^{
      zapp_cef_eval_now(zapp_cef_browser_for_slot(s), copy);
      free(copy);
    });
  }
  return 1;  // handled by CEF — caller must NOT fall through to WKWebView.
}

// Fan |js| into every live CEF browser (all slots). Main-thread safe — see
// zapp_cef.h. Used by window.m's broadcast branch (zapp_registered_webviews_eval)
// since a CEF window has no zapp_webviews[] entry.
void zapp_cef_broadcast_eval(const char* js) {
  if (js == NULL) return;
  if (pthread_main_np() != 0) {
    for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
      cef_browser_t* b = zapp_cef_browsers[i];
      if (b) zapp_cef_eval_now(b, js);
    }
  } else {
    char* copy = strdup(js);
    if (copy == NULL) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      for (int i = 0; i < ZAPP_MAX_WINDOW_CALLBACKS; i++) {
        cef_browser_t* b = zapp_cef_browsers[i];
        if (b) zapp_cef_eval_now(b, copy);
      }
      free(copy);
    });
  }
}

// TASK 2 (DEFER-pattern close): kick off the graceful teardown of the CEF
// browser hosted at |slot|. Called from window.m's windowShouldClose: FIRST
// pass, AFTER the JS close guard allowed the close and AFTER the slot was
// flagged closing (zapp_cef_set_closing) — windowShouldClose: returns NO to
// DEFER the host NSWindow close until this teardown completes.
// darwin_window_destroy also calls this (idempotently) as a safety net; see its
// comment in window.m.
//
// get_host returns an OWNED ref (CEF convention, like get_main_frame above);
// release it after the call. close_browser(force_close=0) is asynchronous AND
// GRACEFUL — it schedules do_close then on_before_close on the CEF UI thread
// (same thread as this call under the external pump). force_close is 0 (not 1)
// on purpose: the defer pattern relies on do_close -> on_before_close running
// the normal way, and Zapp's own close guard already ran at windowShouldClose:
// before this was ever called, so there is nothing to force past.
// on_before_close is where the slot is deregistered, the browser's owned ref
// released, and the deferred [window close] finally triggered
// (zapp_cef_life_span_on_before_close below). We deliberately do NOT touch
// zapp_cef_browsers[slot] here — nulling it early would make on_before_close's
// slot-match guard treat the browser as already reassigned and skip its
// release, leaking the ref kept since on_after_created.
void zapp_cef_close_browser_for_slot(int32_t slot) {
  cef_browser_t* b = zapp_cef_browser_for_slot(slot);
  if (b == NULL) return;  // already closed / never registered — no-op.
  cef_browser_host_t* host = b->get_host(b);  // owned ref
  if (host) {
    fprintf(stderr, "[zapp-cef] close_browser requested (slot %d)\n", slot);
    host->close_browser(host, /*force_close=*/0);
    host->base.release(&host->base);
  }
}

void CEF_CALLBACK
zapp_cef_life_span_on_after_created(cef_life_span_handler_t* self,
                                    cef_browser_t* browser) {
  zapp_cef_life_span_handler_t* h = (zapp_cef_life_span_handler_t*)self;
  if (zapp_cef_slot_ok(h->slot)) {
    // Keep the owned ref instead of releasing it — see zapp_cef_browsers
    // above (a future native->page push mechanism needs it); released in
    // on_before_close.
    zapp_cef_browsers[h->slot] = browser;
    fprintf(stderr, "[zapp-cef] browser created (slot %d)\n", h->slot);
  } else {
    fprintf(stderr, "[zapp-cef] browser created with bad slot %d — dropping\n",
            h->slot);
    browser->base.release(&browser->base);
  }
}

int CEF_CALLBACK zapp_cef_life_span_do_close(cef_life_span_handler_t* self,
                                             cef_browser_t* browser) {
  zapp_cef_life_span_handler_t* h = (zapp_cef_life_span_handler_t*)self;
  // Diagnostic only (TASK 2 close-handshake evidence) — see FINDINGS.
  fprintf(stderr, "[zapp-cef] do_close (slot %d)\n", h->slot);
  // Release the callback parameter before returning.
  browser->base.release(&browser->base);
  // Return 0 to allow the browser close to proceed to on_before_close. Note
  // this is CEF's do_close/on_before_close teardown — NOT the host NSWindow.
  // do_close's "defer" return (1) exists for apps that let CEF OWN the native
  // window and want to run their own confirmation UI before CEF destroys it;
  // ours is the opposite: the browser is an Alloy child of a Zapp-owned
  // NSWindow (zapp_cef_create_browser_in_view), and the NSWindow-level defer
  // already happened one layer up — windowShouldClose: returned NO and kicked
  // off THIS teardown (see zapp_cef_close_browser_for_slot). Zapp's close guard
  // also already ran at windowShouldClose: before close_browser was called. So
  // allow (0): let on_before_close fire, which then triggers the real, deferred
  // [window close] via zapp_cef_finish_window_close.
  return 0;
}

void CEF_CALLBACK
zapp_cef_life_span_on_before_close(cef_life_span_handler_t* self,
                                   cef_browser_t* browser) {
  zapp_cef_life_span_handler_t* h = (zapp_cef_life_span_handler_t*)self;
  // Release the EXTRA ref kept alive since on_after_created — a DIFFERENT
  // owned ref than the |browser| parameter below (CEF hands a fresh owned
  // ref to each callback invocation, per the same convention).
  if (zapp_cef_slot_ok(h->slot) && zapp_cef_browsers[h->slot] == browser) {
    zapp_cef_browsers[h->slot] = NULL;
    browser->base.release(&browser->base);
  }
  browser->base.release(&browser->base);
  // TASK 2: no longer stops the NSApp loop here. Last-window quit is Zapp's
  // own terminateAfterLastWindowClosed path (the NSWindow itself closing —
  // see window.m / platform.m), which fires independently of this
  // browser-level callback; see close-handshake FINDINGS for the read on why
  // that's still correct with the quit call removed.
  fprintf(stderr, "[zapp-cef] browser closed (slot %d)\n", h->slot);
  // DEFER-pattern completion. windowShouldClose: returned NO to keep the host
  // NSWindow open while THIS teardown ran; now that the browser is fully gone
  // (deregistered + ref released above), finish the deferred close by actually
  // closing the NSWindow. zapp_cef_finish_window_close (window.m) finds the
  // NSWindow for this slot and [window close]s it; because the slot's closing
  // flag is still set, the resulting re-entrant windowShouldClose: returns YES
  // and the window closes cleanly. Runs on the CEF UI thread == the main thread
  // under the external pump, so this main-thread NSWindow call is safe.
  extern void zapp_cef_finish_window_close(int32_t slot);
  zapp_cef_finish_window_close(h->slot);
}

static zapp_cef_life_span_handler_t* zapp_cef_life_span_handler_create(int32_t slot) {
  zapp_cef_life_span_handler_t* h = (zapp_cef_life_span_handler_t*)calloc(
      1, sizeof(zapp_cef_life_span_handler_t));
  CHECK(h);

  INIT_CEF_BASE_REFCOUNTED(&h->handler.base, cef_life_span_handler_t,
                           zapp_cef_life_span_handler);
  h->handler.on_after_created = zapp_cef_life_span_on_after_created;
  h->handler.do_close = zapp_cef_life_span_do_close;
  h->handler.on_before_close = zapp_cef_life_span_on_before_close;
  h->slot = slot;

  atomic_store(&h->ref_count, 1);
  return h;
}

//
// The `zapp` bridge, BROWSER-process half — REAL router.
//
// The render process (zapp_cef_bridge.c) ships a "zapp:invoke" process message
// whose single arg [0] is the RAW `{t,id,m,a}` bridge envelope string (exactly
// what WKWebView posts via webkit.messageHandlers.zapp.postMessage). We do NOT
// parse or answer it here — we hand it straight to the SAME Nim router entry
// webview.m's didReceiveScriptMessage uses:
//
//     zapp_handle_message_from_window(app_get_active(), envelope, window_slot)
//
// The router parses + dispatches + answers via sendInvokeResponse ->
// darwin_window_eval_js, whose CEF branch (window.m) delivers the result back
// into the page through zapp_cef_eval_in_window (above). So there is NO reverse
// "zapp:result" process message — the result is eval'd into the page directly.
// ZAPP_MSG_INVOKE is the shared literal, defined once in zapp_cef.h.
//

int CEF_CALLBACK zapp_cef_client_on_process_message_received(
    cef_client_t* self, cef_browser_t* browser, cef_frame_t* frame,
    cef_process_id_t source_process, cef_process_message_t* message) {
  zapp_cef_client_t* client = (zapp_cef_client_t*)self;
  (void)frame;
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
    // arg[0] is the raw `{t,id,m,a}` envelope string — get_string returns a
    // userfree cef_string_t; convert to UTF-8 for the router entry.
    cef_string_userfree_t s_env = args->get_string(args, 0);
    cef_string_utf8_t env_utf8;
    memset(&env_utf8, 0, sizeof(env_utf8));
    if (s_env != NULL) {
      cef_string_utf16_to_utf8(s_env->str, s_env->length, &env_utf8);
      cef_string_userfree_free(s_env);
    }
    args->base.release(&args->base);

    if (env_utf8.str != NULL) {
      // Diagnostic (GATE-4 evidence): shows the raw envelope reaching the real
      // router. High-frequency t:4 setDragRegion messages are elided to keep
      // the log readable.
      if (strstr(env_utf8.str, "\"setDragRegion\"") == NULL) {
        fprintf(stderr, "[zapp-cef][browser] -> router (win=%d): %s\n",
                client->slot, env_utf8.str);
      }
      // Same marshalling as webview.m:396 — (app, raw envelope, window_id).
      // window_id = the CEF window's slot, baked onto this client at create
      // time (zapp_cef_client_create) — multi-window: each browser's client
      // carries its OWN slot, so a message from window 2 tags window 2. Runs
      // on the CEF UI thread == the main thread under the external pump, i.e.
      // the SAME thread the WKWebView handler and the Nim runtime use — safe
      // to call the ORC-GC'd router.
      void* app_ptr = app_get_active();
      if (app_ptr != NULL) {
        zapp_handle_message_from_window(app_ptr, env_utf8.str, client->slot);
      }
    }
    cef_string_utf8_clear(&env_utf8);
    handled = 1;
  }

  cef_string_utf8_clear(&name_utf8);

  // Release the owned callback params (CEF C-API refptr_diff — same convention
  // as the life-span handler's browser param). We retain nothing beyond this
  // call; the router delivers its result via zapp_cef_eval_in_window, which
  // looks the browser back up by slot in zapp_cef_browsers[], not this |frame|.
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

cef_client_t* zapp_cef_client_create(int32_t slot) {
  zapp_cef_client_t* client =
      (zapp_cef_client_t*)calloc(1, sizeof(zapp_cef_client_t));
  CHECK(client);

  INIT_CEF_BASE_REFCOUNTED(&client->client.base, cef_client_t, zapp_cef_client);
  client->client.get_life_span_handler = zapp_cef_client_get_life_span_handler;
  // Browser-process half of the bridge (handles "zapp:invoke").
  client->client.on_process_message_received =
      zapp_cef_client_on_process_message_received;
  client->slot = slot;

  client->life_span_handler = zapp_cef_life_span_handler_create(slot);
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
