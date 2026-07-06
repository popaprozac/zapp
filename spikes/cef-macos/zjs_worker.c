// CEF spike (Task 5) — a REAL libzjs worker running alongside CEF.
//
// Formalizes Task 1's stand-in (a pthread + CFRunLoop timer standing in for
// "a ZJS worker" — see FINDINGS.md Task 1) into the real thing: this file
// embeds vendor/zjs's actual C ABI (include/zjs.h) directly, using the
// SMALLEST surface that runs real JavaScript on its own thread:
//
//   1. zjs_new_minimal_context()  — ES-core-only context (no Ring-1/2 web
//                                   globals, no node: modules — this demo
//                                   needs neither).
//   2. zjs_register_host_function — one host fn (__zapp_native_post) a JS
//                                   `setInterval` tick calls once a second.
//   3. zjs_eval(... "setInterval(...)" ...) — a REAL setInterval tick running
//                                   on the REAL interpreter (not a
//                                   CFRunLoopTimer standing in for one).
//   4. The documented CLI-style loop (zjs_has_pending_work /
//      zjs_next_timer_ms / zjs_run_pending_timers — see vendor/zjs/include/
//      zjs.h) pumps the context for the process lifetime. setInterval
//      re-arms its own timer on every fire, so "pending work" never reaches
//      zero — this loop runs forever, same shape as T1's CFRunLoopRun().
//
// This is deliberately NOT the full native/worker/engines/zjs.c embedding
// (worker registry, the kqueue+CFRunLoop hybrid that drains NSURLSession for
// fetch/WebSocket, capability modules, headless-worker codegen, script-URL
// resolution). None of that machinery is needed to prove the point this task
// exists to prove: a ZJS worker runs on its own native thread, entirely
// independent of whichever render engine (WKWebView or CEF) hosts the page —
// see FINDINGS.md Task 5 for the argument in full.
//
// Worker -> page: the host function hops to the CEF UI (main) thread via
// dispatch_async and pushes JS into the browser's main frame via
// frame->execute_java_script — the SAME mechanism Task 4's bridge.c uses to
// resolve a JS promise from native (see bridge.c's zapp:result handling),
// just triggered by a timer tick instead of a process-message reply.

#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <zjs.h>  // vendor/zjs/include/zjs.h — the embed ABI (see main.nim's
                  // zjsRoot passC / passL for the -I and static-archive link).

#include "cef_spike.h"
#include "include/capi/cef_frame_capi.h"

// Mirrors bridge.c's cef_str_set_utf8 helper (not exported from there — small
// enough to duplicate rather than plumb a shared header for one line).
static void cef_str_set_utf8(cef_string_t* out, const char* utf8) {
  cef_string_utf8_to_utf16(utf8, strlen(utf8), out);
}

// ---------------------------------------------------------------------------
// __zapp_native_post(jsonValue: string) — called from the JS tick (runs on
// the worker thread). jsonValue is already JSON.stringify'd on the JS side;
// splice it verbatim into `window.__zappWorker(<jsonValue>)` on the main
// thread — the same "already-a-JS-value" convention bridge.c's zapp:result
// reply uses for window.__zappResolve.
// ---------------------------------------------------------------------------

// Console evidence, same style as T1's stand-in "[worker] tick N" line —
// fires from the REAL zjs engine's host-function call, independent of
// whether the page has loaded / window.__zappWorker exists yet (that hop
// happens after this log line, on the main thread — see below).
static long g_zjs_tick_count = 0;

