// Bare worker engine — minimum viable host bridge.
//
// Each worker gets a pthread + uv_loop + js_platform + bare_t triple,
// fully isolated. Engine variant (V8 / JSC / QuickJS / mQJS) is picked
// at link time by which `ZAPP_WORKER_ENGINE_BARE_*` define is set;
// this file uses only the engine-agnostic libjs ABI from `<js.h>` and
// the bare embedding API from `<bare.h>`.
//
// Today this surfaces:
//   globalThis.__zappBridge.log(message)
//   globalThis.__zappBridge.workerId      (string, set at create time)
//
// Follow-ups (separate commits) wire `Services.invokeSync`, message
// passing (`postMessage` / `Workers.send`), supervisor crash callbacks,
// Bare module registration (bare-fetch, bare-ws, etc.).

#include "bare.h"

#if defined(ZAPP_WORKER_ENGINE_BARE_V8)     \
 || defined(ZAPP_WORKER_ENGINE_BARE_JSC)    \
 || defined(ZAPP_WORKER_ENGINE_BARE_QUICKJS) \
 || defined(ZAPP_WORKER_ENGINE_BARE_MQJS)   \
 || defined(ZAPP_WORKER_ENGINE_BARE_HERMES)

#include <bare.h>
#include <js.h>
#include <uv.h>
#include <stdatomic.h>

#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef __APPLE__
#include <TargetConditionals.h>
#include <compression.h>
#endif

// Embedded asset struct — matches the layout zapp_assets.zc emits.
typedef struct {
    const char* path;
    uint8_t* data;
    int len;
    int uncompressed_len;
    int is_brotli;
} ZappEmbeddedAsset;

extern ZappEmbeddedAsset zapp_embedded_assets[] __attribute__((weak));
extern int zapp_embedded_assets_count __attribute__((weak));
extern int zapp_build_use_embedded_assets(void);
extern const char* zapp_build_initial_url(void);
extern const char* zapp_build_fs_allowlist_json(void);

// Native service dispatch.
//
// Bare uses the legacy string path (`service_invoke_sync(const char*)`)
// rather than the zero-JSON tree-walk path that jsc.m and txiki.c
// take. The walker is "correct" — fewer string round-trips on paper —
// but in practice it's slower on bare specifically because libjs's
// reflection API (js_get_named_property, js_typeof, js_get_value_*)
// has per-call overhead that dominates on realistic payloads.
//
// Bench data (benchmarks/apps/zapp-host-bridge, 5-run median):
//   - invokeService(50-item array): jsc.m 138 µs, bare-jsc tree-walk 169 µs.
//   - jsc.m uses JSC selectors directly under the hood; bare's
//     walker pays libjs's wrapper cost on every property access,
//     which adds up faster than the JSON.stringify+parse it saves.
//
// We keep the JS-side wrapper that calls JSON.stringify on args
// (in bootstrap/bare-worker.ts) and read the resulting string here.
// On the way back, bare's worker also benefits from JSC's JIT'd
// JSON.stringify on response payloads (5× faster than jsc.m's
// NSJSONSerialization for the same data — a real bare-side win
// on the emit/dispatch path).
//
// `service_invoke_sync` returns a JSON-encoded result string owned
// by the framework — DO NOT free.
extern void* app_get_active(void);
extern const char* service_invoke_sync(void* app, const char* method, const char* args);

// Permission gates (native/permissions/permissions.zc + router.zc — Zen-C,
// plain C symbols). The router gates the webview invoke path; workers reach
// native through these host objects, bypassing the router, so the worker path
// runs the SAME mapping + check here. permission_id_for_invoke returns "" for
// ungated methods; the tier-1 host objects (clipboard/notif/shortcuts) and
// createWindow bypass invokeService entirely, so they call permissions_check
// directly with their catalog id.
extern bool permissions_check(const char* id, const char* method);
extern const char* permission_id_for_invoke(const char* method);

// Worker → host plumbing. All take JSON-stringified payloads from JS.
extern void worker_dispatch_to_webview(const char* worker_id, const char* data_json);
extern void worker_post_message(char* worker_id, char* data_json);
extern void dispatch_event_to_all(const char* event_name, const char* payload);
extern int  zapp_worker_supervisor_record_failure(const char* worker_id);
extern int  zapp_worker_supervisor_get_window_state(
    const char* worker_id, int* out_count, int* out_cap, int* out_window_ms);

// Active-worker registry — single source of truth shared with zjs.c and
// the webview IPC route. Returns a heap JSON array the caller free()s.
// Explicit char* return type: an implicit-int declaration would truncate
// the 64-bit pointer.
extern char* zapp_workers_registry_list_json(void);

// Per-worker log helpers (registry.zc). Both return const char* — declare the
// explicit return type so the 64-bit pointer isn't truncated by implicit-int.
// get_display_name returns the configured name or falls back to the worker_id;
// fmt_compact_ms compacts a ms duration ("30000ms" -> "30s") into a static buf.
extern const char* zapp_worker_registry_get_display_name(const char* worker_id);
extern const char* zapp_fmt_compact_ms(int ms);

// Framework log level (native/log/log.zc): 0=default, 1=verbose, 2=debug.
// Routine per-worker lifecycle lines below are gated to >= 1 (verbose) so they
// don't spam the default dev run; errors and supervisor restart/gave-up stay
// at default.
extern int zapp_log_level;

#ifndef __APPLE__
// --- Windows fallbacks for the Apple-named host shims ---
//
// The host objects below (clipboard, notifications, dock, shortcuts)
// call darwin_* directly — a transitional shape pending the planned
// zapp_* platform layer. Until the Windows backends land (M3 parity
// work), these definitions keep the link green and give workers the
// same silent no-op behavior the webview routes have on Windows.
// Sync is the exception: Windows has a real implementation, so it
// forwards. Delete entries from this block as real windows_* backends
// arrive.
extern void windows_sync_handle(const char* action, const char* payload_json);
void darwin_sync_handle(const char* action, const char* payload_json) {
    windows_sync_handle(action, payload_json);
}
#include "../../platform/windows/clipboard.h"
char* darwin_clipboard_read_text(void) { return windows_clipboard_read_text(); }
bool  darwin_clipboard_write_text(const char* text) { return windows_clipboard_write_text(text); }
char* darwin_clipboard_read_html(void) { return windows_clipboard_read_html(); }
bool  darwin_clipboard_write_html(const char* html) { return windows_clipboard_write_html(html); }
char* darwin_clipboard_read_files(void) { return windows_clipboard_read_files(); }
char* darwin_clipboard_read_image_png_b64(void) { return windows_clipboard_read_image_png_b64(); }
bool  darwin_clipboard_write_image_png_b64(const char* b64) { return windows_clipboard_write_image_png_b64(b64); }
bool  darwin_clipboard_has(const char* fmt) { return windows_clipboard_has(fmt); }
void  darwin_clipboard_clear(void) { windows_clipboard_clear(); }
const char* darwin_notification_get_permission(void) { return "denied"; }
void darwin_notification_show_typed(const char* a, const char* b, const char* c, const char* d) { (void)a; (void)b; (void)c; (void)d; }
void darwin_notification_schedule_typed(const char* a, const char* b, double c) { (void)a; (void)b; (void)c; }
void darwin_notification_cancel(const char* a) { (void)a; }
void darwin_notification_cancel_all(void) {}
void darwin_notification_remove_delivered(const char* a) { (void)a; }
void darwin_notification_remove_all_delivered(void) {}
void darwin_notification_update(const char* a, const char* b, const char* c, const char* d) { (void)a; (void)b; (void)c; (void)d; }
extern void windows_dock_show_icon(void);
extern void windows_dock_hide_icon(void);
extern void windows_dock_set_badge(const char* label);
extern void windows_dock_remove_badge(void);
extern void windows_dock_bounce(int bounce_type);
extern void windows_dock_set_icon(const char* path);
extern void windows_dock_reset_icon(void);
void darwin_dock_show_icon(void) { windows_dock_show_icon(); }
void darwin_dock_hide_icon(void) { windows_dock_hide_icon(); }
void darwin_dock_set_badge(const char* a) { windows_dock_set_badge(a); }
void darwin_dock_remove_badge(void) { windows_dock_remove_badge(); }
void darwin_dock_bounce(int a) { windows_dock_bounce(a); }
void darwin_dock_set_icon(const char* a) { windows_dock_set_icon(a); }
void darwin_dock_reset_icon(void) { windows_dock_reset_icon(); }
// Shortcuts stay false from worker threads: RegisterHotKey binds the
// hotkey to the CALLING thread's message queue, and worker threads
// run a libuv loop, not a Win32 message pump — a registration here
// would never fire. Needs the WM_ZAPP_TASK main-thread funnel (M2
// deferred item) to forward to platform/windows/shortcuts.c.
bool darwin_shortcut_register(const char* a) { (void)a; return false; }
bool darwin_shortcut_unregister(const char* a) { (void)a; return false; }
bool darwin_shortcut_is_registered(const char* a) { (void)a; return false; }
void darwin_shortcut_unregister_all(void) {}
#endif

// Sync API + window creation. darwin_sync_handle is thread-safe (uses
// pthread_mutex), so workers can call directly without bouncing to
// the main queue. Window creation is NOT thread-safe — must run on
// main, see the dispatch_async wrap below.
extern void darwin_sync_handle(const char* action, const char* payload_json);
extern int  zapp_worker_create_window_from_json(const char* opts_json);

// --- Message queue ---
//
// Mirrors the txiki engine's MsgQueue: bounded, mutex-guarded, ownership
// of payloads transferred via strdup on push / free on pop. Two queues
// per worker — one for postMessage data (parsed as JSON, dispatched to
// `globalThis.onmessage`), one for raw eval (broadcast paths from
// `Events.emit` and app-event dispatch).

#define BARE_MSG_QUEUE_MAX 256

typedef struct {
    char* messages[BARE_MSG_QUEUE_MAX];
    int head;
    int tail;
    int count;
    pthread_mutex_t mutex;
} BareMsgQueue;

static void bare_msgqueue_init(BareMsgQueue* q) {
    memset(q, 0, sizeof(*q));
    pthread_mutex_init(&q->mutex, NULL);
}

static int bare_msgqueue_push(BareMsgQueue* q, const char* msg) {
    pthread_mutex_lock(&q->mutex);
    if (q->count >= BARE_MSG_QUEUE_MAX) {
        pthread_mutex_unlock(&q->mutex);
        return -1;
    }
    q->messages[q->tail] = strdup(msg);
    q->tail = (q->tail + 1) % BARE_MSG_QUEUE_MAX;
    q->count++;
    pthread_mutex_unlock(&q->mutex);
    return 0;
}

static char* bare_msgqueue_pop(BareMsgQueue* q) {
    pthread_mutex_lock(&q->mutex);
    if (q->count == 0) {
        pthread_mutex_unlock(&q->mutex);
        return NULL;
    }
    char* msg = q->messages[q->head];
    q->messages[q->head] = NULL;
    q->head = (q->head + 1) % BARE_MSG_QUEUE_MAX;
    q->count--;
    pthread_mutex_unlock(&q->mutex);
    return msg;
}

