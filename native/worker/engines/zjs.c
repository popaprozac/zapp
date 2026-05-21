// zjs worker engine — first-party JS engine for Zapp workers.
//
// Each worker runs on its own pthread with its own uv_loop_t and
// ZjsContext. The thread structure mirrors txiki.c (slot table + mutex,
// per-worker async/inbox plumbing, embedded-asset → filesystem → iOS
// dev-URL script load chain). The novel piece is how zjs drives its
// timer queue from libuv: zjs has no embedded loop of its own, so we
// pump it from a uv_check_t and re-arm a uv_timer_t to zjs_next_timer_ms
// to wake libuv at the right time.
//
// This first cut wires:
//   - context lifecycle (create / teardown)
//   - script loading + eval
//   - console.log host function
//   - setInterval / setTimeout (provided by zjs itself, surfaced via
//     the timer queue we pump from uv)
//
// The full host bridge (invokeService, dispatchEventToAll, send/receive,
// syncWait/syncNotify, workerCrash) lands in subsequent cuts. The
// surface is small on purpose — this file should compile and run
// hello-world's ticker.ts the moment Z4 wires the CLI + router.

#include "zjs.h"
#include <zjs.h>  // include/zjs.h from vendor/zjs — embed ABI

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#include <compression.h>
#endif
#include <uv.h>

// Mirror txiki.c's embedded-asset struct (the macro that defines it is
// local to zapp_assets's translation unit).
typedef struct {
    const char* path;
    uint8_t*    data;
    int         len;
    int         uncompressed_len;
    int         is_brotli;
} ZappEmbeddedAsset;

// ---------------------------------------------------------------------------
// Worker slot table — same shape as txiki, sized identically.
// ---------------------------------------------------------------------------

#define ZJS_MAX_WORKERS 64

typedef struct {
    char         worker_id[64];
    char         owner_id[64];
    char         script_url[256];
    int          active;

    pthread_t    thread;
    uv_loop_t    loop;
    ZjsContext*  ctx;

    // Loop integration: drained on every uv_check, re-armed to next zjs
    // timer deadline so libuv knows when to wake.
    uv_check_t   check;
    uv_timer_t   zjs_wake;
    uv_async_t   shutdown_async;     // signaled from terminate to wake the loop
    int          loop_initialized;

    // Shutdown latch — set by zjs_worker_terminate from any thread,
    // observed by the worker thread when shutdown_async fires.
    int          shutting_down;
} ZjsWorkerSlot;

static ZjsWorkerSlot zjs_workers[ZJS_MAX_WORKERS] = {{0}};
static pthread_mutex_t zjs_workers_mutex = PTHREAD_MUTEX_INITIALIZER;