static ZjsValue host_native_post(ZjsContext* ctx, ZjsValue* argv, uint32_t argc) {
  (void) ctx;
  if (argc < 1 || !zjs_is_string(argv[0])) return zjs_undefined();

  fprintf(stderr, "[worker] real zjs tick %ld -> posting to page\n",
          ++g_zjs_tick_count);

  // Copy the bytes out immediately: per zjs.h's lifetime contract the
  // pointer zjs_string_bytes hands back is only valid while the cell stays
  // reachable, and we're about to return (dropping the JS-side reference)
  // and hop to another thread — take our own copy now.
  uint32_t len = 0;
  const char* bytes = zjs_string_bytes(argv[0], &len);
  if (!bytes) return zjs_undefined();
  char* value_json = (char*) malloc((size_t) len + 1);
  if (!value_json) return zjs_undefined();
  memcpy(value_json, bytes, len);
  value_json[len] = '\0';

  // Heap-allocate the JS call string — avoid the stack-buffer-truncation bug
  // family (the same lesson bridge.c's zapp:result path already applies).
  size_t need = strlen("if (window.__zappWorker) window.__zappWorker();") +
                strlen(value_json) + 1;
  char* js = (char*) malloc(need);
  if (!js) {
    free(value_json);
    return zjs_undefined();
  }
  snprintf(js, need, "if (window.__zappWorker) window.__zappWorker(%s);",
           value_json);
  free(value_json);

  // Hop to the CEF UI (main) thread — CEF browser-process APIs (get_main_frame
  // / execute_java_script) must be called there, same as Task 1's pump and
  // Task 4's render-side calls each run on their own owning thread.
  dispatch_async(dispatch_get_main_queue(), ^{
    cef_browser_t* browser = cefspike_get_active_browser();
    if (browser != NULL) {
      cef_frame_t* frame = browser->get_main_frame(browser);
      if (frame != NULL) {
        cef_string_t code, empty;
        memset(&code, 0, sizeof(code));
        memset(&empty, 0, sizeof(empty));
        cef_str_set_utf8(&code, js);
        frame->execute_java_script(frame, &code, &empty, 0);
        cef_string_clear(&code);
        frame->base.release(&frame->base);
      }
    }
    free(js);
  });

  return zjs_undefined();
}

// ---------------------------------------------------------------------------
// Worker thread — real zjs context, real JS tick, zjs's own event loop.
// ---------------------------------------------------------------------------

static void* cefspike_zjs_worker_thread(void* arg) {
  (void) arg;
  fprintf(stderr, "[worker] real zjs worker starting (libzjs %s)\n",
          zjs_version());

  ZjsContext* ctx = zjs_new_minimal_context();
  if (!ctx) {
    fprintf(stderr, "[worker] zjs_new_minimal_context failed\n");
    return NULL;
  }

  zjs_register_host_function(ctx, "__zapp_native_post", host_native_post);

  // A real setInterval tick — the "does a ZJS worker coexist with CEF" gate
  // T1 opened, now proven against the actual engine instead of a
  // CFRunLoopTimer stand-in. setInterval re-arms itself on every fire (per
  // zjs.h's event-loop doc comment), so "pending work" stays non-zero
  // indefinitely — see the pump loop below.
  zjs_eval(ctx,
    "globalThis.__zappTick = 0;"
    "setInterval(function () {"
    "  __zappTick++;"
    "  __zapp_native_post(JSON.stringify({"
    "    tick: __zappTick,"
    "    at: Date.now(),"
    "    source: 'real zjs worker (libzjs)'"
    "  }));"
    "}, 1000);");
  if (zjs_had_error(ctx)) {
    ZjsValue err = zjs_get_error(ctx);
    uint32_t elen = 0;
    const char* ebytes = zjs_is_string(err) ? zjs_string_bytes(err, &elen) : NULL;
    fprintf(stderr, "[worker] zjs bootstrap eval threw: %.*s\n", (int) elen,
            ebytes ? ebytes : (const char*) "<unreadable>");
  } else {
    fprintf(stderr, "[worker] real zjs loop started (setInterval armed)\n");
  }

  // The documented zjs "CLI-style loop" (vendor/zjs/include/zjs.h): poll
  // pending work, sleep until the next timer's due time, fire it, repeat.
  while (zjs_has_pending_work(ctx)) {
    int64_t wait_ms = zjs_next_timer_ms(ctx);
    if (wait_ms > 0) {
      struct timespec ts;
      ts.tv_sec = wait_ms / 1000;
      ts.tv_nsec = (wait_ms % 1000) * 1000000;
      nanosleep(&ts, NULL);
    }
    zjs_run_pending_timers(ctx);
    if (zjs_had_error(ctx)) {
      fprintf(stderr, "[worker] zjs timer callback threw (continuing)\n");
    }
  }

  fprintf(stderr, "[worker] real zjs loop exited (no more pending work)\n");
  zjs_free_context(ctx);
  return NULL;
}

void cefspike_start_zjs_worker(void) {
  pthread_t thread;
  int rc = pthread_create(&thread, NULL, cefspike_zjs_worker_thread, NULL);
  if (rc != 0) {
    fprintf(stderr, "[worker] pthread_create (zjs) failed: %d\n", rc);
    return;
  }
  pthread_detach(thread);
}