static void bare_msgqueue_destroy(BareMsgQueue* q) {
    pthread_mutex_lock(&q->mutex);
    for (int i = 0; i < BARE_MSG_QUEUE_MAX; i++) {
        free(q->messages[i]);
        q->messages[i] = NULL;
    }
    q->count = 0;
    pthread_mutex_unlock(&q->mutex);
    pthread_mutex_destroy(&q->mutex);
}

// --- Slot table ---

#define BARE_MAX_WORKERS 64

typedef struct {
    char worker_id[64];
    char owner_id[64];
    char script_url[256];
    bool active;
    pthread_t thread;
    bare_t* bare;
    js_env_t* env;
    js_platform_t* platform;
    uv_loop_t* loop;          // owned by the worker thread; freed on teardown
    char* script_source;      // malloc'd; lives until bare_teardown completes
    int script_len;
    uv_async_t async;         // wakes worker thread for incoming messages
    int async_initialized;
    BareMsgQueue inbox;       // postMessage payloads (JSON strings)
    BareMsgQueue eval_inbox;  // raw JS to eval (broadcast path)

    // Reincarnation counter — 1 on first start, +1 each successful restart.
    // Written from the outer loop in bare_worker_thread (Task 2.3).
    int incarnation;

    // Control flags — written from bare_host_worker_crash (worker thread)
    // and bare_worker_terminate (any thread). The outer reincarnation
    // loop reads these after bare_run returns. wants_terminate wins.
    _Atomic int wants_restart;
    _Atomic int wants_terminate;
} BareWorkerSlot;

static BareWorkerSlot bare_workers[BARE_MAX_WORKERS] = {0};
static pthread_mutex_t bare_mutex = PTHREAD_MUTEX_INITIALIZER;

// --- Process-wide JS platform ---
//
// V8 has a strict global initialization contract: `V8::InitializePlatform`
// must be called exactly once per process, from a single thread, before
// any V8 environments are created. Two threads racing into V8::Initialize
// trips a fatal "Wrong initialization order" abort. libjsc and libqjs
// don't enforce this, but they're still happy to share a single platform.
//
// We mirror the reference Bare CLI (vendor/bare/bin/bare.c): one
// dedicated platform thread runs js_create_platform once, holds a
// uv_loop running indefinitely on it, and a uv_barrier coordinates
// "platform ready" with the rest of the process. Every worker thread
// then calls bare_setup with this shared platform pointer.
//
// Lazy: only spun up the first time any bare worker is created. Apps
// that never reach for a worker pay zero cost (no extra thread).

static pthread_once_t bare_platform_once = PTHREAD_ONCE_INIT;
static js_platform_t* bare_shared_platform = NULL;
static uv_loop_t bare_platform_loop;
static uv_async_t bare_platform_shutdown;
static uv_barrier_t bare_platform_ready;
static pthread_t bare_platform_tid;

static void bare_on_platform_shutdown(uv_async_t* h) {
    uv_close((uv_handle_t*)h, NULL);
}

static void* bare_platform_thread(void* unused) {
    (void)unused;
    int err;

    err = uv_loop_init(&bare_platform_loop);
    if (err != 0) {
        fprintf(stderr, "[zapp] bare platform thread uv_loop_init failed: %s\n",
            uv_strerror(err));
        return NULL;
    }
    err = uv_async_init(&bare_platform_loop, &bare_platform_shutdown,
                        bare_on_platform_shutdown);
    if (err != 0) {
        fprintf(stderr, "[zapp] bare platform thread uv_async_init failed: %s\n",
            uv_strerror(err));
        uv_loop_close(&bare_platform_loop);
        return NULL;
    }

    js_platform_options_t platform_opts = {0};
    err = js_create_platform(&bare_platform_loop, &platform_opts, &bare_shared_platform);
    if (err != 0) {
        fprintf(stderr, "[zapp] bare js_create_platform failed (err=%d)\n", err);
        bare_shared_platform = NULL;
    }

    // Signal the parent thread that the platform is ready (or NULL on failure).
    uv_barrier_wait(&bare_platform_ready);

    // Run the platform loop until something calls uv_async_send(&bare_platform_shutdown).
    // Today nothing does — the platform lives for the lifetime of the
    // process (matches the reference Bare CLI). Worker teardown
    // doesn't touch this; only process exit closes it.
    uv_run(&bare_platform_loop, UV_RUN_DEFAULT);

    if (bare_shared_platform) {
        js_destroy_platform(bare_shared_platform);
        bare_shared_platform = NULL;
    }
    uv_run(&bare_platform_loop, UV_RUN_DEFAULT);
    uv_loop_close(&bare_platform_loop);
    return NULL;
}

static void bare_init_platform_once(void) {
    int err;
    err = uv_barrier_init(&bare_platform_ready, 2);
    if (err != 0) {
        fprintf(stderr, "[zapp] bare uv_barrier_init failed: %s\n", uv_strerror(err));
        return;
    }
    err = pthread_create(&bare_platform_tid, NULL, bare_platform_thread, NULL);
    if (err != 0) {
        fprintf(stderr, "[zapp] bare platform pthread_create failed (err=%d)\n", err);
        uv_barrier_destroy(&bare_platform_ready);
        return;
    }
    pthread_detach(bare_platform_tid);

    // Wait for the platform thread to finish js_create_platform.
    uv_barrier_wait(&bare_platform_ready);
    uv_barrier_destroy(&bare_platform_ready);
}

// Public-ish: returns the shared platform pointer, lazily creating it
// on first call. NULL if creation failed (also logged).
static js_platform_t* bare_get_shared_platform(void) {
    pthread_once(&bare_platform_once, bare_init_platform_once);
    return bare_shared_platform;
}

static BareWorkerSlot* bare_find_slot(const char* worker_id) {
    if (!worker_id) return NULL;
    for (int i = 0; i < BARE_MAX_WORKERS; i++) {
        if (bare_workers[i].active &&
            strcmp(bare_workers[i].worker_id, worker_id) == 0) {
            return &bare_workers[i];
        }
    }
    return NULL;
}

// --- Script loading ---
//
// Same fallback chain as the txiki engine: embedded brotli (prod) →
// filesystem (macOS dev) → HTTP fetch from Vite dev URL (iOS dev,
// where the Sim sandbox can't see the host filesystem).

static char* bare_load_script(const char* script_url, int* out_len) {
    if (!script_url || !script_url[0]) return NULL;

    // 1. Embedded assets (production build).
    if (zapp_build_use_embedded_assets() &&
        &zapp_embedded_assets_count != NULL) {
        for (int i = 0; i < zapp_embedded_assets_count; i++) {
            if (strcmp(zapp_embedded_assets[i].path, script_url) != 0) continue;
            char* code = NULL;
            int code_len = 0;
            if (zapp_embedded_assets[i].is_brotli &&
                zapp_embedded_assets[i].uncompressed_len > 0) {
#ifdef __APPLE__
                code = (char*)malloc(zapp_embedded_assets[i].uncompressed_len + 1);
                code_len = (int)compression_decode_buffer(
                    (uint8_t*)code, zapp_embedded_assets[i].uncompressed_len,
                    zapp_embedded_assets[i].data, zapp_embedded_assets[i].len,
                    NULL, COMPRESSION_BROTLI);
                code[code_len] = '\0';
#else
                // Non-Apple host doesn't ship libcompression; brotli
                // decode hookup deferred until Linux/Windows port
                fprintf(stderr,
                    "[zapp] bare worker: brotli decode not available on this platform\n");
                return NULL;
#endif
            } else {
                code_len = zapp_embedded_assets[i].len;
                code = (char*)malloc(code_len + 1);
                memcpy(code, zapp_embedded_assets[i].data, code_len);
                code[code_len] = '\0';
            }
            if (zapp_log_level >= 1) {
                fprintf(stderr, "[zapp] bare worker loaded from embedded: %s\n", script_url);
            }
            *out_len = code_len;
            return code;
        }
    }

    // 2. Filesystem (macOS dev — cwd is the project root).
    char cwd[256];
    if (getcwd(cwd, sizeof(cwd))) {
        const char* basename = strrchr(script_url, '/');
        basename = basename ? basename + 1 : script_url;
        char path_buf[512];
        snprintf(path_buf, sizeof(path_buf), "%s/.zapp/workers/%s", cwd, basename);
        // "rb" — see zjs.c's loader: Windows text mode corrupts binary
        // artifacts and shortens reads. POSIX ignores the 'b'.
        FILE* f = fopen(path_buf, "rb");
        if (f) {
            fseek(f, 0, SEEK_END);
            long len = ftell(f);
            fseek(f, 0, SEEK_SET);
            char* code = (char*)malloc(len + 1);
            if (code) {
                fread(code, 1, len, f);
                code[len] = '\0';
                fclose(f);
                if (zapp_log_level >= 1) {
                    fprintf(stderr, "[zapp] bare worker loaded from disk: %s\n", path_buf);
                }
                *out_len = (int)len;
                return code;
            }
            fclose(f);
        }
    }

    // 3. iOS dev: HTTP fetch from Vite dev URL (Sim can't see host fs).
#if defined(__APPLE__) && TARGET_OS_IPHONE
    {
        const char* dev_url = zapp_build_initial_url();
        if (dev_url && dev_url[0] != '\0') {
            char full_url[1024];
            snprintf(full_url, sizeof(full_url), "%s%s", dev_url, script_url);
            extern char* zapp_ios_fetch_url_sync(const char* url, int* out_len);
            int fetched_len = 0;
            char* fetched = zapp_ios_fetch_url_sync(full_url, &fetched_len);
            if (fetched) {
                fprintf(stderr,
                    "[zapp] bare worker loaded from dev server: %s\n", full_url);
                *out_len = fetched_len;
                return fetched;
            }
        }
    }
#endif

    fprintf(stderr, "[zapp] bare worker script not found: %s\n", script_url);
    return NULL;
}

// --- uv_async_t handler: drain inboxes on the worker thread ---
//
// libuv signals this whenever the host calls uv_async_send on the
// worker's `async` handle (after pushing into either the eval_inbox
// or the postMessage inbox). We drain BOTH queues each time:
//
//   - eval_inbox: raw JS strings from broadcast paths (Events.emit,
//     app events). Each string is `js_run_script`-evaluated directly.
//
//   - inbox: postMessage data payloads (already JSON-encoded). We parse
//     into a JS value and dispatch to `globalThis.onmessage` and any
//     entries in `globalThis._messageHandlers` (the channel API).
//
// Mirrors txiki's on_async_message exactly. The dispatch shape (the
// `onmessage` global, the `_messageHandlers` array) is the contract
// that runtime/worker.ts and the worker bootstrap rely on; matching
// engines means user code is engine-agnostic.

