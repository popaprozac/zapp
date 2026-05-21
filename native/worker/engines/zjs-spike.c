// zjs + libuv integration spike.
//
// Goal: prove the "run a zjs context on a libuv loop" pattern that
// engines/zjs.c will eventually use for headless workers. Single
// thread, no Zapp host bridge — just enough to verify
//   (a) zjs's host-function ABI works against a console.log shim,
//   (b) microtasks drain at the right times (the bug we chased
//       for two days under Hermes),
//   (c) setInterval / setTimeout fire on a uv-driven schedule,
//   (d) shutdown is clean.
//
// Build:
//   clang -O1 -Wall -Wextra -std=c11 \
//     -I vendor/zjs/include -I /opt/homebrew/include \
//     native/worker/engines/zjs-spike.c \
//     vendor/zjs/build/libzjs.a /opt/homebrew/lib/libuv.dylib \
//     -framework Foundation -fobjc-arc \
//     -o build/zjs-spike
//   ./build/zjs-spike
//
// Expected output: "hello from zjs" once, then "tick N" four times
// over ~800ms, then "shutdown". Promise.resolve().then(...) lands
// before the first tick (microtask ordering).

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#include "zjs.h"

// ---------------------------------------------------------------------------
// Loop wiring.
//
// zjs runs its own timer queue. libuv runs its own event loop. We bridge
// them with two uv handles:
//
//   - uv_check_t  : runs at the END of every uv loop tick. Pumps any
//                   zjs timers whose due time has passed, then asks zjs
//                   when the next one is due.
//   - uv_timer_t  : re-armed after every drain to fire when zjs's next
//                   timer is due, so libuv knows to wake the loop at
//                   that time even if nothing else is scheduled.
//
// This is the same shape engines/zjs.c will use when it lives inside a
// real worker thread — replace the uv_default_loop() with a per-worker
// uv_loop_init() and the harness becomes a worker engine.
// ---------------------------------------------------------------------------

typedef struct {
    ZjsContext* ctx;
    uv_check_t  check;
    uv_timer_t  zjs_wake;     // re-armed to fire when zjs's next timer is due
    uv_timer_t  shutdown;     // one-shot kill switch after the demo runs
    int         shutting_down;
} LoopBridge;

static void on_zjs_wake(uv_timer_t* h) { (void) h; /* drain happens in on_check */ }

static void on_check(uv_check_t* h) {
    LoopBridge* lb = (LoopBridge*) h->data;
    if (lb->shutting_down) return;

    // Fire any zjs timers that are due. zjs drains microtasks after each
    // callback per spec — no manual drain needed.
    zjs_run_pending_timers(lb->ctx);

    // If a timer's callback threw uncaught, surface and bail. Real worker
    // code routes this through the supervisor; the spike just exits.
    if (zjs_had_error(lb->ctx)) {
        ZjsValue err = zjs_get_error(lb->ctx);
        uint32_t len = 0;
        const char* msg = zjs_string_bytes(err, &len);
        fprintf(stderr, "[spike] timer threw: %.*s\n",
            (int) len, msg ? msg : "<non-string throw>");
    }

    // Re-arm the wake-up timer for the NEXT zjs deadline. Negative means
    // no pending timer — don't re-arm, the loop will idle until something
    // else wakes it (in the spike, the shutdown timer eventually does).
    int64_t next_ms = zjs_next_timer_ms(lb->ctx);
    if (next_ms < 0) return;
    if (next_ms == 0) next_ms = 1;  // uv_timer_start treats 0 specially
    uv_timer_start(&lb->zjs_wake, on_zjs_wake, (uint64_t) next_ms, 0);
}

static void on_shutdown(uv_timer_t* h) {
    LoopBridge* lb = (LoopBridge*) h->data;
    lb->shutting_down = 1;
    fprintf(stderr, "[spike] shutdown\n");
    uv_check_stop(&lb->check);
    uv_timer_stop(&lb->zjs_wake);
    uv_close((uv_handle_t*) &lb->check,    NULL);
    uv_close((uv_handle_t*) &lb->zjs_wake, NULL);
    uv_close((uv_handle_t*) &lb->shutdown, NULL);
}