static ZjsWorkerSlot* zjs_find_slot(const char* worker_id) {
    for (int i = 0; i < ZJS_MAX_WORKERS; i++) {
        if (zjs_workers[i].active && strcmp(zjs_workers[i].worker_id, worker_id) == 0) {
            return &zjs_workers[i];
        }
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// Forward decls — Zapp externs.
// ---------------------------------------------------------------------------

extern int  zapp_build_use_embedded_assets(void);
extern ZappEmbeddedAsset zapp_embedded_assets[];
extern int  zapp_embedded_assets_count;
#if defined(__APPLE__) && TARGET_OS_IPHONE
extern const char* zapp_build_initial_url(void);
extern char* zapp_ios_fetch_url_sync(const char* url, int* out_len);
#endif

// ---------------------------------------------------------------------------
// Bootstrap — host functions installed on every zjs worker context.
// First cut surfaces console.log only; Z2/Z3 layer invokeService and
// dispatchEventToAll on top.
// ---------------------------------------------------------------------------

static ZjsValue host_console_log(ZjsContext* ctx, ZjsValue* argv, uint32_t argc) {
    fputs("[js-console]", stderr);
    for (uint32_t i = 0; i < argc; i++) {
        fputc(' ', stderr);
        if (zjs_is_string(argv[i])) {
            uint32_t len = 0;
            const char* s = zjs_string_bytes(argv[i], &len);
            fwrite(s, 1, len, stderr);
        } else if (zjs_is_int32(argv[i])) {
            fprintf(stderr, "%d", zjs_as_int32(argv[i]));
        } else if (zjs_is_double(argv[i])) {
            fprintf(stderr, "%g", zjs_as_double(argv[i]));
        } else if (zjs_is_bool(argv[i])) {
            fputs(zjs_as_bool(argv[i]) ? "true" : "false", stderr);
        } else if (zjs_is_null(argv[i])) {
            fputs("null", stderr);
        } else if (zjs_is_undefined(argv[i])) {
            fputs("undefined", stderr);
        } else {
            // Anything else (object, array, function) — let zjs's String()
            // coerce it. Slow path, fine for diagnostics.
            zjs_set_global(ctx, "__zapp_log_tmp", argv[i]);
            ZjsValue s = zjs_eval(ctx, "String(__zapp_log_tmp)");
            uint32_t len = 0;
            const char* bytes = zjs_string_bytes(s, &len);
            if (bytes) fwrite(bytes, 1, len, stderr);
            else fputs("<unprintable>", stderr);
        }
    }
    fputc('\n', stderr);
    return zjs_undefined();
}

static void zjs_setup_bridge(ZjsContext* ctx, const char* worker_id) {
    (void) worker_id;  // Z2 stashes this per-context for invokeService routing.

    // globalThis.console = { log, error, warn, info } — all hit the same
    // stderr printer for now. Workers typically don't have multiple log
    // levels of their own; the router's worker stderr capture is enough.
    ZjsValue console = zjs_new_object(ctx);
    ZjsValue log_fn  = zjs_register_host_function(ctx, "__zapp_console_log",
                                                  host_console_log);
    zjs_set_property(ctx, console, "log",   log_fn);
    zjs_set_property(ctx, console, "error", log_fn);
    zjs_set_property(ctx, console, "warn",  log_fn);
    zjs_set_property(ctx, console, "info",  log_fn);
    zjs_set_global(ctx, "console", console);
}

// ---------------------------------------------------------------------------
// uv ↔ zjs timer bridge.
// ---------------------------------------------------------------------------

static void on_zjs_wake(uv_timer_t* h) { (void) h; /* work happens in on_check */ }

// Fires when zjs_worker_terminate (or terminate_owner) flips
// shutting_down. We stop the loop here — the on_check tick also bails,
// and the teardown label after uv_run handles the close calls. Splitting
// the signaling (uv_async_send is thread-safe) from the actual teardown
// (only the worker thread touches its handles) keeps the locking story
// simple — no mutex around the loop itself.
static void on_shutdown_async(uv_async_t* h) {
    ZjsWorkerSlot* slot = (ZjsWorkerSlot*) h->data;
    uv_stop(&slot->loop);
}

static void on_check(uv_check_t* h) {
    ZjsWorkerSlot* slot = (ZjsWorkerSlot*) h->data;
    if (slot->shutting_down) return;

    zjs_run_pending_timers(slot->ctx);

    if (zjs_had_error(slot->ctx)) {
        ZjsValue err = zjs_get_error(slot->ctx);
        uint32_t len = 0;
        const char* msg = zjs_string_bytes(err, &len);
        fprintf(stderr, "[zapp] zjs worker '%s' timer threw: %.*s\n",
            slot->worker_id, (int) len, msg ? msg : "<non-string throw>");
        // Surface but keep running — matches txiki / bare behaviour, where
        // a single throw in a setInterval cb doesn't tear the worker down.
    }

    int64_t next_ms = zjs_next_timer_ms(slot->ctx);
    if (next_ms < 0) return;             // no timers pending — idle
    if (next_ms == 0) next_ms = 1;       // uv_timer_start treats 0 specially
    uv_timer_start(&slot->zjs_wake, on_zjs_wake, (uint64_t) next_ms, 0);
}

// ---------------------------------------------------------------------------
// Script loading — mirrors txiki.c's embedded → filesystem → iOS-dev-URL
// fallback chain so workers run uniformly across dev and prod regardless
// of engine choice.
// ---------------------------------------------------------------------------

static char* zjs_load_script(const char* script_url, long* out_len) {
    char  script_path[512];
    char  cwd[256];
    const char* basename = strrchr(script_url, '/');
    basename = basename ? basename + 1 : script_url;
    if (getcwd(cwd, sizeof(cwd))) {
        snprintf(script_path, sizeof(script_path), "%s/.zapp/workers/%s", cwd, basename);
    } else {
        strncpy(script_path, script_url, sizeof(script_path) - 1);
        script_path[sizeof(script_path) - 1] = '\0';
    }

    char* code = NULL;
    long  code_len = 0;

    if (zapp_build_use_embedded_assets()) {
        for (int ai = 0; ai < zapp_embedded_assets_count; ai++) {
            if (strcmp(zapp_embedded_assets[ai].path, script_url) == 0) {
#ifdef __APPLE__
                if (zapp_embedded_assets[ai].is_brotli && zapp_embedded_assets[ai].uncompressed_len > 0) {
                    code = (char*) malloc(zapp_embedded_assets[ai].uncompressed_len + 1);
                    code_len = compression_decode_buffer(
                        (uint8_t*) code, zapp_embedded_assets[ai].uncompressed_len,
                        zapp_embedded_assets[ai].data, zapp_embedded_assets[ai].len,
                        NULL, COMPRESSION_BROTLI);
                    code[code_len] = '\0';
                } else
#endif
                {
                    code_len = zapp_embedded_assets[ai].len;
                    code = (char*) malloc(code_len + 1);
                    memcpy(code, zapp_embedded_assets[ai].data, code_len);
                    code[code_len] = '\0';
                }
                fprintf(stderr, "[zapp] zjs worker script loaded from embedded: %s\n", script_url);
                break;
            }
        }
    }

    if (!code) {
        FILE* f = fopen(script_path, "r");
        if (f) {
            fseek(f, 0, SEEK_END);
            code_len = ftell(f);
            fseek(f, 0, SEEK_SET);
            code = (char*) malloc(code_len + 1);
            if (code) {
                if (fread(code, 1, code_len, f) != (size_t) code_len) {
                    free(code); code = NULL; code_len = 0;
                } else {
                    code[code_len] = '\0';
                    fprintf(stderr, "[zapp] zjs worker script loaded: %s\n", script_path);
                }
            }
            fclose(f);
        }
    }

#if defined(__APPLE__) && TARGET_OS_IPHONE
    if (!code) {
        const char* dev_url = zapp_build_initial_url();
        if (dev_url && dev_url[0] != '\0') {
            char full_url[1024];
            snprintf(full_url, sizeof(full_url), "%s%s", dev_url, script_url);
            int fetched_len = 0;
            char* fetched = zapp_ios_fetch_url_sync(full_url, &fetched_len);
            if (fetched) {
                code = fetched;
                code_len = fetched_len;
                fprintf(stderr, "[zapp] zjs worker loaded from dev server: %s\n", full_url);
            }
        }
    }
#endif

    if (out_len) *out_len = code_len;
    return code;
}

// ---------------------------------------------------------------------------
// Worker thread — owns its uv_loop + ZjsContext for the lifetime of the
// worker. The slot.active flag is the authoritative "this worker is up"
// state; the supervisor / dispatch path uses it to gate routing.
// ---------------------------------------------------------------------------

static void* zjs_worker_thread(void* arg) {
    ZjsWorkerSlot* slot = (ZjsWorkerSlot*) arg;

    if (uv_loop_init(&slot->loop) != 0) {
        fprintf(stderr, "[zapp] zjs worker '%s' uv_loop_init failed\n", slot->worker_id);
        slot->active = 0;
        return NULL;
    }
    slot->loop_initialized = 1;

    slot->ctx = zjs_new_context();
    if (!slot->ctx) {
        fprintf(stderr, "[zapp] zjs worker '%s' zjs_new_context failed\n", slot->worker_id);
        uv_loop_close(&slot->loop);
        slot->active = 0;
        return NULL;
    }

    // Bridge first, then user script. The user script may call host
    // functions during top-level execution (Services.invokeSync from
    // module scope is a real pattern), so console.log + invokeService
    // must be reachable before the eval runs.
    zjs_setup_bridge(slot->ctx, slot->worker_id);

    // Hook the loop wiring BEFORE eval so any setInterval / setTimeout
    // the script registers immediately gets pumped from the first tick.
    uv_check_init(&slot->loop, &slot->check);
    slot->check.data = slot;
    uv_check_start(&slot->check, on_check);

    uv_timer_init(&slot->loop, &slot->zjs_wake);
    slot->zjs_wake.data = slot;

    uv_async_init(&slot->loop, &slot->shutdown_async, on_shutdown_async);
    slot->shutdown_async.data = slot;

    long  code_len = 0;
    char* code = zjs_load_script(slot->script_url, &code_len);
    if (!code) {
        fprintf(stderr, "[zapp] zjs worker script not found: %s\n", slot->script_url);
        goto teardown;
    }

    // Vite emits .mjs but we eval as a plain script — the bundle is
    // self-contained (Vite tree-shakes all live imports inline). When
    // we want true ESM, switch to zjs_eval_module against the resolved
    // filesystem path; the embedded-asset path makes that a follow-up.
    zjs_eval(slot->ctx, code);
    if (zjs_had_error(slot->ctx)) {
        ZjsValue err = zjs_get_error(slot->ctx);
        uint32_t len = 0;
        const char* msg = zjs_string_bytes(err, &len);
        fprintf(stderr, "[zapp] zjs worker '%s' script threw: %.*s\n",
            slot->worker_id, (int) len, msg ? msg : "<non-string throw>");
    }
    free(code);

    // Arm the wake timer for the first scheduled callback (if any). uv
    // would otherwise idle until the next setInterval period; this
    // guarantees the loop wakes for whatever the script just registered.
    int64_t next_ms = zjs_next_timer_ms(slot->ctx);
    if (next_ms >= 0) {
        if (next_ms == 0) next_ms = 1;
        uv_timer_start(&slot->zjs_wake, on_zjs_wake, (uint64_t) next_ms, 0);
    }

    uv_run(&slot->loop, UV_RUN_DEFAULT);

teardown:
    if (slot->loop_initialized) {
        uv_check_stop(&slot->check);
        uv_timer_stop(&slot->zjs_wake);
        uv_close((uv_handle_t*) &slot->check,           NULL);
        uv_close((uv_handle_t*) &slot->zjs_wake,        NULL);
        uv_close((uv_handle_t*) &slot->shutdown_async,  NULL);
        // Drain close callbacks before tearing down the loop. UV_RUN_DEFAULT
        // here would block forever if any handle is still open — but
        // we closed everything above, so the loop drains the closes and
        // returns once they're all done.
        uv_run(&slot->loop, UV_RUN_DEFAULT);
        uv_loop_close(&slot->loop);
        slot->loop_initialized = 0;
    }
    if (slot->ctx) {
        zjs_free_context(slot->ctx);
        slot->ctx = NULL;
    }
    slot->active = 0;
    fprintf(stderr, "[zapp] zjs worker '%s' exited\n", slot->worker_id);
    return NULL;
}

// ---------------------------------------------------------------------------
// Public C API — matches engine_router.zc's expected per-engine surface.
// ---------------------------------------------------------------------------

bool zjs_worker_create(const char* script_url, const char* owner_id, const char* worker_id) {
    if (!script_url || !worker_id) return false;

    pthread_mutex_lock(&zjs_workers_mutex);
    ZjsWorkerSlot* slot = NULL;
    for (int i = 0; i < ZJS_MAX_WORKERS; i++) {
        if (!zjs_workers[i].active) {
            slot = &zjs_workers[i];
            break;
        }
    }
    if (!slot) {
        pthread_mutex_unlock(&zjs_workers_mutex);
        fprintf(stderr, "[zapp] zjs worker pool full (max %d)\n", ZJS_MAX_WORKERS);
        return false;
    }

    memset(slot, 0, sizeof(*slot));
    strncpy(slot->worker_id, worker_id, sizeof(slot->worker_id) - 1);
    if (owner_id) strncpy(slot->owner_id, owner_id, sizeof(slot->owner_id) - 1);
    strncpy(slot->script_url, script_url, sizeof(slot->script_url) - 1);
    slot->active = 1;
    pthread_mutex_unlock(&zjs_workers_mutex);

    if (pthread_create(&slot->thread, NULL, zjs_worker_thread, slot) != 0) {
        fprintf(stderr, "[zapp] zjs pthread_create failed for '%s'\n", worker_id);
        slot->active = 0;
        return false;
    }
    pthread_detach(slot->thread);
    return true;
}

void zjs_worker_post_message(const char* worker_id, const char* data_json) {
    // Inbox + uv_async wake lands in the next cut (Z2 — message routing
    // alongside the direct invokeService path). For now a clear log so
    // any premature use surfaces instead of silently dropping.
    (void) data_json;
    fprintf(stderr, "[zapp] zjs_worker_post_message not yet implemented (worker '%s')\n",
        worker_id ? worker_id : "<null>");
}

void zjs_worker_terminate(const char* worker_id) {
    if (!worker_id) return;
    pthread_mutex_lock(&zjs_workers_mutex);
    ZjsWorkerSlot* slot = zjs_find_slot(worker_id);
    if (slot) {
        slot->shutting_down = 1;
        // uv_async_send is the only uv_* call that's thread-safe to
        // invoke from outside the loop's thread — it's how we wake the
        // worker. The async fires on_shutdown_async which uv_stops the
        // loop; the worker thread then unwinds via the teardown label.
        if (slot->loop_initialized) uv_async_send(&slot->shutdown_async);
    }
    pthread_mutex_unlock(&zjs_workers_mutex);
    // Thread is detached — slot.active flips to 0 when it exits.
}

void zjs_worker_terminate_owner(const char* owner_id) {
    if (!owner_id) return;
    pthread_mutex_lock(&zjs_workers_mutex);
    for (int i = 0; i < ZJS_MAX_WORKERS; i++) {
        if (zjs_workers[i].active && strcmp(zjs_workers[i].owner_id, owner_id) == 0) {
            zjs_workers[i].shutting_down = 1;
            if (zjs_workers[i].loop_initialized) {
                uv_async_send(&zjs_workers[i].shutdown_async);
            }
        }
    }
    pthread_mutex_unlock(&zjs_workers_mutex);
}