static void bare_on_async_message(uv_async_t* handle) {
    BareWorkerSlot* slot = (BareWorkerSlot*)handle->data;
    if (!slot || !slot->env) return;

    js_handle_scope_t* scope;
    js_open_handle_scope(slot->env, &scope);

    // 1. Drain raw JS eval messages (broadcast path). We wrap each in a
    //    try/catch on the JS side because broadcast scripts assume a
    //    richer bridge surface (Symbol.for('zapp.bridge')._onEvent etc.)
    //    that may not yet be installed during early bootstrap. Without
    //    the wrapper, one missing symbol kills the whole worker.
    char* eval_msg;
    while ((eval_msg = bare_msgqueue_pop(&slot->eval_inbox)) != NULL) {
        size_t wrapped_len = strlen(eval_msg) + 128;
        char* wrapped = (char*)malloc(wrapped_len);
        snprintf(wrapped, wrapped_len, "try{%s}catch(e){}", eval_msg);

        js_value_t* src;
        js_create_string_utf8(slot->env, (const utf8_t*)wrapped,
                              strlen(wrapped), &src);
        js_value_t* result;
        int err = js_run_script(slot->env, "<event-broadcast>", -1, 0, src, &result);
        if (err) {
            fprintf(stderr, "[zapp/%s] broadcast eval failed (err=%d)\n",
                zapp_worker_registry_get_display_name(slot->worker_id), err);
        }
        free(wrapped);
        free(eval_msg);
    }

    // 2. Drain postMessage payloads. Parse JSON, build event {data}, call
    //    onmessage + each entry in _messageHandlers.
    js_value_t* global;
    js_get_global(slot->env, &global);

    char* msg;
    while ((msg = bare_msgqueue_pop(&slot->inbox)) != NULL) {
        // Wrap in `globalThis.__zappBridge._dispatchMessage(jsonString)` so
        // the JSON.parse + onmessage call happens in JS — saves us writing
        // a JSON parser via the libjs ABI (no js_parse_json helper exists).
        // The dispatcher itself is bound during worker bootstrap below.
        size_t code_len = strlen(msg) + 64;
        char* code = (char*)malloc(code_len);
        snprintf(code, code_len,
                 "globalThis.__zappBridge._dispatchMessage(%s);", msg);
        js_value_t* src;
        js_create_string_utf8(slot->env, (const utf8_t*)code, strlen(code), &src);
        js_value_t* result;
        int err = js_run_script(slot->env, "<post-message>", -1, 0, src, &result);
        if (err) {
            fprintf(stderr, "[zapp/%s] postMessage dispatch failed (err=%d)\n",
                zapp_worker_registry_get_display_name(slot->worker_id), err);
        }
        free(code);
        free(msg);
    }

    js_close_handle_scope(slot->env, scope);
}

// --- Host function: __zappBridge.log ---
//
// First host function — proves JS can call into C through libjs's
// trampoline. Future commits add invokeSync, postMessage, etc.

static js_value_t* bare_host_log(js_env_t* env, js_callback_info_t* info) {
    size_t argc = 1;
    js_value_t* argv[1];
    void* data = NULL;
    js_get_callback_info(env, info, &argc, argv, NULL, &data);
    BareWorkerSlot* slot = (BareWorkerSlot*)data;

    if (argc >= 1) {
        // Read up to 4KB of message; truncate longer payloads.
        char buf[4096];
        size_t len = 0;
        js_get_value_string_utf8(env, argv[0], (utf8_t*)buf, sizeof(buf) - 1, &len);
        buf[len] = '\0';
        // Worker console is the app's OWN output — always shown, never gated
        // by verbosity. Prefix with the registry display name ([zapp/<worker>])
        // to unify with the #150 lifecycle log format.
        const char* worker_id = slot ? slot->worker_id : "?";
        fprintf(stderr, "[zapp/%s] %s\n",
            zapp_worker_registry_get_display_name(worker_id), buf);
    }

    js_value_t* undef;
    js_get_undefined(env, &undef);
    return undef;
}

// __zappBridge._invokeServiceRaw(method, argsJson) — synchronous
// service invocation via the JSON-string path.
//
// JS-side wrapper (in bootstrap/bare-worker.ts) does JSON.stringify
// on args; we read that string and hand it to service_invoke_sync.
// The framework parses internally. We tried a zero-JSON tree-walk
// path that built a JsonValue directly via libjs's reflection API
// (js_get_named_property, js_typeof, …) — same shape jsc.m and
// txiki.c use — but in practice it was slower on realistic payloads
// (169 µs vs 138 µs on a 50-item array, vs jsc.m). The libjs ABI
// has per-call overhead that erases the JSON-roundtrip savings.
// See benchmarks/apps/zapp-host-bridge for numbers.
//
// The result string is owned by the framework — do not free.

static js_value_t* bare_host_invoke_service(js_env_t* env, js_callback_info_t* info) {
    size_t argc = 2;
    js_value_t* argv[2];
    void* data = NULL;
    js_get_callback_info(env, info, &argc, argv, NULL, &data);
    BareWorkerSlot* slot = (BareWorkerSlot*)data;

    js_value_t* undef;
    js_get_undefined(env, &undef);

    if (argc < 2) return undef;

    // Read method name — short identifiers, fixed buffer is fine.
    char method[256];
    size_t method_len = 0;
    js_get_value_string_utf8(env, argv[0], (utf8_t*)method, sizeof(method) - 1, &method_len);
    method[method_len] = '\0';

    // Permission gate (same mapping the router runs for the webview path).
    // Gated method + manifest active + not granted → throw so the synchronous
    // invokeService() call rejects/throws on the JS side (parity with the
    // webview path, which rejects with new Error("PERMISSION_DENIED:<id>")).
    const char* perm_id = permission_id_for_invoke(method);
    if (perm_id && perm_id[0] && !permissions_check(perm_id, method)) {
        char denied[160];
        snprintf(denied, sizeof(denied), "PERMISSION_DENIED:%s", perm_id);
        js_throw_error(env, NULL, denied);
        return undef;
    }

    // Read args JSON. The two-call probe pattern (size first, then
    // read) is libjs's idiom for dynamic-length strings.
    size_t args_len = 0;
    js_get_value_string_utf8(env, argv[1], NULL, 0, &args_len);
    char* args_json = (char*)malloc(args_len + 1);
    if (!args_json) return undef;
    js_get_value_string_utf8(env, argv[1], (utf8_t*)args_json, args_len + 1, &args_len);
    args_json[args_len] = '\0';

    void* app = app_get_active();
    if (!app) {
        free(args_json);
        return undef;
    }
    const char* result = service_invoke_sync(app, method, args_json);
    free(args_json);

    if (!result || result[0] == '\0') return undef;

    js_value_t* out;
    js_create_string_utf8(env, (const utf8_t*)result, strlen(result), &out);
    (void)slot;  // currently unused; reserved for per-worker accounting
    return out;
}

// __zappBridge.listWorkers() -> string (JSON array of active workers)
//
// Worker-context Workers.list() on bare. Parity counterpart to zjs.c's
// host_list_workers: returns the registry's JSON string verbatim and the
// JS runtime wrapper JSON.parses it. Returns "[]" (a valid empty array)
// when the registry yields NULL so the JS side always gets something
// parseable — never null/undefined.
//
// js_create_string_utf8 copies the bytes into engine-managed storage
// (the libjs JSC backend's js_to_string_utf8 builds a fresh JSString;
// the zero-copy path is the separate js_create_external_string_utf8,
// which takes a finalize callback this plain variant lacks). So the heap
// buffer is ours to free() immediately after construction — same
// free-after-construct pattern used by bare_host_clipboard above.
static js_value_t* bare_host_list_workers(js_env_t* env, js_callback_info_t* info) {
    (void)info;
    char* json = zapp_workers_registry_list_json();
    js_value_t* out;
    if (!json) {
        js_create_string_utf8(env, (const utf8_t*)"[]", 2, &out);
        return out;
    }
    js_create_string_utf8(env, (const utf8_t*)json, strlen(json), &out);
    free(json);
    return out;
}

// Read an arbitrarily-sized JS string into a heap buffer. Caller frees.
// Returns NULL on conversion failure / null arg. The two-call probe
// pattern (size first, then read) is the libjs ABI's idiom for
// dynamic-length strings; mirrors how runtime.c does it internally.
static char* bare_read_js_string_dup(js_env_t* env, js_value_t* val) {
    if (!val) return NULL;
    size_t len = 0;
    if (js_get_value_string_utf8(env, val, NULL, 0, &len) != 0) return NULL;
    char* buf = (char*)malloc(len + 1);
    if (!buf) return NULL;
    js_get_value_string_utf8(env, val, (utf8_t*)buf, len + 1, &len);
    buf[len] = '\0';
    return buf;
}

// Read a string-typed property from a JS object as a heap-allocated
// C string. Returns NULL when the property is missing / undefined /
// null. Caller frees on non-NULL return.
//
// Used by every tier-1 host fn that takes an `args` object — keeps
// the C side clean by hiding the property-fetch + string-conversion
// boilerplate.
static char* bare_get_string_prop(js_env_t* env, js_value_t* obj, const char* name) {
    if (!obj) return NULL;
    js_value_t* val;
    if (js_get_named_property(env, obj, name, &val) != 0 || !val) return NULL;
    // Defensive: js_get_named_property succeeds even when the property
    // is undefined / not present. The string read below will fail or
    // return an empty string — we treat both as "absent" for the
    // purposes of these dispatchers.
    return bare_read_js_string_dup(env, val);
}

// Heap-allocating JSON string escape. Returns malloc'd buffer the
// caller frees, or NULL on allocation failure. Worst case is a 6x
// blow-up (every byte = \uXXXX) so we size accordingly. NULL input
// returns an empty heap buffer so callers don't have to special-case.
//
// Why this exists: the worker-crash payload assembly previously used
// raw %s substitutions for `message`/`stack`. Error stacks always
// contain newlines and frequently contain double-quotes — both
// invalid bare in JSON string literals — so the webview's JSON.parse
// blew up on every worker crash, surfacing as
// `[zapp] event handler error: parse@[native code]` upstream of
// every actual error report.
static char* bare_json_escape_dup(const char* src) {
    if (!src) {
        char* e = (char*)malloc(1);
        if (e) e[0] = '\0';
        return e;
    }
    size_t n = strlen(src);
    char* dst = (char*)malloc(n * 6 + 1);
    if (!dst) return NULL;
    size_t j = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)src[i];
        switch (c) {
            case '"':  dst[j++] = '\\'; dst[j++] = '"';  break;
            case '\\': dst[j++] = '\\'; dst[j++] = '\\'; break;
            case '\n': dst[j++] = '\\'; dst[j++] = 'n';  break;
            case '\r': dst[j++] = '\\'; dst[j++] = 'r';  break;
            case '\t': dst[j++] = '\\'; dst[j++] = 't';  break;
            case '\b': dst[j++] = '\\'; dst[j++] = 'b';  break;
            case '\f': dst[j++] = '\\'; dst[j++] = 'f';  break;
            default:
                if (c < 0x20) {
                    static const char hex[] = "0123456789abcdef";
                    dst[j++] = '\\'; dst[j++] = 'u';
                    dst[j++] = '0';  dst[j++] = '0';
                    dst[j++] = hex[(c >> 4) & 0xF];
                    dst[j++] = hex[c & 0xF];
                } else {
                    dst[j++] = (char)c;
                }
        }
    }
    dst[j] = '\0';
    return dst;
}

// Read a numeric property as a double, with a default. Same shape as
// the string variant — returns the default when the property is
// missing or not coercible.
static double bare_get_double_prop(js_env_t* env, js_value_t* obj, const char* name, double dflt) {
    if (!obj) return dflt;
    js_value_t* val;
    if (js_get_named_property(env, obj, name, &val) != 0 || !val) return dflt;
    double out = dflt;
    if (js_get_value_double(env, val, &out) != 0) return dflt;
    return out;
}