// ---------------------------------------------------------------------------
// Host functions — minimal `console.log`. Real worker bridge will add
// invokeService, postToWebview, dispatchEventToAll, etc.
// ---------------------------------------------------------------------------

static ZjsValue host_console_log(ZjsContext* ctx, ZjsValue* argv, uint32_t argc) {
    fputs("[js-console]", stdout);
    for (uint32_t i = 0; i < argc; i++) {
        fputc(' ', stdout);
        if (zjs_is_string(argv[i])) {
            uint32_t len = 0;
            const char* s = zjs_string_bytes(argv[i], &len);
            fwrite(s, 1, len, stdout);
        } else if (zjs_is_int32(argv[i])) {
            printf("%d", zjs_as_int32(argv[i]));
        } else if (zjs_is_double(argv[i])) {
            printf("%g", zjs_as_double(argv[i]));
        } else if (zjs_is_bool(argv[i])) {
            fputs(zjs_as_bool(argv[i]) ? "true" : "false", stdout);
        } else if (zjs_is_null(argv[i])) {
            fputs("null", stdout);
        } else if (zjs_is_undefined(argv[i])) {
            fputs("undefined", stdout);
        } else {
            // Coerce other cell kinds via zjs's String() — slow path,
            // fine for diagnostics.
            zjs_set_global(ctx, "__spike_tmp", argv[i]);
            ZjsValue s = zjs_eval(ctx, "String(__spike_tmp)");
            uint32_t len = 0;
            const char* bytes = zjs_string_bytes(s, &len);
            if (bytes) fwrite(bytes, 1, len, stdout);
            else fputs("<unprintable>", stdout);
        }
    }
    fputc('\n', stdout);
    return zjs_undefined();
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------

int main(void) {
    fprintf(stderr, "[spike] zjs version: %s\n", zjs_version());

    ZjsContext* ctx = zjs_new_context();
    if (!ctx) { fprintf(stderr, "[spike] zjs_new_context failed\n"); return 1; }

    // globalThis.console = { log: host_console_log }
    ZjsValue console = zjs_new_object(ctx);
    ZjsValue log_fn  = zjs_register_host_function(ctx, "__spike_console_log",
                                                  host_console_log);
    zjs_set_property(ctx, console, "log", log_fn);
    zjs_set_global(ctx, "console", console);

    // Now wire the loop.
    LoopBridge lb = {0};
    lb.ctx = ctx;
    uv_loop_t* loop = uv_default_loop();
    uv_check_init(loop, &lb.check);   lb.check.data    = &lb;
    uv_timer_init(loop, &lb.zjs_wake); lb.zjs_wake.data = &lb;
    uv_timer_init(loop, &lb.shutdown); lb.shutdown.data = &lb;
    uv_check_start(&lb.check, on_check);

    // Kill switch after 900ms — long enough to see ~4 ticks.
    uv_timer_start(&lb.shutdown, on_shutdown, 900, 0);

    // The demo script: a microtask, a setInterval, a Promise chain.
    // This is the same shape a real worker bundle starts with — bare-fetch
    // and friends would slot in after setInterval here, once the host
    // bridge has the surface for them.
    const char* src =
        "console.log('hello from zjs');"
        "Promise.resolve('microtask drained').then(m => console.log(m));"
        "var n = 0;"
        "setInterval(() => { n++; console.log('tick', n); }, 200);";

    zjs_eval(ctx, src);
    if (zjs_had_error(ctx)) {
        ZjsValue err = zjs_get_error(ctx);
        uint32_t len = 0;
        const char* msg = zjs_string_bytes(err, &len);
        fprintf(stderr, "[spike] script threw: %.*s\n",
            (int) len, msg ? msg : "<non-string throw>");
        zjs_free_context(ctx);
        return 1;
    }

    // After the script, ask zjs when the first timer is due and arm.
    int64_t next_ms = zjs_next_timer_ms(ctx);
    if (next_ms >= 0) {
        if (next_ms == 0) next_ms = 1;
        uv_timer_start(&lb.zjs_wake, on_zjs_wake, (uint64_t) next_ms, 0);
    }

    int rc = uv_run(loop, UV_RUN_DEFAULT);
    fprintf(stderr, "[spike] uv_run returned %d\n", rc);

    zjs_free_context(ctx);
    return 0;
}