// __zappBridge.postToWebview(jsonString) — sends a JSON-string message
// to the worker's owning window. The bootstrap's `self.postMessage`
// alias points here; user code rarely calls it directly.
static js_value_t* bare_host_post_to_webview(js_env_t* env, js_callback_info_t* info) {
    size_t argc = 1;
    js_value_t* argv[1];
    void* data = NULL;
    js_get_callback_info(env, info, &argc, argv, NULL, &data);
    BareWorkerSlot* slot = (BareWorkerSlot*)data;
    js_value_t* undef;
    js_get_undefined(env, &undef);
    if (argc < 1 || !slot) return undef;

    char* payload = bare_read_js_string_dup(env, argv[0]);
    if (!payload) return undef;
    worker_dispatch_to_webview(slot->worker_id, payload);
    free(payload);
    return undef;
}

// __zappBridge.postToWorker(targetId, jsonString) — direct worker→worker
// channel. Skips the webview hop a webview-mediated path would do, so
// pipelines (ingest → db → sync) stay point-to-point.
static js_value_t* bare_host_post_to_worker(js_env_t* env, js_callback_info_t* info) {
    size_t argc = 2;
    js_value_t* argv[2];
    void* data = NULL;
    js_get_callback_info(env, info, &argc, argv, NULL, &data);
    js_value_t* undef;
    js_get_undefined(env, &undef);
    if (argc < 2) return undef;

    char* target = bare_read_js_string_dup(env, argv[0]);
    char* payload = bare_read_js_string_dup(env, argv[1]);
    if (target && payload) worker_post_message(target, payload);
    free(target);
    free(payload);
    return undef;
}

// __zappBridge.dispatchEventToAll(name, payloadJson) — broadcast a
// fire-and-forget event to every webview AND every worker (the
// dispatch.zc side handles the fan-out, gated on ZAPP_HAS_BARE +
// per-engine defines).
static js_value_t* bare_host_dispatch_event_to_all(js_env_t* env, js_callback_info_t* info) {
    size_t argc = 2;
    js_value_t* argv[2];
    void* data = NULL;
    js_get_callback_info(env, info, &argc, argv, NULL, &data);
    js_value_t* undef;
    js_get_undefined(env, &undef);
    if (argc < 1) return undef;

    char* name = bare_read_js_string_dup(env, argv[0]);
    char* payload = argc >= 2 ? bare_read_js_string_dup(env, argv[1]) : NULL;
    if (name) dispatch_event_to_all(name, payload ? payload : "{}");
    free(name);
    free(payload);
    return undef;
}

// --- Tier-1 host objects (clipboard, notif, shortcuts) ---
//
// These mirror the (action, args) dispatch pattern jsc.m and txiki.c
// use. The runtime/clipboard.ts / runtime/notification.ts /
// runtime/shortcuts.ts wrappers already call `__zappBridge.<name>(action, args)`
// — porting to bare just means binding the same shape.

extern char* darwin_clipboard_read_text(void);
extern bool  darwin_clipboard_write_text(const char* text);
extern char* darwin_clipboard_read_html(void);
extern bool  darwin_clipboard_write_html(const char* html);
extern char* darwin_clipboard_read_files(void);
extern char* darwin_clipboard_read_image_png_b64(void);
extern bool  darwin_clipboard_write_image_png_b64(const char* b64);
extern bool  darwin_clipboard_has(const char* fmt);
extern void  darwin_clipboard_clear(void);

static js_value_t* bare_host_clipboard(js_env_t* env, js_callback_info_t* info) {
    size_t argc = 2;
    js_value_t* argv[2];
    js_get_callback_info(env, info, &argc, argv, NULL, NULL);

    js_value_t* undef;
    js_get_undefined(env, &undef);
    if (argc < 1) return undef;

    char action[64];
    size_t alen = 0;
    js_get_value_string_utf8(env, argv[0], (utf8_t*)action, sizeof(action) - 1, &alen);
    action[alen] = '\0';

    js_value_t* args = argc >= 2 ? argv[1] : NULL;

    // Per-branch permission gate: read* / has → "clipboard:read",
    // write* / clear → "clipboard:write". This host object bypasses
    // invokeService + the router, so the check lives here. Denied →
    // return the branch's own empty/false value (silent; permissions_check
    // logs the denial once).
    if (strcmp(action, "readText") == 0) {
        if (!permissions_check("clipboard:read", "clipboard.readText")) return undef;
        char* s = darwin_clipboard_read_text();
        js_value_t* out;
        js_create_string_utf8(env, (const utf8_t*)(s ? s : ""), s ? strlen(s) : 0, &out);
        if (s) free(s);
        return out;
    }
    if (strcmp(action, "writeText") == 0) {
        if (!permissions_check("clipboard:write", "clipboard.writeText")) return undef;
        char* text = bare_get_string_prop(env, args, "text");
        darwin_clipboard_write_text(text ? text : "");
        free(text);
        return undef;
    }
    if (strcmp(action, "readHtml") == 0) {
        if (!permissions_check("clipboard:read", "clipboard.readHtml")) return undef;
        char* s = darwin_clipboard_read_html();
        js_value_t* out;
        js_create_string_utf8(env, (const utf8_t*)(s ? s : ""), s ? strlen(s) : 0, &out);
        if (s) free(s);
        return out;
    }
    if (strcmp(action, "writeHtml") == 0) {
        if (!permissions_check("clipboard:write", "clipboard.writeHtml")) return undef;
        char* html = bare_get_string_prop(env, args, "html");
        darwin_clipboard_write_html(html ? html : "");
        free(html);
        return undef;
    }
    if (strcmp(action, "readFiles") == 0) {
        if (!permissions_check("clipboard:read", "clipboard.readFiles")) {
            js_value_t* empty;
            js_create_string_utf8(env, (const utf8_t*)"[]", 2, &empty);
            return empty;
        }
        // Native returns a JSON-array string; runtime wrapper JSON.parses it.
        char* j = darwin_clipboard_read_files();
        js_value_t* out;
        js_create_string_utf8(env, (const utf8_t*)(j ? j : "[]"), j ? strlen(j) : 2, &out);
        if (j) free(j);
        return out;
    }
    if (strcmp(action, "readImage") == 0) {
        if (!permissions_check("clipboard:read", "clipboard.readImage")) return undef;
        char* b64 = darwin_clipboard_read_image_png_b64();
        js_value_t* out;
        js_create_string_utf8(env, (const utf8_t*)(b64 ? b64 : ""), b64 ? strlen(b64) : 0, &out);
        if (b64) free(b64);
        return out;
    }
    if (strcmp(action, "writeImage") == 0) {
        if (!permissions_check("clipboard:write", "clipboard.writeImage")) return undef;
        char* data = bare_get_string_prop(env, args, "data");
        darwin_clipboard_write_image_png_b64(data ? data : "");
        free(data);
        return undef;
    }
    if (strcmp(action, "has") == 0) {
        if (!permissions_check("clipboard:read", "clipboard.has")) {
            js_value_t* out;
            js_get_boolean(env, false, &out);
            return out;
        }
        char* fmt = bare_get_string_prop(env, args, "format");
        bool h = darwin_clipboard_has(fmt ? fmt : "");
        free(fmt);
        js_value_t* out;
        js_get_boolean(env, h, &out);
        return out;
    }
    if (strcmp(action, "clear") == 0) {
        if (!permissions_check("clipboard:write", "clipboard.clear")) return undef;
        darwin_clipboard_clear();
        return undef;
    }
    return undef;
}

extern const char* darwin_notification_get_permission(void);
extern void darwin_notification_show_typed(const char*, const char*, const char*, const char*);
extern void darwin_notification_schedule_typed(const char*, const char*, double);
extern void darwin_notification_cancel(const char*);
extern void darwin_notification_cancel_all(void);
extern void darwin_notification_remove_delivered(const char*);
extern void darwin_notification_remove_all_delivered(void);
extern void darwin_notification_update(const char*, const char*, const char*, const char*);

static js_value_t* bare_host_notif(js_env_t* env, js_callback_info_t* info) {
    size_t argc = 2;
    js_value_t* argv[2];
    js_get_callback_info(env, info, &argc, argv, NULL, NULL);

    js_value_t* undef;
    js_get_undefined(env, &undef);
    if (argc < 1) return undef;

    char action[64];
    size_t alen = 0;
    js_get_value_string_utf8(env, argv[0], (utf8_t*)action, sizeof(action) - 1, &alen);
    action[alen] = '\0';

    // Permission gate — notifications bypass invokeService + the router, so
    // the check lives here. Denied → undef (the fn's own miss/error return).
    if (!permissions_check("notifications", "Notification")) return undef;

    js_value_t* args = argc >= 2 ? argv[1] : NULL;

    if (strcmp(action, "getPermission") == 0) {
        const char* st = darwin_notification_get_permission();
        // jsc.m returns { status: <string> }. We do the same: build a tiny
        // result object so the JS side's contract holds.
        js_value_t* obj;
        js_create_object(env, &obj);
        js_value_t* st_val;
        js_create_string_utf8(env, (const utf8_t*)(st ? st : "notDetermined"),
                              strlen(st ? st : "notDetermined"), &st_val);
        js_set_named_property(env, obj, "status", st_val);
        return obj;
    }
    if (strcmp(action, "show") == 0 || strcmp(action, "schedule") == 0) {
        char* title    = bare_get_string_prop(env, args, "title");
        char* subtitle = bare_get_string_prop(env, args, "subtitle");
        char* body     = bare_get_string_prop(env, args, "body");
        if (strcmp(action, "show") == 0) {
            char* sound = bare_get_string_prop(env, args, "sound");
            darwin_notification_show_typed(title ? title : "",
                                           subtitle ? subtitle : "",
                                           body ? body : "",
                                           sound ? sound : "default");
            free(sound);
        } else {
            double delay = bare_get_double_prop(env, args, "delaySeconds", 0);
            darwin_notification_schedule_typed(title ? title : "",
                                               body ? body : "",
                                               delay);
        }
        free(title); free(subtitle); free(body);

        // Match jsc.m's "make a client-side ID" contract — we don't
        // expose the native delivery ID synchronously today.
        char idbuf[64];
        snprintf(idbuf, sizeof(idbuf), "notif-%lu-%u",
                 (unsigned long)time(NULL), (unsigned int)rand());
        js_value_t* obj;
        js_create_object(env, &obj);
        js_value_t* id_val;
        js_create_string_utf8(env, (const utf8_t*)idbuf, strlen(idbuf), &id_val);
        js_set_named_property(env, obj, "id", id_val);
        return obj;
    }
    if (strcmp(action, "cancel") == 0) {
        char* id = bare_get_string_prop(env, args, "id");
        darwin_notification_cancel(id ? id : "");
        free(id);
        return undef;
    }
    if (strcmp(action, "cancelAll") == 0) {
        darwin_notification_cancel_all();
        return undef;
    }
    if (strcmp(action, "removeDelivered") == 0) {
        char* id = bare_get_string_prop(env, args, "id");
        darwin_notification_remove_delivered(id ? id : "");
        free(id);
        return undef;
    }
    if (strcmp(action, "removeAllDelivered") == 0) {
        darwin_notification_remove_all_delivered();
        return undef;
    }
    if (strcmp(action, "update") == 0) {
        char* id       = bare_get_string_prop(env, args, "id");
        char* title    = bare_get_string_prop(env, args, "title");
        char* subtitle = bare_get_string_prop(env, args, "subtitle");
        char* body     = bare_get_string_prop(env, args, "body");
        darwin_notification_update(id ? id : "",
                                   title ? title : "",
                                   subtitle ? subtitle : "",
                                   body ? body : "");
        free(id); free(title); free(subtitle); free(body);
        return undef;
    }
    return undef;
}

extern void darwin_dock_show_icon(void);
extern void darwin_dock_hide_icon(void);
extern void darwin_dock_set_badge(const char*);
extern void darwin_dock_remove_badge(void);
extern void darwin_dock_bounce(int);
extern void darwin_dock_set_icon(const char*);
extern void darwin_dock_reset_icon(void);

static js_value_t* bare_host_dock(js_env_t* env, js_callback_info_t* info) {
    size_t argc = 2;
    js_value_t* argv[2];
    js_get_callback_info(env, info, &argc, argv, NULL, NULL);
    js_value_t* undef;
    js_get_undefined(env, &undef);
    if (argc < 1) return undef;

    // Permission gate — dock bypasses invokeService + the router, so
    // the check lives here. Denied → undef (the fn's own miss return).
    if (!permissions_check("dock", "Dock")) return undef;

    char action[32];
    size_t alen = 0;
    js_get_value_string_utf8(env, argv[0], (utf8_t*)action, sizeof(action) - 1, &alen);
    action[alen] = '\0';

    js_value_t* args = argc >= 2 ? argv[1] : NULL;

    if (strcmp(action, "showIcon") == 0) { darwin_dock_show_icon(); return undef; }
    if (strcmp(action, "hideIcon") == 0) { darwin_dock_hide_icon(); return undef; }
    if (strcmp(action, "removeBadge") == 0) { darwin_dock_remove_badge(); return undef; }
    if (strcmp(action, "resetIcon") == 0) { darwin_dock_reset_icon(); return undef; }
    if (strcmp(action, "setBadge") == 0) {
        char* label = bare_get_string_prop(env, args, "label");
        darwin_dock_set_badge(label ? label : "");
        free(label);
        return undef;
    }
    if (strcmp(action, "bounce") == 0) {
        double t = bare_get_double_prop(env, args, "type", 0);
        darwin_dock_bounce((int)t);
        return undef;
    }
    if (strcmp(action, "setIcon") == 0) {
        char* p = bare_get_string_prop(env, args, "path");
        darwin_dock_set_icon(p ? p : "");
        free(p);
        return undef;
    }
    return undef;
}

// __zappBridge.quit() — terminate the app from any worker. Same as
// jsc.m's quit; dispatch to main is unnecessary on bare since exit(0)
// is signal-safe and the libuv loop will tear down on the way out.
static js_value_t* bare_host_quit(js_env_t* env, js_callback_info_t* info) {
    (void)env; (void)info;
    exit(0);
}

// __zappBridge.subscribeWindowEvent(windowId, eventId) — register the
// worker for a given window's event stream. Negative windowId means
// "all windows". Mirrors jsc.m:374-387.
extern void zapp_window_set_backend_listener(int id, int event_id, int has_listener);
static js_value_t* bare_host_subscribe_window_event(js_env_t* env, js_callback_info_t* info) {
    size_t argc = 2;
    js_value_t* argv[2];
    js_get_callback_info(env, info, &argc, argv, NULL, NULL);
    js_value_t* undef;
    js_get_undefined(env, &undef);
    if (argc < 2) return undef;

    int32_t wId = -1, eId = 0;
    js_get_value_int32(env, argv[0], &wId);
    js_get_value_int32(env, argv[1], &eId);

    if (wId < 0) {
        for (int i = 0; i < 64; i++) {
            zapp_window_set_backend_listener(i, eId, 1);
        }
    } else {
        zapp_window_set_backend_listener(wId, eId, 1);
    }
    return undef;
}

// __zappBridge.showNotification(title, body) — legacy simple shape.
// Modern code uses notif("show", { title, body, ... }) instead.
static js_value_t* bare_host_show_notification(js_env_t* env, js_callback_info_t* info) {
    size_t argc = 2;
    js_value_t* argv[2];
    js_get_callback_info(env, info, &argc, argv, NULL, NULL);
    js_value_t* undef;
    js_get_undefined(env, &undef);

    // Permission gate — same id as the modern notif() host object.
    if (!permissions_check("notifications", "Notification.show")) return undef;

    char* title = argc >= 1 ? bare_read_js_string_dup(env, argv[0]) : NULL;
    char* body  = argc >= 2 ? bare_read_js_string_dup(env, argv[1]) : NULL;
    darwin_notification_show_typed(title ? title : "", "",
                                   body ? body : "", "default");
    free(title);
    free(body);
    return undef;
}

extern bool darwin_shortcut_register(const char* a);
extern bool darwin_shortcut_unregister(const char* a);
extern bool darwin_shortcut_is_registered(const char* a);
extern void darwin_shortcut_unregister_all(void);

static js_value_t* bare_host_shortcuts(js_env_t* env, js_callback_info_t* info) {
    size_t argc = 2;
    js_value_t* argv[2];
    js_get_callback_info(env, info, &argc, argv, NULL, NULL);

    js_value_t* undef;
    js_get_undefined(env, &undef);
    if (argc < 1) return undef;

    char action[32];
    size_t alen = 0;
    js_get_value_string_utf8(env, argv[0], (utf8_t*)action, sizeof(action) - 1, &alen);
    action[alen] = '\0';

    // Permission gate — global shortcuts bypass invokeService + the router,
    // so the check lives here. Denied → undef (the fn's own miss return).
    if (!permissions_check("shortcuts", "GlobalShortcut")) return undef;

    if (strcmp(action, "unregisterAll") == 0) {
        darwin_shortcut_unregister_all();
        return undef;
    }

    js_value_t* args = argc >= 2 ? argv[1] : NULL;
    char* acc = bare_get_string_prop(env, args, "accelerator");
    bool result = false;
    if (strcmp(action, "register") == 0)
        result = darwin_shortcut_register(acc ? acc : "");
    else if (strcmp(action, "unregister") == 0)
        result = darwin_shortcut_unregister(acc ? acc : "");
    else if (strcmp(action, "isRegistered") == 0)
        result = darwin_shortcut_is_registered(acc ? acc : "");
    free(acc);

    js_value_t* out;
    js_get_boolean(env, result, &out);
    return out;
}

// --- Sync API (syncWait / syncNotify) ---
//
// We keep the Promise/resolver dance in JS-land — the dispatcher_setup
// script (below) wires `bridge.syncWait` and `bridge.syncNotify` as
// thin wrappers that:
//
//   - For syncWait: generate a request_id, create a Promise, stash the
//     resolver function in `bridge._syncPending[request_id]`, call
//     `_registerWait(id, key, timeoutMs)` to register with native.
//   - For syncNotify: call `_notifyHost(key, count)`.
//
// The host fns here are the C-side primitives — pass through to
// `darwin_sync_handle` with a properly-shaped payload. The native
// sync system already calls back into the worker via
// `darwin_sync_dispatch_to_worker(worker_id, payload)` which pushes
// JS into the worker's eval_inbox; the bootstrap's dispatchSyncResult
// looks up the resolver and invokes it.

static js_value_t* bare_host_register_wait(js_env_t* env, js_callback_info_t* info) {
    size_t argc = 3;
    js_value_t* argv[3];
    js_get_callback_info(env, info, &argc, argv, NULL, NULL);
    js_value_t* undef;
    js_get_undefined(env, &undef);
    if (argc < 2) return undef;

    char* req_id = bare_read_js_string_dup(env, argv[0]);
    char* key    = bare_read_js_string_dup(env, argv[1]);
    double timeout_ms = -1;
    if (argc >= 3) (void)js_get_value_double(env, argv[2], &timeout_ms);

    if (req_id && key) {
        // The native side expects a JSON envelope with id / key /
        // targetWorkerId / timeoutMs (the latter only when > 0).
        // Heap-allocate to avoid a fixed-size buffer truncating long
        // request IDs / keys.
        BareWorkerSlot* slot = NULL;
        // Find our slot by looking back through the function's data
        // pointer. js_create_function stores `data` per-binding; we
        // pass `slot` at creation time so this is a direct pointer.
        void* data = NULL;
        // Re-fetch via callback info — we already have it via argv setup
        // above but didn't capture data. Do it again with data param.
        size_t a2 = 0;
        js_get_callback_info(env, info, &a2, NULL, NULL, &data);
        slot = (BareWorkerSlot*)data;
        const char* worker_id = slot ? slot->worker_id : "";

        size_t need = strlen(req_id) + strlen(key) + strlen(worker_id) + 128;
        char* payload = (char*)malloc(need);
        if (timeout_ms > 0) {
            snprintf(payload, need,
                "{\"id\":\"%s\",\"key\":\"%s\",\"targetWorkerId\":\"%s\",\"timeoutMs\":%g}",
                req_id, key, worker_id, timeout_ms);
        } else {
            snprintf(payload, need,
                "{\"id\":\"%s\",\"key\":\"%s\",\"targetWorkerId\":\"%s\"}",
                req_id, key, worker_id);
        }
        darwin_sync_handle("wait", payload);
        free(payload);
    }
    free(req_id);
    free(key);
    return undef;
}

static js_value_t* bare_host_notify(js_env_t* env, js_callback_info_t* info) {
    size_t argc = 2;
    js_value_t* argv[2];
    js_get_callback_info(env, info, &argc, argv, NULL, NULL);
    js_value_t* undef;
    js_get_undefined(env, &undef);
    if (argc < 1) return undef;

    char* key = bare_read_js_string_dup(env, argv[0]);
    int32_t count = 1;
    if (argc >= 2) (void)js_get_value_int32(env, argv[1], &count);
    if (count < 1) count = 1;

    if (key && key[0]) {
        // `key` comes from JS — same JSON-escape requirement as the
        // worker-crash payload below.
        char* esc_key = bare_json_escape_dup(key);
        size_t need = (esc_key ? strlen(esc_key) : 0) + 64;
        char* payload = (char*)malloc(need);
        if (payload) {
            snprintf(payload, need, "{\"key\":\"%s\",\"count\":%d}",
                     esc_key ? esc_key : "", count);
            darwin_sync_handle("notify", payload);
            free(payload);
        }
        free(esc_key);
    }
    free(key);
    return undef;
}

// --- createWindow ---
//
// Workers can spawn windows with a single host call. We accept the
// pre-stringified opts JSON (the JS-side wrapper does `JSON.stringify`
// — same path jsc.m takes internally before calling the C side).
// Window creation must run on the main thread on macOS, so we
// dispatch_async; the worker thread blocks on a semaphore until the
// main thread fills in the result.

#ifdef __APPLE__
#include <dispatch/dispatch.h>

static js_value_t* bare_host_create_window(js_env_t* env, js_callback_info_t* info) {
    size_t argc = 1;
    js_value_t* argv[1];
    js_get_callback_info(env, info, &argc, argv, NULL, NULL);
    js_value_t* undef;
    js_get_undefined(env, &undef);
    if (argc < 1) return undef;

    // Permission gate — window creation from a worker bypasses invokeService
    // + the router (zjs falls back to invokeService("__window:create"); bare
    // has this direct host). Denied → undef (the fn's own miss return).
    if (!permissions_check("window:create", "createWindow")) return undef;

    char* opts_json = bare_read_js_string_dup(env, argv[0]);
    if (!opts_json) return undef;

    // Block the worker thread until the main-queue creation completes.
    // dispatch_sync would deadlock if we're already on main (workers
    // never are — they have their own pthread — but the guard is cheap).
    __block int window_id = -1;
    if (pthread_main_np()) {
        window_id = zapp_worker_create_window_from_json(opts_json);
    } else {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        const char* opts_capture = opts_json;
        dispatch_async(dispatch_get_main_queue(), ^{
            window_id = zapp_worker_create_window_from_json(opts_capture);
            dispatch_semaphore_signal(sem);
        });
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    }
    free(opts_json);

    // Return { windowId: "win-<n>" } — the runtime/window.ts wrapper
    // uses the string form for parity with WebView-spawned windows.
    char idbuf[32];
    snprintf(idbuf, sizeof(idbuf), "win-%d", window_id);
    js_value_t* out;
    js_create_object(env, &out);
    js_value_t* id_val;
    js_create_string_utf8(env, (const utf8_t*)idbuf, strlen(idbuf), &id_val);
    js_set_named_property(env, out, "windowId", id_val);
    return out;
}
#else
// Windows: worker-spawned windows need the main-thread funnel
// (PostMessage(WM_ZAPP_TASK) + event-wait — see WINDOWS_PORTING.md
// lesson 6), which doesn't exist yet. Undef until the M2 worker pass;
// the GCD path above is the shape to mirror.
static js_value_t* bare_host_create_window(js_env_t* env, js_callback_info_t* info) {
    (void)info;
    js_value_t* undef;
    js_get_undefined(env, &undef);
    return undef;
}
#endif

// --- bare_worker_eval_js: target a specific worker's eval_inbox ---
//
// Used by `darwin_sync_dispatch_to_worker` (sync.m) to deliver a
// `bridge.dispatchSyncResult(payload)` call to a specific bare worker.
// Same idea as bare_broadcast_eval_js but scoped to one slot.
//
// Public extern so sync.m can find it; declared in bare.h for the
// dispatcher fallback chain.
void bare_worker_eval_js(const char* worker_id, const char* js) {
    if (!worker_id || !js) return;
    pthread_mutex_lock(&bare_mutex);
    BareWorkerSlot* slot = bare_find_slot(worker_id);
    if (slot && slot->async_initialized) {
        bare_msgqueue_push(&slot->eval_inbox, js);
        uv_async_send(&slot->async);
    }
    pthread_mutex_unlock(&bare_mutex);
}

// __zappBridge.workerCrash(message, stack) — the worker bootstrap
// calls this when an uncaught error escapes a setTimeout callback or
// event handler. Dispatches `worker:crashed`, asks the supervisor for
// a verdict, and on verdict==1 sets wants_restart + bare_terminate
// (the outer reincarnation loop in bare_worker_thread handles the
// rest). On verdict==2 fires `worker:gave-up`. Same shape as
// host_worker_crash in zjs.c.
static js_value_t* bare_host_worker_crash(js_env_t* env, js_callback_info_t* info) {
    size_t argc = 2;
    js_value_t* argv[2];
    void* data = NULL;
    js_get_callback_info(env, info, &argc, argv, NULL, &data);
    BareWorkerSlot* slot = (BareWorkerSlot*)data;
    js_value_t* undef;
    js_get_undefined(env, &undef);
    if (!slot) return undef;

    char* message = argc >= 1 ? bare_read_js_string_dup(env, argv[0]) : NULL;
    char* stack   = argc >= 2 ? bare_read_js_string_dup(env, argv[1]) : NULL;

    char* esc_message = bare_json_escape_dup(message);
    char* esc_stack   = bare_json_escape_dup(stack);

    // Build the JSON payload {"id":..., "message":..., "stack":..., "incarnation":N}.
    size_t need = strlen(slot->worker_id) +
                  (esc_message ? strlen(esc_message) : 0) +
                  (esc_stack ? strlen(esc_stack) : 0) + 128;
    char* payload = (char*)malloc(need);
    if (payload) {
        snprintf(payload, need,
                 "{\"id\":\"%s\",\"message\":\"%s\",\"stack\":\"%s\",\"incarnation\":%d}",
                 slot->worker_id,
                 esc_message ? esc_message : "",
                 esc_stack ? esc_stack : "",
                 slot->incarnation);
        dispatch_event_to_all("worker:crashed", payload);
        free(payload);
    }

    int decision = zapp_worker_supervisor_record_failure(slot->worker_id);
    if (decision == 1) {
        // Restart approved. Set the atomic flag and bare_terminate to
        // break bare_run; the outer loop in bare_worker_thread sees
        // wants_restart and re-incarnates the JS state. worker:restarted
        // fires from there after setup_state completes.
        atomic_store(&slot->wants_restart, 1);
        if (slot->bare) bare_terminate(slot->bare);
    } else if (decision == 2) {
        // Supervisor cap exhausted — gave_up flag in registry is now sticky.
        char gave_up[256];
        snprintf(gave_up, sizeof(gave_up),
                 "{\"id\":\"%s\",\"finalIncarnation\":%d,\"retriesAttempted\":%d}",
                 slot->worker_id, slot->incarnation,
                 slot->incarnation > 0 ? slot->incarnation - 1 : 0);
        dispatch_event_to_all("worker:gave-up", gave_up);
    }
    // decision == 0: no policy configured; worker idles in current state.

    free(esc_message);
    free(esc_stack);
    free(message);
    free(stack);
    return undef;
}

// --- Worker thread helpers ---

typedef enum {
    BARE_SETUP_OK      = 0,
    BARE_SETUP_CRASHED = 1,
    BARE_SETUP_FATAL   = 2,
} BareSetupResult;

// Forward declarations
static BareSetupResult bare_worker_setup_state(BareWorkerSlot* slot);
static void bare_worker_teardown_state(BareWorkerSlot* slot, int keep_loop);

// Synthetic crash signal — called from setup_state when the wrapped
// js_run_script fails to eval the user script wrap (rare; usually a
// parse error in the wrap itself), or when script_source is missing
// or empty. Mirrors bare_host_worker_crash's dispatch + supervisor
// handshake without needing a live JS frame.
//
// Caller returns BARE_SETUP_CRASHED so the outer loop in
// bare_worker_thread teardown + iterates per supervisor verdict.
static void bare_setup_synthesize_crash(BareWorkerSlot* slot,
                                        const char* msg,
                                        const char* stack) {
    char* esc_message = bare_json_escape_dup(msg ? msg : "");
    char* esc_stack   = bare_json_escape_dup(stack ? stack : "");

    size_t need = strlen(slot->worker_id) +
                  (esc_message ? strlen(esc_message) : 0) +
                  (esc_stack ? strlen(esc_stack) : 0) + 128;
    char* payload = (char*)malloc(need);
    if (payload) {
        snprintf(payload, need,
                 "{\"id\":\"%s\",\"message\":\"%s\",\"stack\":\"%s\",\"incarnation\":%d}",
                 slot->worker_id,
                 esc_message ? esc_message : "",
                 esc_stack   ? esc_stack   : "",
                 slot->incarnation);
        dispatch_event_to_all("worker:crashed", payload);
        free(payload);
    }

    int decision = zapp_worker_supervisor_record_failure(slot->worker_id);
    if (decision == 1) {
        atomic_store(&slot->wants_restart, 1);
        // No bare_terminate here — we're inside setup_state, not running
        // bare_run yet. The outer while-loop in bare_worker_thread sees
        // SETUP_CRASHED return value and proceeds to teardown + iterate.
    } else if (decision == 2) {
        char gp[256];
        snprintf(gp, sizeof(gp),
                 "{\"id\":\"%s\",\"finalIncarnation\":%d,\"retriesAttempted\":%d}",
                 slot->worker_id, slot->incarnation,
                 slot->incarnation > 0 ? slot->incarnation - 1 : 0);
        dispatch_event_to_all("worker:gave-up", gp);
    }

    free(esc_message);
    free(esc_stack);
}

// bare_worker_setup_state — called from bare_worker_thread after
// uv_loop_init + slot->loop assignment. Initialises the bare runtime,
// registers all host functions on __zappBridge, evals both bootstrap
// scripts, and evals the user worker script. Returns BARE_SETUP_FATAL
// if the platform or bare_setup step fails (caller closes the loop
// directly). Returns BARE_SETUP_OK on success. BARE_SETUP_CRASHED is
// defined but not yet returned here — Task 2.5 will wire it for
// script-eval errors.
static BareSetupResult bare_worker_setup_state(BareWorkerSlot* slot) {
    int err;

    // Share a single js_platform_t across all bare workers in the
    // process. Required by V8 (which has process-wide global state and
    // aborts on second-init); harmless on libjsc / libqjs which permit
    // multiple platforms but work with one. The platform lives on its
    // own dedicated thread (see bare_platform_thread) so its uv_loop
    // doesn't compete with worker loops.
    js_platform_t* platform = bare_get_shared_platform();
    if (!platform) {
        fprintf(stderr, "[zapp/%s] shared platform unavailable\n",
            zapp_worker_registry_get_display_name(slot->worker_id));
        slot->active = false;
        return BARE_SETUP_FATAL;
    }
    slot->platform = platform;  // recorded for diagnostics; NOT owned by the slot

    bare_options_t bare_opts = {0};
    const char* argv[] = { "zapp-bare-worker", NULL };
    err = bare_setup(slot->loop, platform, &slot->env, 1, argv, &bare_opts, &slot->bare);
    if (err) {
        fprintf(stderr, "[zapp/%s] bare_setup failed (err=%d)\n",
            zapp_worker_registry_get_display_name(slot->worker_id), err);
        slot->active = false;
        return BARE_SETUP_FATAL;
    }

    // Register the uv_async_t BEFORE any host-side post can race in. Once
    // active=true is visible to other threads they may call uv_async_send
    // through bare_worker_post_message; the handle has to exist by then.
    uv_async_init(slot->loop, &slot->async, bare_on_async_message);
    slot->async.data = slot;
    slot->async_initialized = 1;

    // Register host functions on globalThis.__zappBridge. All libjs
    // value creations must happen inside an open handle scope; without
    // one JSC immediately segfaults on the first js_get_global call.
    js_handle_scope_t* scope;
    js_open_handle_scope(slot->env, &scope);

    js_value_t* global;
    js_get_global(slot->env, &global);

    js_value_t* bridge;
    js_create_object(slot->env, &bridge);

    js_value_t* log_fn;
    js_create_function(slot->env, "log", -1, bare_host_log, slot, &log_fn);
    js_set_named_property(slot->env, bridge, "log", log_fn);

    // _invokeServiceRaw — synchronous service invocation. JS-side
    // wrapper (`invokeService`) handles JSON.stringify/parse around
    // this. See dispatcher_setup script below.
    js_value_t* invoke_fn;
    js_create_function(slot->env, "_invokeServiceRaw", -1,
                       bare_host_invoke_service, slot, &invoke_fn);
    js_set_named_property(slot->env, bridge, "_invokeServiceRaw", invoke_fn);

    // listWorkers — worker-context Workers.list(). Returns the registry
    // JSON string verbatim ("[]" on alloc failure); the JS runtime wrapper
    // JSON.parses it. Same "listWorkers" property + string contract as
    // zjs.c so Workers.list() behaves identically across engines.
    js_value_t* list_workers_fn;
    js_create_function(slot->env, "listWorkers", -1,
                       bare_host_list_workers, slot, &list_workers_fn);
    js_set_named_property(slot->env, bridge, "listWorkers", list_workers_fn);

    // Worker → host plumbing. Each takes JSON-string payloads from JS
    // (the worker bootstrap stringifies before calling). Output is
    // a tiny string-marshaling layer that mirrors what jsc.m and
    // txiki.c expose — so user worker code is engine-agnostic.
    // postToWebview / postToWorker — register raw versions that take a
    // pre-stringified JSON payload. JS wrappers in dispatcher_setup do
    // JSON.stringify so user code can pass objects naturally
    // (`Events.emit("name", { ... })`, `Workers.send(id, ch, { ... })`).
    // Without the wrapper, JSC's string-coercion of objects produces
    // `"[object Object]"` and breaks the receiving side.
    js_value_t* post_webview_fn;
    js_create_function(slot->env, "_postToWebviewRaw", -1,
                       bare_host_post_to_webview, slot, &post_webview_fn);
    js_set_named_property(slot->env, bridge, "_postToWebviewRaw", post_webview_fn);

    js_value_t* post_worker_fn;
    js_create_function(slot->env, "_postToWorkerRaw", -1,
                       bare_host_post_to_worker, slot, &post_worker_fn);
    js_set_named_property(slot->env, bridge, "_postToWorkerRaw", post_worker_fn);

    // dispatchEventToAll — register as `_dispatchEventToAllRaw` (takes
    // pre-stringified JSON) and let the JS wrapper in dispatcher_setup
    // call JSON.stringify on the payload before invoking. Without the
    // wrapper, JSC's coercion of a JS object to a string via
    // js_get_value_string_utf8 produces "[object Object]" — the
    // receiving webview's _onEvent then fails to JSON.parse and the
    // payload arrives as a string, breaking object access on the
    // event data.
    js_value_t* dispatch_fn;
    js_create_function(slot->env, "_dispatchEventToAllRaw", -1,
                       bare_host_dispatch_event_to_all, slot, &dispatch_fn);
    js_set_named_property(slot->env, bridge, "_dispatchEventToAllRaw", dispatch_fn);

    js_value_t* crash_fn;
    js_create_function(slot->env, "workerCrash", -1,
                       bare_host_worker_crash, slot, &crash_fn);
    js_set_named_property(slot->env, bridge, "workerCrash", crash_fn);

    // Tier-1 host objects — clipboard / notif / shortcuts. Each is a
    // single (action, args) dispatcher that routes by string. Mirrors
    // the contract runtime/clipboard.ts / notification.ts / shortcuts.ts
    // already use against the legacy engines, so user worker code is
    // engine-agnostic.
    js_value_t* clip_fn;
    js_create_function(slot->env, "clipboard", -1,
                       bare_host_clipboard, slot, &clip_fn);
    js_set_named_property(slot->env, bridge, "clipboard", clip_fn);

    js_value_t* notif_fn;
    js_create_function(slot->env, "notif", -1,
                       bare_host_notif, slot, &notif_fn);
    js_set_named_property(slot->env, bridge, "notif", notif_fn);

    js_value_t* shortcuts_fn;
    js_create_function(slot->env, "shortcuts", -1,
                       bare_host_shortcuts, slot, &shortcuts_fn);
    js_set_named_property(slot->env, bridge, "shortcuts", shortcuts_fn);

    js_value_t* dock_fn;
    js_create_function(slot->env, "dock", -1,
                       bare_host_dock, slot, &dock_fn);
    js_set_named_property(slot->env, bridge, "dock", dock_fn);

    js_value_t* quit_fn;
    js_create_function(slot->env, "quit", -1,
                       bare_host_quit, slot, &quit_fn);
    js_set_named_property(slot->env, bridge, "quit", quit_fn);

    js_value_t* sub_fn;
    js_create_function(slot->env, "subscribeWindowEvent", -1,
                       bare_host_subscribe_window_event, slot, &sub_fn);
    js_set_named_property(slot->env, bridge, "subscribeWindowEvent", sub_fn);

    js_value_t* sn_fn;
    js_create_function(slot->env, "showNotification", -1,
                       bare_host_show_notification, slot, &sn_fn);
    js_set_named_property(slot->env, bridge, "showNotification", sn_fn);

    // Sync (wait/notify) primitives. JS-side wrappers in
    // dispatcher_setup turn these into the Promise-shaped public
    // syncWait/syncNotify API. Underscore prefixes mark them as
    // private so user code reaches for syncWait/syncNotify instead.
    js_value_t* reg_wait_fn;
    js_create_function(slot->env, "_registerWait", -1,
                       bare_host_register_wait, slot, &reg_wait_fn);
    js_set_named_property(slot->env, bridge, "_registerWait", reg_wait_fn);

    js_value_t* notify_fn;
    js_create_function(slot->env, "_notifyHost", -1,
                       bare_host_notify, slot, &notify_fn);
    js_set_named_property(slot->env, bridge, "_notifyHost", notify_fn);

    // createWindow — JS wrapper stringifies opts and passes to
    // _createWindowRaw. Returning {windowId} matches jsc.m's contract.
    js_value_t* cw_fn;
    js_create_function(slot->env, "_createWindowRaw", -1,
                       bare_host_create_window, slot, &cw_fn);
    js_set_named_property(slot->env, bridge, "_createWindowRaw", cw_fn);

    js_value_t* worker_id_str;
    js_create_string_utf8(slot->env, (utf8_t*)slot->worker_id,
        strlen(slot->worker_id), &worker_id_str);
    js_set_named_property(slot->env, bridge, "workerId", worker_id_str);

    // The worker bootstrap script expects `self` as an alias for the
    // global. Add it before running the bootstrap so `self.postMessage`
    // / `self.send` / `self.receive` install on the right object. The
    // legacy engines have this wired in their per-engine bootstrap;
    // for bare we do it here once.
    js_set_named_property(slot->env, global, "self", global);

    js_set_named_property(slot->env, global, "__zappBridge", bridge);

    // Step A — inject the build-time FS allowlist JSON onto the bridge.
    // Tiny dynamic step (~6 lines) that has to be templated against
    // the JSON; everything else lives in bootstrap/bare-worker.ts.
    //
    // Why: runtime/bare/fs.ts wraps bare-fs and consults
    // `__zappBridge.fsAllowlist` before every filesystem call. The
    // allowlist is build-time data (zapp.config.ts `fs.allow`),
    // serialized into the binary by `zapp_build_fs_allowlist_json`.
    {
        const char* fs_allowlist = zapp_build_fs_allowlist_json();
        if (!fs_allowlist) fs_allowlist = "[]";
        size_t need = strlen(fs_allowlist) + 128;
        char* buf = (char*)malloc(need);
        snprintf(buf, need,
            "(function(){var b=globalThis.__zappBridge;"
            "try{b.fsAllowlist=Object.freeze(JSON.parse(%s));}"
            "catch(e){b.fsAllowlist=[];}})();",
            fs_allowlist);
        js_value_t* src;
        js_create_string_utf8(slot->env, (const utf8_t*)buf, strlen(buf), &src);
        js_value_t* result;
        js_run_script(slot->env, "<bare-fs-allowlist>", -1, 0, src, &result);
        free(buf);
    }

    // Step B — eval the static dispatcher setup (codegen-bundled from
    // bootstrap/bare-worker.ts). Sets up _dispatchMessage, listener
    // registry, invokeService/syncWait/syncNotify/createWindow JS
    // wrappers, JSON.stringify wrappers around the dispatch/post raw
    // trampolines, and the Symbol.for('zapp.bridge') alias.
    //
    // Source: bootstrap/bare-worker.ts. Edit there, not here.
    extern const char* zapp_bare_worker_bootstrap_script(void);
    const char* bare_setup_js = zapp_bare_worker_bootstrap_script();
    if (bare_setup_js && bare_setup_js[0] != '\0') {
        js_value_t* src;
        js_create_string_utf8(slot->env, (const utf8_t*)bare_setup_js,
                              strlen(bare_setup_js), &src);
        js_value_t* result;
        int berr = js_run_script(slot->env, "<bare-worker-bootstrap>", -1, 0,
                                 src, &result);
        if (berr) {
            fprintf(stderr,
                "[zapp/%s] bare-worker-bootstrap failed (err=%d)\n",
                zapp_worker_registry_get_display_name(slot->worker_id), berr);
        }
    }

    // Run the standard Zapp worker bootstrap script — installs
    // `self.send` / `self.receive`, the channel router on
    // `_messageHandlers`, app-event dispatch, error wrapping for
    // setTimeout/setInterval, and rebinds `bridge.invoke` /
    // `bridge.emit` aliases that user code expects. Same script the
    // jsc.m and txiki.c engines run; this is the contract that makes
    // a worker script engine-agnostic.
    extern const char* zapp_worker_bootstrap_script(void);
    const char* worker_boot = zapp_worker_bootstrap_script();
    if (worker_boot && worker_boot[0] != '\0') {
        js_value_t* boot_src;
        js_create_string_utf8(slot->env, (const utf8_t*)worker_boot,
                              strlen(worker_boot), &boot_src);
        js_value_t* boot_result;
        int boot_err = js_run_script(slot->env, "<zapp-worker-bootstrap>", -1, 0,
                                     boot_src, &boot_result);
        if (boot_err) {
            fprintf(stderr,
                "[zapp/%s] bootstrap script failed (err=%d)\n",
                zapp_worker_registry_get_display_name(slot->worker_id), boot_err);
        }
    }

    js_close_handle_scope(slot->env, scope);

    if (zapp_log_level >= 1) {
        fprintf(stderr, "[zapp/%s] created\n",
            zapp_worker_registry_get_display_name(slot->worker_id));
    }

    // Run the user's worker script. We use `js_run_script` rather than
    // `bare_load` because bare-module's CJS/ESM resolver rejects our
    // tsup-bundled .mjs (it expects a fileystem-locatable URL with
    // resolution metadata). The bundled worker source is plain JS that
    // runs at top level — `js_run_script` evaluates it directly,
    // installs the user's `receive(...)` listeners, etc.
    //
    // Once T1.6 (CLI install + cmake-link of bare modules) lands,
    // user worker code that does `import 'bare-fetch'` will resolve
    // through bare's module loader. Until then, the bundler resolves
    // imports at build time and the bundle is self-contained.
    if (slot->script_source && slot->script_len > 0) {
        js_handle_scope_t* run_scope;
        js_open_handle_scope(slot->env, &run_scope);

        // Wrap the user script in:
        //   1. an IIFE so each worker's top-level declarations stay
        //      local (avoids `let`-redeclare conflicts when the env
        //      is reused across restarts; bare reuses the env, jsc.m
        //      doesn't).
        //   2. a JS-side try/catch that delegates any uncaught error
        //      to `__zappBridge._handleUserScriptError(e)`. Without
        //      this, js_run_script returns an opaque `err=-2` and the
        //      real error message is invisible to both stderr and the
        //      `worker:crashed` event flow. Bare's runtime
        //      `onuncaughtexception` ONLY fires for errors raised from
        //      libuv-driven async callbacks; top-level eval failures
        //      take a different path that we have to report manually.
        //
        // The full reporting logic (bridge.log + bridge.workerCrash +
        // console.error fallback) lives in bootstrap/bare-worker.ts as
        // `_handleUserScriptError` — keeping JS in TS so it gets full
        // editor tooling and code review (see
        // feedback_js_in_ts_files.md).
        const char* wrap_prefix =
            "(function(){ try {\n";
        const char* wrap_suffix =
            "\n} catch (e) {\n"
            "  globalThis.__zappBridge._handleUserScriptError(e);\n"
            "} })();";
        size_t wrapped_len = strlen(wrap_prefix) + (size_t)slot->script_len +
                             strlen(wrap_suffix) + 1;
        char* wrapped = (char*)malloc(wrapped_len);
        snprintf(wrapped, wrapped_len, "%s%s%s",
                 wrap_prefix, slot->script_source, wrap_suffix);

        js_value_t* src;
        js_create_string_utf8(slot->env, (utf8_t*)wrapped,
                              strlen(wrapped), &src);
        js_value_t* run_result;
        int run_err = js_run_script(slot->env, slot->script_url, -1, 0, src, &run_result);
        if (run_err) {
            // Should be rare now — the JS-side try/catch swallows most
            // user-script errors. If we still see this, the wrap
            // itself is malformed (parse error in our generated JS,
            // not in user code).
            fprintf(stderr,
                "[zapp/%s] wrapper eval failed (err=%d) — generated wrap may be malformed\n",
                zapp_worker_registry_get_display_name(slot->worker_id), run_err);
        }
        free(wrapped);
        js_close_handle_scope(slot->env, run_scope);

        if (run_err) {
            bare_setup_synthesize_crash(slot, "script wrap eval failed", "");
            return BARE_SETUP_CRASHED;
        }
    } else {
        fprintf(stderr, "[zapp/%s] missing script source\n",
                zapp_worker_registry_get_display_name(slot->worker_id));
        bare_setup_synthesize_crash(slot, "script load failed", "");
        return BARE_SETUP_CRASHED;
    }

    return BARE_SETUP_OK;
}

// bare_worker_teardown_state — tears down the bare runtime, async
// handle, message queues, and slot fields. If keep_loop is non-zero,
// skips uv_loop_close (used when the caller intends to re-init the
// loop for a restart; Task 2.3 will use this). The final "exited" log
// line is emitted here so it always appears regardless of call site.
static void bare_worker_teardown_state(BareWorkerSlot* slot, int keep_loop) {
    int exit_code = 0;
    bare_teardown(slot->bare, UV_RUN_NOWAIT, &exit_code);
    if (slot->async_initialized) {
        uv_close((uv_handle_t*)&slot->async, NULL);
        slot->async_initialized = 0;
    }
    // Drain close callbacks before the next incarnation init's a fresh
    // handle on the same loop. Without this, libuv sees a still-closing
    // slot->async on the next uv_async_init (UB), and bare_run on the
    // next iteration drains the stale closing handles itself → loop
    // empties → bare_run returns immediately. Mirrors zjs's teardown.
    uv_run(slot->loop, UV_RUN_NOWAIT);
    // The platform is process-wide (see bare_get_shared_platform). We
    // recorded a pointer for diagnostics but DO NOT own it — never
    // call js_destroy_platform from the worker thread.
    if (!keep_loop) {
        uv_loop_close(slot->loop);
    }

    if (!keep_loop) {
        bare_msgqueue_destroy(&slot->inbox);
        bare_msgqueue_destroy(&slot->eval_inbox);
        free(slot->script_source);
        slot->script_source = NULL;
    }

    slot->bare = NULL;
    slot->env = NULL;
    slot->platform = NULL;
    slot->loop = NULL;
    slot->active = false;

    if (zapp_log_level >= 1) {
        fprintf(stderr, "[zapp/%s] exited (code=%d)\n",
            zapp_worker_registry_get_display_name(slot->worker_id), exit_code);
    }
}

// --- Worker thread entry ---

static void* bare_worker_thread(void* data) {
    BareWorkerSlot* slot = (BareWorkerSlot*)data;

    uv_loop_t loop;
    int err = uv_loop_init(&loop);
    if (err) {
        fprintf(stderr, "[zapp/%s] uv_loop_init failed: %s\n",
                zapp_worker_registry_get_display_name(slot->worker_id), uv_strerror(err));
        slot->active = false;
        return NULL;
    }
    slot->loop = &loop;
    slot->incarnation = 0;

    while (1) {
        slot->incarnation++;
        slot->active = true;

        // teardown_state(keep_loop=1) nulls slot->loop to protect against
        // stale access; re-arm it at the top of each iteration so that
        // setup_state and bare_run always see a live pointer.
        slot->loop = &loop;

        BareSetupResult setup = bare_worker_setup_state(slot);

        if (setup == BARE_SETUP_FATAL) {
            fprintf(stderr, "[zapp/%s] setup fatal (incarnation %d)\n",
                    zapp_worker_registry_get_display_name(slot->worker_id), slot->incarnation);
            break;
        }

        if (setup == BARE_SETUP_CRASHED) {
            // host_worker_crash already fired; wants_restart set per
            // supervisor verdict. Skip bare_run — nothing live to run.
            // (No path returns CRASHED yet — Task 2.5 adds it.)
            bare_worker_teardown_state(slot, /*keep_loop=*/1);
        } else {
            // BARE_SETUP_OK
            if (slot->incarnation > 1) {
                char payload[128];
                snprintf(payload, sizeof(payload),
                         "{\"id\":\"%s\",\"incarnation\":%d}",
                         slot->worker_id, slot->incarnation);
                dispatch_event_to_all("worker:restarted", payload);
                int fc = 0, cap = 0, win = 0;
                zapp_worker_supervisor_get_window_state(slot->worker_id, &fc, &cap, &win);
                fprintf(stderr, "[zapp/%s] restart %d (fail %d/%d in %s)\n",
                        zapp_worker_registry_get_display_name(slot->worker_id),
                        slot->incarnation, fc, cap, zapp_fmt_compact_ms(win));
            }

            bare_run(slot->bare, UV_RUN_DEFAULT);

            bare_worker_teardown_state(slot, /*keep_loop=*/1);
        }

        if (atomic_load(&slot->wants_terminate)) break;
        if (!atomic_load(&slot->wants_restart)) break;
        atomic_store(&slot->wants_restart, 0);
    }

    // Final cleanup — close the loop now that we're really exiting.
    uv_run(&loop, UV_RUN_NOWAIT);
    uv_loop_close(&loop);
    bare_msgqueue_destroy(&slot->inbox);
    bare_msgqueue_destroy(&slot->eval_inbox);
    free(slot->script_source);
    slot->script_source = NULL;
    slot->active = false;
    return NULL;
}

// --- Public API ---

bool bare_worker_create(const char* script_url, const char* owner_id, const char* worker_id) {
    if (!script_url || !worker_id) return false;

    pthread_mutex_lock(&bare_mutex);
    BareWorkerSlot* slot = NULL;
    for (int i = 0; i < BARE_MAX_WORKERS; i++) {
        if (!bare_workers[i].active) {
            slot = &bare_workers[i];
            break;
        }
    }
    if (!slot) {
        pthread_mutex_unlock(&bare_mutex);
        fprintf(stderr, "[zapp] bare worker create: slot table full\n");
        return false;
    }

    memset(slot, 0, sizeof(*slot));
    strncpy(slot->worker_id, worker_id, sizeof(slot->worker_id) - 1);
    strncpy(slot->owner_id, owner_id ? owner_id : "", sizeof(slot->owner_id) - 1);
    strncpy(slot->script_url, script_url, sizeof(slot->script_url) - 1);
    bare_msgqueue_init(&slot->inbox);
    bare_msgqueue_init(&slot->eval_inbox);
    slot->active = true;
    pthread_mutex_unlock(&bare_mutex);

    // Load the script source on the calling thread (the embedded
    // assets table + the iOS NSURLSession helper are both safe
    // off-main; doing it here keeps the worker thread focused on JS).
    int script_len = 0;
    char* script_source = bare_load_script(script_url, &script_len);
    if (!script_source) {
        slot->active = false;
        return false;
    }
    slot->script_source = script_source;
    slot->script_len = script_len;

    int err = pthread_create(&slot->thread, NULL, bare_worker_thread, slot);
    if (err) {
        fprintf(stderr, "[zapp/%s] pthread_create failed (err=%d)\n",
            zapp_worker_registry_get_display_name(slot->worker_id), err);
        free(slot->script_source);
        slot->script_source = NULL;
        slot->active = false;
        return false;
    }
    pthread_detach(slot->thread);
    return true;
}

void bare_worker_post_message(const char* worker_id, const char* data_json) {
    if (!worker_id || !data_json) return;
    pthread_mutex_lock(&bare_mutex);
    BareWorkerSlot* slot = bare_find_slot(worker_id);
    if (!slot || !slot->active || !slot->async_initialized || !slot->bare) {
        fprintf(stderr, "[zapp/%s] message dropped (not ready; incarnation %d)\n",
                zapp_worker_registry_get_display_name(worker_id),
                slot ? slot->incarnation : 0);
        pthread_mutex_unlock(&bare_mutex);
        return;
    }
    bare_msgqueue_push(&slot->inbox, data_json);
    uv_async_send(&slot->async);
    pthread_mutex_unlock(&bare_mutex);
}

// Broadcast a raw JS string to every active bare worker. Called from
// dispatch.zc:dispatch_event_to_workers and app_events.zc app-event
// fan-out. Each worker drains its eval_inbox on the next async tick.
void bare_broadcast_eval_js(const char* js) {
    if (!js) return;
    pthread_mutex_lock(&bare_mutex);
    for (int i = 0; i < BARE_MAX_WORKERS; i++) {
        BareWorkerSlot* slot = &bare_workers[i];
        if (!slot->active || !slot->async_initialized) continue;
        bare_msgqueue_push(&slot->eval_inbox, js);
        uv_async_send(&slot->async);
    }
    pthread_mutex_unlock(&bare_mutex);
}

void bare_worker_terminate(const char* worker_id) {
    pthread_mutex_lock(&bare_mutex);
    BareWorkerSlot* slot = bare_find_slot(worker_id);
    if (slot) {
        atomic_store(&slot->wants_terminate, 1);
        if (slot->bare) {
            bare_terminate(slot->bare);  // signals bare_run to return; thread cleans up
        }
    }
    pthread_mutex_unlock(&bare_mutex);
}

void bare_worker_terminate_owner(const char* owner_id) {
    if (!owner_id) return;
    pthread_mutex_lock(&bare_mutex);
    for (int i = 0; i < BARE_MAX_WORKERS; i++) {
        if (bare_workers[i].active &&
            strcmp(bare_workers[i].owner_id, owner_id) == 0) {
            atomic_store(&bare_workers[i].wants_terminate, 1);
            if (bare_workers[i].bare) {
                bare_terminate(bare_workers[i].bare);
            }
        }
    }
    pthread_mutex_unlock(&bare_mutex);
}

#endif // ZAPP_WORKER_ENGINE_BARE_*
