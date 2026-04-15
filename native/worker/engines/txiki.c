// txiki.js worker engine — pure C implementation.
// Each worker gets a TJSRuntime on its own thread with libuv event loop.
// Message passing uses uv_async_t to safely wake the worker thread.

#include "txiki.h"
#include "tjs.h"
#include "quickjs.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/stat.h>
#include <pthread.h>
#include <time.h>
#include <uv.h>
#include <compression.h>

// Platform-specific APIs used for privileged host objects (createWindow,
// quit, notif, dock). Darwin uses GCD; Windows will need its own path via
// thread hops / platform APIs when txiki gains Windows support.
#ifdef __APPLE__
#include <dispatch/dispatch.h>
#endif

// txiki.js private API — needed for TJS_GetLoop and TJS_NewRuntimeWorker
extern uv_loop_t* TJS_GetLoop(TJSRuntime* qrt);
extern TJSRuntime* TJS_NewRuntimeWorker(void);
// Required so the libwebsockets layer doesn't assert on first WebSocket use.
// Embedder helper added to vendor/txiki.js/src/vm.c.
extern void TJS_SetCookieJarPath(TJSRuntime* qrt, const char* path);

// Embedded asset struct — defined in zapp_assets.zc, accessed via extern below.
// We mirror the layout here because the ZAPP_EMBEDDED_ASSET_DEFINED macro
// is local to the zapp_assets translation unit and isn't visible across files.
typedef struct {
    const char* path;
    uint8_t* data;
    int len;
    int uncompressed_len;
    int is_brotli;
} ZappEmbeddedAsset;

// --- Message queue (thread-safe) ---

#define MSG_QUEUE_MAX 256

typedef struct {
    char* messages[MSG_QUEUE_MAX];
    int head;
    int tail;
    int count;
    pthread_mutex_t mutex;
} MsgQueue;

static void msgqueue_init(MsgQueue* q) {
    memset(q, 0, sizeof(MsgQueue));
    pthread_mutex_init(&q->mutex, NULL);
}

static int msgqueue_push(MsgQueue* q, const char* msg) {
    pthread_mutex_lock(&q->mutex);
    if (q->count >= MSG_QUEUE_MAX) {
        pthread_mutex_unlock(&q->mutex);
        return -1;
    }
    q->messages[q->tail] = strdup(msg);
    q->tail = (q->tail + 1) % MSG_QUEUE_MAX;
    q->count++;
    pthread_mutex_unlock(&q->mutex);
    return 0;
}

static char* msgqueue_pop(MsgQueue* q) {
    pthread_mutex_lock(&q->mutex);
    if (q->count == 0) {
        pthread_mutex_unlock(&q->mutex);
        return NULL;
    }
    char* msg = q->messages[q->head];
    q->messages[q->head] = NULL;
    q->head = (q->head + 1) % MSG_QUEUE_MAX;
    q->count--;
    pthread_mutex_unlock(&q->mutex);
    return msg;
}

static void msgqueue_destroy(MsgQueue* q) {
    pthread_mutex_lock(&q->mutex);
    for (int i = 0; i < MSG_QUEUE_MAX; i++) {
        free(q->messages[i]);
        q->messages[i] = NULL;
    }
    q->count = 0;
    pthread_mutex_unlock(&q->mutex);
    pthread_mutex_destroy(&q->mutex);
}

// --- Worker storage ---

#define TXIKI_MAX_WORKERS 64

typedef struct {
    char worker_id[64];
    char owner_id[64];
    char script_url[256];
    int active;
    TJSRuntime* runtime;
    JSContext* ctx;
    pthread_t thread;
    uv_async_t async;       // Wakes worker thread for incoming messages
    MsgQueue inbox;          // Thread-safe message queue (regular messages)
    MsgQueue sync_inbox;     // Thread-safe queue for Sync.wait results
    int async_initialized;
} TxikiWorkerSlot;

static TxikiWorkerSlot txiki_workers[TXIKI_MAX_WORKERS] = {{0}};
static pthread_mutex_t txiki_mutex = PTHREAD_MUTEX_INITIALIZER;

static TxikiWorkerSlot* txiki_find_slot(const char* worker_id) {
    for (int i = 0; i < TXIKI_MAX_WORKERS; i++) {
        if (txiki_workers[i].active && strcmp(txiki_workers[i].worker_id, worker_id) == 0) {
            return &txiki_workers[i];
        }
    }
    return NULL;
}

// --- Forward declarations ---
extern void* app_get_active(void);
extern const char* service_invoke_sync(void* app, const char* method, const char* args);
extern bool app_get_bootstrap_web_content_inspectable(void);

// --- Zen-C JsonValue construction (declared in std/json.zc + json_builder.zc) ---
// JsonValue is opaque to this translation unit; we only manipulate it via
// pointers. The _ptr constructors return heap-allocated nodes; our own
// json_object_set_owned / json_array_push_owned helpers transfer ownership
// without the extra malloc that std/json.zc's set/push would do.
typedef struct JsonValue JsonValue;
extern JsonValue* JsonValue__null_ptr(void);
extern JsonValue* JsonValue__bool_ptr(bool b);
extern JsonValue* JsonValue__number_ptr(double n);
extern JsonValue* JsonValue__string_ptr(char* s);
extern JsonValue* JsonValue__array_ptr(void);
extern JsonValue* JsonValue__object_ptr(void);
extern void json_object_set_owned(JsonValue* obj, char* key, JsonValue* val);
extern void json_array_push_owned(JsonValue* arr, JsonValue* val);
extern void json_free_tree(JsonValue* v);
extern const char* service_invoke_native(void* app, const char* method, JsonValue* args);

// Walk a QuickJS JSValue and build a Zen-C JsonValue tree directly.
// Returns a heap-allocated tree; caller frees via json_free_tree().
static JsonValue* jsvalue_to_jsonvalue(JSContext* ctx, JSValueConst v) {
    if (JS_IsUndefined(v) || JS_IsNull(v)) {
        return JsonValue__null_ptr();
    }
    if (JS_IsBool(v)) {
        return JsonValue__bool_ptr(JS_ToBool(ctx, v) ? true : false);
    }
    if (JS_IsNumber(v)) {
        double n = 0;
        JS_ToFloat64(ctx, &n, v);
        return JsonValue__number_ptr(n);
    }
    if (JS_IsString(v)) {
        const char* s = JS_ToCString(ctx, v);
        JsonValue* jv = JsonValue__string_ptr((char*)(s ? s : ""));
        if (s) JS_FreeCString(ctx, s);
        return jv;
    }
    if (JS_IsArray(v)) {
        JsonValue* arr = JsonValue__array_ptr();
        JSValue len_val = JS_GetPropertyStr(ctx, v, "length");
        uint32_t len = 0;
        JS_ToUint32(ctx, &len, len_val);
        JS_FreeValue(ctx, len_val);
        for (uint32_t i = 0; i < len; i++) {
            JSValue elem = JS_GetPropertyUint32(ctx, v, i);
            JsonValue* child = jsvalue_to_jsonvalue(ctx, elem);
            JS_FreeValue(ctx, elem);
            json_array_push_owned(arr, child);
        }
        return arr;
    }
    if (JS_IsObject(v)) {
        JsonValue* obj = JsonValue__object_ptr();
        JSPropertyEnum* tab = NULL;
        uint32_t len = 0;
        if (JS_GetOwnPropertyNames(ctx, &tab, &len, v, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) == 0) {
            for (uint32_t i = 0; i < len; i++) {
                const char* key = JS_AtomToCString(ctx, tab[i].atom);
                JSValue prop = JS_GetProperty(ctx, v, tab[i].atom);
                JsonValue* child = jsvalue_to_jsonvalue(ctx, prop);
                json_object_set_owned(obj, (char*)(key ? key : ""), child);
                if (key) JS_FreeCString(ctx, key);
                JS_FreeValue(ctx, prop);
            }
            JS_FreePropertyEnum(ctx, tab, len);
        }
        return obj;
    }
    // Anything else (function, symbol) — coerce to null.
    return JsonValue__null_ptr();
}

// --- Host objects (same as before) ---

static JSValue zapp_bridge_invoke_service(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    const char* method = JS_ToCString(ctx, argv[0]);
    if (!method) return JS_UNDEFINED;

    // Zero-JSON path: walk JS args directly into a JsonValue tree (no
    // JSON.stringify + JSON.parse round-trip). One tree walk instead of two.
    JsonValue* args_jv = NULL;
    if (argc >= 2 && !JS_IsUndefined(argv[1]) && !JS_IsNull(argv[1])) {
        args_jv = jsvalue_to_jsonvalue(ctx, argv[1]);
    }

    void* app = app_get_active();
    const char* svc_result = app ? service_invoke_native(app, method, args_jv) : NULL;
    JS_FreeCString(ctx, method);
    if (args_jv) json_free_tree(args_jv);

    if (!svc_result || svc_result[0] == '\0') return JS_UNDEFINED;
    JSValue parsed = JS_ParseJSON(ctx, svc_result, strlen(svc_result), "<service>");
    if (JS_IsException(parsed)) return JS_NewString(ctx, svc_result);
    return parsed;
}

// Per-worker cached state, looked up once at setup by worker_id and reused
// on every host object call. Indexed by a __zapp_ctx_id hidden property set
// on the context's TJSRuntime during bridge setup.
typedef struct {
    char worker_id[64];
} TxikiBridgeCache;

// Hash map keyed by JSContext* → TxikiBridgeCache*. Workers are created rarely
// (once per new Worker()) so the linear scan is fine. Bounded by TXIKI_MAX_WORKERS.
static TxikiBridgeCache txiki_bridge_caches[TXIKI_MAX_WORKERS + 1] = {{{0}}};
static JSContext* txiki_bridge_ctxs[TXIKI_MAX_WORKERS + 1] = {0};

static TxikiBridgeCache* txiki_bridge_cache_for(JSContext* ctx) {
    for (int i = 0; i < TXIKI_MAX_WORKERS + 1; i++) {
        if (txiki_bridge_ctxs[i] == ctx) return &txiki_bridge_caches[i];
    }
    return NULL;
}

static void txiki_bridge_cache_register(JSContext* ctx, const char* worker_id) {
    for (int i = 0; i < TXIKI_MAX_WORKERS + 1; i++) {
        if (txiki_bridge_ctxs[i] == NULL) {
            txiki_bridge_ctxs[i] = ctx;
            strncpy(txiki_bridge_caches[i].worker_id, worker_id, 63);
            txiki_bridge_caches[i].worker_id[63] = '\0';
            return;
        }
    }
}

static void txiki_bridge_cache_release(JSContext* ctx) {
    for (int i = 0; i < TXIKI_MAX_WORKERS + 1; i++) {
        if (txiki_bridge_ctxs[i] == ctx) {
            txiki_bridge_ctxs[i] = NULL;
            txiki_bridge_caches[i].worker_id[0] = '\0';
            return;
        }
    }
}

// --- Sync pending resolvers (per-worker) ---
//
// Sync.wait returns a Promise. The resolver is stored here (keyed by the
// request_id sent to darwin_sync_handle) until the result arrives and is
// dispatched back into the worker via sync_inbox + uv_async.
//
// Access is single-threaded: only the worker thread that owns `ctx` touches
// its own entries. Register/lookup/release all happen on the worker thread.

#define TXIKI_MAX_PENDING_SYNCS 128

typedef struct {
    int active;
    char request_id[128];
    JSContext* ctx;        // context that owns the resolver
    JSValue resolver;      // JS function ref (strong ref, JS_DupValue'd)
} TxikiSyncPending;

static TxikiSyncPending txiki_sync_pending[TXIKI_MAX_PENDING_SYNCS] = {{0}};
static pthread_mutex_t txiki_sync_pending_mutex = PTHREAD_MUTEX_INITIALIZER;

static void txiki_sync_pending_add(const char* request_id, JSContext* ctx, JSValue resolver) {
    pthread_mutex_lock(&txiki_sync_pending_mutex);
    for (int i = 0; i < TXIKI_MAX_PENDING_SYNCS; i++) {
        if (!txiki_sync_pending[i].active) {
            txiki_sync_pending[i].active = 1;
            strncpy(txiki_sync_pending[i].request_id, request_id, sizeof(txiki_sync_pending[i].request_id) - 1);
            txiki_sync_pending[i].request_id[sizeof(txiki_sync_pending[i].request_id) - 1] = '\0';
            txiki_sync_pending[i].ctx = ctx;
            txiki_sync_pending[i].resolver = resolver;
            pthread_mutex_unlock(&txiki_sync_pending_mutex);
            return;
        }
    }
    pthread_mutex_unlock(&txiki_sync_pending_mutex);
    // Table full — leak the resolver ref. Should never happen in practice.
    JS_FreeValue(ctx, resolver);
}

// Find and remove a pending entry. Returns the resolver on success (caller
// owns the strong ref and must JS_FreeValue after use).
static int txiki_sync_pending_take(const char* request_id, JSContext** out_ctx, JSValue* out_resolver) {
    pthread_mutex_lock(&txiki_sync_pending_mutex);
    for (int i = 0; i < TXIKI_MAX_PENDING_SYNCS; i++) {
        if (txiki_sync_pending[i].active &&
            strcmp(txiki_sync_pending[i].request_id, request_id) == 0) {
            *out_ctx = txiki_sync_pending[i].ctx;
            *out_resolver = txiki_sync_pending[i].resolver;
            txiki_sync_pending[i].active = 0;
            txiki_sync_pending[i].request_id[0] = '\0';
            txiki_sync_pending[i].ctx = NULL;
            pthread_mutex_unlock(&txiki_sync_pending_mutex);
            return 1;
        }
    }
    pthread_mutex_unlock(&txiki_sync_pending_mutex);
    return 0;
}

// Release any entries owned by `ctx` (called on worker teardown).
static void txiki_sync_pending_release_ctx(JSContext* ctx) {
    pthread_mutex_lock(&txiki_sync_pending_mutex);
    for (int i = 0; i < TXIKI_MAX_PENDING_SYNCS; i++) {
        if (txiki_sync_pending[i].active && txiki_sync_pending[i].ctx == ctx) {
            JS_FreeValue(ctx, txiki_sync_pending[i].resolver);
            txiki_sync_pending[i].active = 0;
            txiki_sync_pending[i].request_id[0] = '\0';
            txiki_sync_pending[i].ctx = NULL;
        }
    }
    pthread_mutex_unlock(&txiki_sync_pending_mutex);
}

static JSValue zapp_bridge_post_to_webview(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;

    // Cached worker_id — no per-call globalThis lookup.
    TxikiBridgeCache* cache = txiki_bridge_cache_for(ctx);
    if (!cache || cache->worker_id[0] == '\0') return JS_UNDEFINED;

    // Direct C JSON.stringify — no four-property lookup dance.
    JSValue json_val = JS_JSONStringify(ctx, argv[0], JS_UNDEFINED, JS_UNDEFINED);
    if (!JS_IsException(json_val)) {
        const char* json = JS_ToCString(ctx, json_val);
        if (json) {
            worker_dispatch_to_webview(cache->worker_id, (char*)json);
            JS_FreeCString(ctx, json);
        }
    }
    JS_FreeValue(ctx, json_val);
    return JS_UNDEFINED;
}

// --- Sync.wait / Sync.notify host objects ---

extern void darwin_sync_handle(const char* action, const char* payload_json);

static JSValue zapp_bridge_sync_wait(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;

    const char* key = JS_ToCString(ctx, argv[0]);
    if (!key) return JS_UNDEFINED;

    double timeout_ms = -1;
    if (argc >= 2 && !JS_IsUndefined(argv[1]) && !JS_IsNull(argv[1])) {
        JS_ToFloat64(ctx, &timeout_ms, argv[1]);
    }

    TxikiBridgeCache* cache = txiki_bridge_cache_for(ctx);
    const char* wid = (cache && cache->worker_id[0]) ? cache->worker_id : "__unknown__";

    // Generate a unique request_id scoped to the worker.
    static int zapp_sync_counter = 0;
    int seq = __atomic_add_fetch(&zapp_sync_counter, 1, __ATOMIC_SEQ_CST);
    char request_id[128];
    snprintf(request_id, sizeof(request_id), "%s:sync-%d-%u", wid, seq, arc4random());

    // Build payload for darwin_sync_handle
    char payload[512];
    if (timeout_ms > 0) {
        snprintf(payload, sizeof(payload),
            "{\"id\":\"%s\",\"key\":\"%s\",\"targetWorkerId\":\"%s\",\"timeoutMs\":%d}",
            request_id, key, wid, (int)timeout_ms);
    } else {
        snprintf(payload, sizeof(payload),
            "{\"id\":\"%s\",\"key\":\"%s\",\"targetWorkerId\":\"%s\"}",
            request_id, key, wid);
    }
    JS_FreeCString(ctx, key);

    // Create the promise and store the resolver.
    JSValue resolving_funcs[2];
    JSValue promise = JS_NewPromiseCapability(ctx, resolving_funcs);
    if (JS_IsException(promise)) {
        return JS_UNDEFINED;
    }
    // Keep the resolve fn; drop the reject fn (we always resolve with a status).
    txiki_sync_pending_add(request_id, ctx, resolving_funcs[0]);
    JS_FreeValue(ctx, resolving_funcs[1]);

    // Register with the native sync handler. darwin_sync_handle is
    // thread-safe (pthread_mutex), so we call it directly from the worker
    // thread with no main-queue bounce.
    darwin_sync_handle("wait", payload);

    return promise;
}

static JSValue zapp_bridge_sync_notify(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;

    const char* key = JS_ToCString(ctx, argv[0]);
    if (!key) return JS_UNDEFINED;

    int count = 1;
    if (argc >= 2 && !JS_IsUndefined(argv[1]) && !JS_IsNull(argv[1])) {
        int32_t c = 1;
        JS_ToInt32(ctx, &c, argv[1]);
        if (c >= 1) count = c;
    }

    char payload[256];
    snprintf(payload, sizeof(payload), "{\"key\":\"%s\",\"count\":%d}", key, count);
    JS_FreeCString(ctx, key);

    darwin_sync_handle("notify", payload);
    return JS_UNDEFINED;
}

// Forward decl — defined later in the backend section.
extern TxikiWorkerSlot txiki_backend;
extern int txiki_backend_running;

// Called by darwin_sync_dispatch_to_worker from whatever thread the match
// happened on. We push the payload to the target worker's sync_inbox and
// signal its uv_async so it drains on the worker thread.
//
// Returns 1 if the worker was found and the message queued; 0 otherwise.
int txiki_worker_dispatch_sync_result(const char* worker_id, const char* payload_json) {
    if (!worker_id || !payload_json) return 0;

    // Special case: __backend__ has its own slot outside the workers array.
    if (strcmp(worker_id, "__backend__") == 0) {
        if (!txiki_backend_running || !txiki_backend.async_initialized) return 0;
        msgqueue_push(&txiki_backend.sync_inbox, payload_json);
        uv_async_send(&txiki_backend.async);
        return 1;
    }

    pthread_mutex_lock(&txiki_mutex);
    TxikiWorkerSlot* slot = txiki_find_slot(worker_id);
    if (!slot || !slot->async_initialized) {
        pthread_mutex_unlock(&txiki_mutex);
        return 0;
    }
    msgqueue_push(&slot->sync_inbox, payload_json);
    uv_async_send(&slot->async);
    pthread_mutex_unlock(&txiki_mutex);
    return 1;
}

// Extract a string field from a flat JSON payload like {"id":"foo","status":"notified"}.
// Writes up to out_size-1 chars plus a null terminator. Returns 1 on success.
static int zapp_extract_json_str(const char* payload, const char* field, char* out, size_t out_size) {
    if (!payload || !field || !out || out_size < 2) return 0;
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", field);
    const char* p = strstr(payload, pattern);
    if (!p) return 0;
    p += strlen(pattern);
    size_t i = 0;
    while (*p && *p != '"' && i < out_size - 1) {
        if (*p == '\\' && p[1]) { p++; }
        out[i++] = *p++;
    }
    out[i] = '\0';
    return 1;
}

// Broadcast a fire-and-forget event to every webview. Used by the backend
// to push state changes to all open windows; workers can use it the same way.
// Calls into the existing Zen-C dispatch_event_to_all which builds the JS
// every webview's bridge._onEvent listener picks up.
extern void dispatch_event_to_all(const char* event_name, const char* payload);

static JSValue zapp_bridge_emit_to_host(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;

    const char* name = JS_ToCString(ctx, argv[0]);
    if (!name) return JS_UNDEFINED;

    // Direct C JSON.stringify — no property-lookup dance.
    const char* payload_json = "{}";
    char* payload_str = NULL;
    JSValue json_val = JS_UNDEFINED;
    if (argc >= 2 && !JS_IsUndefined(argv[1]) && !JS_IsNull(argv[1])) {
        json_val = JS_JSONStringify(ctx, argv[1], JS_UNDEFINED, JS_UNDEFINED);
        if (!JS_IsException(json_val)) {
            payload_str = (char*)JS_ToCString(ctx, json_val);
            if (payload_str) payload_json = payload_str;
        }
    }

    dispatch_event_to_all(name, payload_json);

    JS_FreeCString(ctx, name);
    if (payload_str) JS_FreeCString(ctx, payload_str);
    JS_FreeValue(ctx, json_val);
    return JS_UNDEFINED;
}

// --- Privileged host objects: parity with JSC ---

// createWindow(opts) — sync window creation from any worker.
// Threading: window creation must happen on the main thread. Worker threads
// call dispatch_sync(main) to hop over, but guard against the deadlock when
// the caller is already on main (e.g. via a setTimeout-dispatched callback
// that the JSC engine routes to main — txiki workers run on their own thread
// so this guard is belt-and-suspenders).
extern int zapp_worker_create_window(const char* title, const char* url, int width, int height);

static JSValue zapp_bridge_create_window(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    const char* title = "Window";
    const char* url = "";
    int width = 0, height = 0;
    JSValue title_val = JS_UNDEFINED;
    JSValue url_val = JS_UNDEFINED;

    if (argc >= 1 && JS_IsObject(argv[0])) {
        title_val = JS_GetPropertyStr(ctx, argv[0], "title");
        if (JS_IsString(title_val)) title = JS_ToCString(ctx, title_val);
        url_val = JS_GetPropertyStr(ctx, argv[0], "url");
        if (JS_IsString(url_val)) url = JS_ToCString(ctx, url_val);
        JSValue w_val = JS_GetPropertyStr(ctx, argv[0], "width");
        if (JS_IsNumber(w_val)) { int32_t w = 0; JS_ToInt32(ctx, &w, w_val); width = w; }
        JS_FreeValue(ctx, w_val);
        JSValue h_val = JS_GetPropertyStr(ctx, argv[0], "height");
        if (JS_IsNumber(h_val)) { int32_t h = 0; JS_ToInt32(ctx, &h, h_val); height = h; }
        JS_FreeValue(ctx, h_val);
    }

    int window_id = -1;
    const char* titleC = title ? title : "";
    const char* urlC = url ? url : "";
#ifdef __APPLE__
    // txiki workers always run on their own thread (uv_loop), never the main
    // queue — so dispatch_sync(main) is always safe here (no deadlock risk).
    __block int wid_out = -1;
    __block const char* tC = titleC;
    __block const char* uC = urlC;
    __block int w = width;
    __block int h = height;
    dispatch_sync(dispatch_get_main_queue(), ^{
        wid_out = zapp_worker_create_window(tC, uC, w, h);
    });
    window_id = wid_out;
#else
    // TODO(windows): route window creation through the platform's main-thread
    // hop (PostMessage + WaitForSingleObject or equivalent) when txiki gains
    // Windows support.
    window_id = zapp_worker_create_window(titleC, urlC, width, height);
#endif

    if (title && JS_IsString(title_val)) JS_FreeCString(ctx, title);
    if (url && JS_IsString(url_val)) JS_FreeCString(ctx, url);
    JS_FreeValue(ctx, title_val);
    JS_FreeValue(ctx, url_val);

    char wid[32];
    snprintf(wid, sizeof(wid), "win-%d", window_id);
    JSValue result = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, result, "windowId", JS_NewString(ctx, wid));
    return result;
}

// quit() — terminate the app. Must hop to the main thread on platforms that
// require it; exit() itself is safe from any thread but some teardown
// handlers assume main-thread context.
static JSValue zapp_bridge_quit(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)ctx; (void)this_val; (void)argc; (void)argv;
#ifdef __APPLE__
    dispatch_async(dispatch_get_main_queue(), ^{ exit(0); });
#else
    exit(0);
#endif
    return JS_UNDEFINED;
}

// notif(action, args) — dispatcher for all notification operations.
// Mirrors the JSC engine's bridge.notif host.
//
// Darwin-only today. When txiki ships on Windows we'll add the Windows
// notification backend and drop the #ifdef, routing to a common
// `zapp_notification_*` layer.
#ifdef __APPLE__
extern const char* darwin_notification_get_permission(void);
extern void darwin_notification_show_typed(const char*, const char*, const char*, const char*);
extern void darwin_notification_schedule_typed(const char*, const char*, double);
extern void darwin_notification_cancel(const char*);
extern void darwin_notification_cancel_all(void);
extern void darwin_notification_remove_delivered(const char*);
extern void darwin_notification_remove_all_delivered(void);
extern void darwin_notification_update(const char*, const char*, const char*, const char*);
#endif

static JSValue zapp_bridge_notif(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
#ifndef __APPLE__
    (void)ctx; (void)this_val; (void)argc; (void)argv;
    return JS_UNDEFINED;
#else
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    const char* action = JS_ToCString(ctx, argv[0]);
    if (!action) return JS_UNDEFINED;
    JSValue args = (argc >= 2) ? argv[1] : JS_UNDEFINED;

    // Helper to extract a string property from args (if args is an object).
    #define GETSTR(name, dflt) ({ \
        const char* _r = (dflt); \
        JSValue _v = JS_IsObject(args) ? JS_GetPropertyStr(ctx, args, (name)) : JS_UNDEFINED; \
        if (JS_IsString(_v)) _r = JS_ToCString(ctx, _v); \
        _v; _r; \
    })

    JSValue result = JS_UNDEFINED;

    if (strcmp(action, "getPermission") == 0) {
        const char* st = darwin_notification_get_permission();
        result = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, result, "status", JS_NewString(ctx, st ? st : "notDetermined"));
    } else if (strcmp(action, "show") == 0 && JS_IsObject(args)) {
        JSValue title_v = JS_GetPropertyStr(ctx, args, "title");
        JSValue subtitle_v = JS_GetPropertyStr(ctx, args, "subtitle");
        JSValue body_v = JS_GetPropertyStr(ctx, args, "body");
        JSValue sound_v = JS_GetPropertyStr(ctx, args, "sound");
        const char* t = JS_IsString(title_v) ? JS_ToCString(ctx, title_v) : "";
        const char* s = JS_IsString(subtitle_v) ? JS_ToCString(ctx, subtitle_v) : "";
        const char* b = JS_IsString(body_v) ? JS_ToCString(ctx, body_v) : "";
        const char* snd = JS_IsString(sound_v) ? JS_ToCString(ctx, sound_v) : "default";
        darwin_notification_show_typed(t, s, b, snd);
        char id[64];
        {
            struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
            unsigned long long ms = (unsigned long long)ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;
            snprintf(id, sizeof(id), "notif-%llu-%u", ms, arc4random());
        }
        result = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, result, "id", JS_NewString(ctx, id));
        if (JS_IsString(title_v)) JS_FreeCString(ctx, t);
        if (JS_IsString(subtitle_v)) JS_FreeCString(ctx, s);
        if (JS_IsString(body_v)) JS_FreeCString(ctx, b);
        if (JS_IsString(sound_v)) JS_FreeCString(ctx, snd);
        JS_FreeValue(ctx, title_v); JS_FreeValue(ctx, subtitle_v);
        JS_FreeValue(ctx, body_v); JS_FreeValue(ctx, sound_v);
    } else if (strcmp(action, "schedule") == 0 && JS_IsObject(args)) {
        JSValue title_v = JS_GetPropertyStr(ctx, args, "title");
        JSValue body_v = JS_GetPropertyStr(ctx, args, "body");
        JSValue delay_v = JS_GetPropertyStr(ctx, args, "delaySeconds");
        const char* t = JS_IsString(title_v) ? JS_ToCString(ctx, title_v) : "";
        const char* b = JS_IsString(body_v) ? JS_ToCString(ctx, body_v) : "";
        double d = 0; if (JS_IsNumber(delay_v)) JS_ToFloat64(ctx, &d, delay_v);
        darwin_notification_schedule_typed(t, b, d);
        char id[64];
        {
            struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
            unsigned long long ms = (unsigned long long)ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;
            snprintf(id, sizeof(id), "notif-%llu-%u", ms, arc4random());
        }
        result = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, result, "id", JS_NewString(ctx, id));
        if (JS_IsString(title_v)) JS_FreeCString(ctx, t);
        if (JS_IsString(body_v)) JS_FreeCString(ctx, b);
        JS_FreeValue(ctx, title_v); JS_FreeValue(ctx, body_v); JS_FreeValue(ctx, delay_v);
    } else if (strcmp(action, "cancelAll") == 0) {
        darwin_notification_cancel_all();
    } else if (strcmp(action, "removeAllDelivered") == 0) {
        darwin_notification_remove_all_delivered();
    } else if (JS_IsObject(args)) {
        JSValue id_v = JS_GetPropertyStr(ctx, args, "id");
        const char* id = JS_IsString(id_v) ? JS_ToCString(ctx, id_v) : "";
        if (strcmp(action, "cancel") == 0) darwin_notification_cancel(id);
        else if (strcmp(action, "removeDelivered") == 0) darwin_notification_remove_delivered(id);
        else if (strcmp(action, "update") == 0) {
            JSValue t_v = JS_GetPropertyStr(ctx, args, "title");
            JSValue st_v = JS_GetPropertyStr(ctx, args, "subtitle");
            JSValue b_v = JS_GetPropertyStr(ctx, args, "body");
            const char* t = JS_IsString(t_v) ? JS_ToCString(ctx, t_v) : "";
            const char* st = JS_IsString(st_v) ? JS_ToCString(ctx, st_v) : "";
            const char* b = JS_IsString(b_v) ? JS_ToCString(ctx, b_v) : "";
            darwin_notification_update(id, t, st, b);
            if (JS_IsString(t_v)) JS_FreeCString(ctx, t);
            if (JS_IsString(st_v)) JS_FreeCString(ctx, st);
            if (JS_IsString(b_v)) JS_FreeCString(ctx, b);
            JS_FreeValue(ctx, t_v); JS_FreeValue(ctx, st_v); JS_FreeValue(ctx, b_v);
        }
        if (JS_IsString(id_v)) JS_FreeCString(ctx, id);
        JS_FreeValue(ctx, id_v);
    }

    #undef GETSTR
    JS_FreeCString(ctx, action);
    return result;
#endif /* __APPLE__ */
}

// dock(action, args) — sync dispatcher for macOS dock APIs. On Windows this
// will become `taskbar` routing to SetOverlayIcon / SetThumbnailTooltip etc.
// once the cross-platform `zapp_dock_*` layer lands.
#ifdef __APPLE__
extern void darwin_dock_show_icon(void);
extern void darwin_dock_hide_icon(void);
extern void darwin_dock_set_badge(const char*);
extern void darwin_dock_remove_badge(void);
extern void darwin_dock_bounce(int);
extern void darwin_dock_set_icon(const char*);
extern void darwin_dock_reset_icon(void);
#endif

static JSValue zapp_bridge_dock(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
#ifndef __APPLE__
    (void)ctx; (void)this_val; (void)argc; (void)argv;
    return JS_UNDEFINED;
#else
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    const char* action = JS_ToCString(ctx, argv[0]);
    if (!action) return JS_UNDEFINED;

    if (strcmp(action, "showIcon") == 0) darwin_dock_show_icon();
    else if (strcmp(action, "hideIcon") == 0) darwin_dock_hide_icon();
    else if (strcmp(action, "removeBadge") == 0) darwin_dock_remove_badge();
    else if (strcmp(action, "resetIcon") == 0) darwin_dock_reset_icon();
    else if (argc >= 2 && JS_IsObject(argv[1])) {
        if (strcmp(action, "setBadge") == 0) {
            JSValue v = JS_GetPropertyStr(ctx, argv[1], "label");
            const char* s = JS_IsString(v) ? JS_ToCString(ctx, v) : "";
            darwin_dock_set_badge(s);
            if (JS_IsString(v)) JS_FreeCString(ctx, s);
            JS_FreeValue(ctx, v);
        } else if (strcmp(action, "bounce") == 0) {
            JSValue v = JS_GetPropertyStr(ctx, argv[1], "type");
            int32_t t = 0; if (JS_IsNumber(v)) JS_ToInt32(ctx, &t, v);
            darwin_dock_bounce(t);
            JS_FreeValue(ctx, v);
        } else if (strcmp(action, "setIcon") == 0) {
            JSValue v = JS_GetPropertyStr(ctx, argv[1], "path");
            const char* s = JS_IsString(v) ? JS_ToCString(ctx, v) : "";
            darwin_dock_set_icon(s);
            if (JS_IsString(v)) JS_FreeCString(ctx, s);
            JS_FreeValue(ctx, v);
        }
    }

    JS_FreeCString(ctx, action);
    return JS_UNDEFINED;
#endif /* __APPLE__ */
}

static void txiki_setup_bridge(JSContext* ctx, const char* worker_id) {
    // Register worker_id in the per-context cache so host objects can look it
    // up without a globalThis property fetch on every call.
    txiki_bridge_cache_register(ctx, worker_id);

    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "__zappWorkerId", JS_NewString(ctx, worker_id));

    JSValue bridge = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, bridge, "invokeService",
        JS_NewCFunction(ctx, zapp_bridge_invoke_service, "invokeService", 2));
    JS_SetPropertyStr(ctx, bridge, "postToWebview",
        JS_NewCFunction(ctx, zapp_bridge_post_to_webview, "postToWebview", 1));
    JS_SetPropertyStr(ctx, bridge, "emitToHost",
        JS_NewCFunction(ctx, zapp_bridge_emit_to_host, "emitToHost", 2));
    JS_SetPropertyStr(ctx, bridge, "dispatchEventToAll",
        JS_NewCFunction(ctx, zapp_bridge_emit_to_host, "dispatchEventToAll", 2));
    JS_SetPropertyStr(ctx, bridge, "syncWait",
        JS_NewCFunction(ctx, zapp_bridge_sync_wait, "syncWait", 2));
    JS_SetPropertyStr(ctx, bridge, "syncNotify",
        JS_NewCFunction(ctx, zapp_bridge_sync_notify, "syncNotify", 2));
    // Privileged host objects — parity with JSC engine. Every worker gets
    // full access to these regardless of how it was spawned.
    JS_SetPropertyStr(ctx, bridge, "createWindow",
        JS_NewCFunction(ctx, zapp_bridge_create_window, "createWindow", 1));
    JS_SetPropertyStr(ctx, bridge, "quit",
        JS_NewCFunction(ctx, zapp_bridge_quit, "quit", 0));
    JS_SetPropertyStr(ctx, bridge, "notif",
        JS_NewCFunction(ctx, zapp_bridge_notif, "notif", 2));
    JS_SetPropertyStr(ctx, bridge, "dock",
        JS_NewCFunction(ctx, zapp_bridge_dock, "dock", 2));
    JS_SetPropertyStr(ctx, global, "__zappBridge", bridge);
    JS_SetPropertyStr(ctx, global, "postMessage",
        JS_NewCFunction(ctx, zapp_bridge_post_to_webview, "postMessage", 1));

    // `self` alias — worker scope convention.
    JS_Eval(ctx, "self = globalThis;", 18, "<bridge>", JS_EVAL_TYPE_GLOBAL);

    // Run the shared worker bootstrap (bootstrap/worker.ts). This wires up
    // the event listener registry, the runtime bridge aliases, channel API
    // (self.send / self.receive), and app-event dispatch — the same JS that
    // the JSC engine runs. Parity between engines is critical: the same TS
    // worker code must behave identically whether it's spawned under JSC or
    // txiki.
    extern const char* zapp_worker_bootstrap_script(void);
    const char* bootstrap = zapp_worker_bootstrap_script();
    if (bootstrap && bootstrap[0] != '\0') {
        JSValue r = JS_Eval(ctx, bootstrap, strlen(bootstrap), "<worker-bootstrap>", JS_EVAL_TYPE_GLOBAL);
        if (JS_IsException(r)) {
            JSValue e = JS_GetException(ctx);
            const char* msg = JS_ToCString(ctx, e);
            fprintf(stderr, "[zapp] txiki worker bootstrap failed: %s\n", msg ? msg : "(unknown)");
            if (msg) JS_FreeCString(ctx, msg);
            JS_FreeValue(ctx, e);
        }
        JS_FreeValue(ctx, r);
    }

    JS_FreeValue(ctx, global);
}

// --- Async message delivery (runs on worker thread) ---

// Drain Sync.wait results from a worker's sync_inbox — runs on the worker
// thread that owns `ctx`. Called by both regular worker and backend async
// handlers.
static void txiki_drain_sync_inbox(TxikiWorkerSlot* slot, JSContext* ctx) {
    char* sync_msg;
    while ((sync_msg = msgqueue_pop(&slot->sync_inbox)) != NULL) {
        char rid[128] = {0};
        char status[32] = {0};
        if (zapp_extract_json_str(sync_msg, "id", rid, sizeof(rid)) &&
            zapp_extract_json_str(sync_msg, "status", status, sizeof(status))) {
            JSContext* pending_ctx = NULL;
            JSValue resolver;
            if (txiki_sync_pending_take(rid, &pending_ctx, &resolver) && pending_ctx == ctx) {
                JSValue arg = JS_NewString(ctx, status);
                JSValue ret = JS_Call(ctx, resolver, JS_UNDEFINED, 1, &arg);
                JS_FreeValue(ctx, ret);
                JS_FreeValue(ctx, arg);
                JS_FreeValue(ctx, resolver);
            }
        }
        free(sync_msg);
    }
}

static void on_async_message(uv_async_t* handle) {
    TxikiWorkerSlot* slot = (TxikiWorkerSlot*)handle->data;
    if (!slot || !slot->ctx) return;

    JSContext* ctx = slot->ctx;

    // Drain Sync.wait results first.
    txiki_drain_sync_inbox(slot, ctx);

    char* msg;
    while ((msg = msgqueue_pop(&slot->inbox)) != NULL) {
        // Parse JSON and create event
        JSValue global = JS_GetGlobalObject(ctx);
        JSValue parsed = JS_ParseJSON(ctx, msg, strlen(msg), "<message>");
        if (JS_IsException(parsed)) parsed = JS_NewString(ctx, msg);

        JSValue event = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, event, "data", parsed);

        // Call self.onmessage
        JSValue onmessage = JS_GetPropertyStr(ctx, global, "onmessage");
        if (!JS_IsUndefined(onmessage) && !JS_IsNull(onmessage)) {
            JS_Call(ctx, onmessage, global, 1, &event);
        }
        JS_FreeValue(ctx, onmessage);

        // Call _messageHandlers (channel API)
        JSValue handlers = JS_GetPropertyStr(ctx, global, "_messageHandlers");
        if (!JS_IsUndefined(handlers)) {
            JSValue len_val = JS_GetPropertyStr(ctx, handlers, "length");
            int32_t len = 0;
            JS_ToInt32(ctx, &len, len_val);
            JS_FreeValue(ctx, len_val);
            for (int i = 0; i < len; i++) {
                JSValue h = JS_GetPropertyUint32(ctx, handlers, i);
                if (!JS_IsUndefined(h)) JS_Call(ctx, h, global, 1, &event);
                JS_FreeValue(ctx, h);
            }
        }
        JS_FreeValue(ctx, handlers);
        JS_FreeValue(ctx, event);
        JS_FreeValue(ctx, global);
        free(msg);
    }
}

// --- Worker thread ---

static void* txiki_worker_thread(void* arg) {
    TxikiWorkerSlot* slot = (TxikiWorkerSlot*)arg;

    TJSRuntime* rt = TJS_NewRuntimeWorker();
    if (!rt) {
        fprintf(stderr, "[zapp] txiki: failed to create runtime for %s\n", slot->worker_id);
        slot->active = 0;
        return NULL;
    }

    // libwebsockets requires a non-NULL cookie jar path before any WebSocket
    // is constructed. txiki's CLI bootstrap normally sets this; for embedder
    // use we set it ourselves so SDKs like SurrealDB can connect.
    {
        char cookie_dir[1024];
        char cookie_path[1280];
        const char* home = getenv("HOME");
        snprintf(cookie_dir, sizeof(cookie_dir), "%s/Library/Caches/zapp", home ? home : "/tmp");
        mkdir(cookie_dir, 0755);  // best-effort; ignore EEXIST
        snprintf(cookie_path, sizeof(cookie_path), "%s/cookies-%s.txt", cookie_dir, slot->worker_id);
        TJS_SetCookieJarPath(rt, cookie_path);
    }

    JSContext* ctx = TJS_GetJSContext(rt);
    slot->runtime = rt;
    slot->ctx = ctx;

    // Register uv_async on the worker's event loop BEFORE TJS_Run
    uv_loop_t* loop = TJS_GetLoop(rt);
    uv_async_init(loop, &slot->async, on_async_message);
    slot->async.data = slot;
    slot->async_initialized = 1;

    txiki_setup_bridge(ctx, slot->worker_id);

    // script_url is the canonical URL form (e.g. "/_workers/worker.mjs")
    // rewritten by the Vite plugin. Embedded assets use the same key;
    // dev filesystem fallback maps it to .zapp/workers/<basename>.
    char script_path[512];
    char cwd[256];
    const char* basename = strrchr(slot->script_url, '/');
    basename = basename ? basename + 1 : slot->script_url;
    if (getcwd(cwd, sizeof(cwd))) {
        snprintf(script_path, sizeof(script_path), "%s/.zapp/workers/%s", cwd, basename);
    } else {
        strncpy(script_path, slot->script_url, sizeof(script_path) - 1);
    }

    // Try embedded assets first (production builds)
    char* code = NULL;
    long code_len = 0;

    extern int zapp_build_use_embedded_assets(void);
    if (zapp_build_use_embedded_assets()) {
        extern ZappEmbeddedAsset zapp_embedded_assets[];
        extern int zapp_embedded_assets_count;

        for (int ai = 0; ai < zapp_embedded_assets_count; ai++) {
            if (strcmp(zapp_embedded_assets[ai].path, slot->script_url) == 0) {
                if (zapp_embedded_assets[ai].is_brotli && zapp_embedded_assets[ai].uncompressed_len > 0) {
                    code = (char*)malloc(zapp_embedded_assets[ai].uncompressed_len + 1);
                    code_len = compression_decode_buffer(
                        (uint8_t*)code, zapp_embedded_assets[ai].uncompressed_len,
                        zapp_embedded_assets[ai].data, zapp_embedded_assets[ai].len,
                        NULL, COMPRESSION_BROTLI);
                    code[code_len] = '\0';
                } else {
                    code_len = zapp_embedded_assets[ai].len;
                    code = (char*)malloc(code_len + 1);
                    memcpy(code, zapp_embedded_assets[ai].data, code_len);
                    code[code_len] = '\0';
                }
                fprintf(stderr, "[zapp] txiki worker script loaded from embedded: %s\n", slot->script_url);
                break;
            }
        }
    }

    // Fallback: filesystem (dev mode)
    if (!code) {
        FILE* f = fopen(script_path, "r");
        if (f) {
            fseek(f, 0, SEEK_END);
            code_len = ftell(f);
            fseek(f, 0, SEEK_SET);
            code = (char*)malloc(code_len + 1);
            if (code) {
                fread(code, 1, code_len, f);
                code[code_len] = '\0';
                fprintf(stderr, "[zapp] txiki worker script loaded: %s\n", script_path);
            }
            fclose(f);
        } else {
            fprintf(stderr, "[zapp] txiki worker script not found: %s\n", script_path);
        }
    }

    if (code) {
        // Eval as a module so top-level await is allowed. The bundled script
        // is ESM-shaped and contains no live imports/exports (Vite tree-shakes
        // everything inline), so no module loader is needed. The TJS_Run loop
        // below pumps any pending top-level await.
        JSValue result = JS_Eval(ctx, code, code_len, slot->script_url, JS_EVAL_TYPE_MODULE);
        if (JS_IsException(result)) {
            JSValue exc = JS_GetException(ctx);
            const char* err = JS_ToCString(ctx, exc);
            fprintf(stderr, "[zapp] txiki worker error: %s\n", err ? err : "unknown");
            if (err) JS_FreeCString(ctx, err);
            JS_FreeValue(ctx, exc);
        }
        JS_FreeValue(ctx, result);
        free(code);

        // Run the event loop
        TJS_Run(rt);
    }

    // Cleanup
    if (slot->async_initialized) {
        uv_close((uv_handle_t*)&slot->async, NULL);
    }
    txiki_sync_pending_release_ctx(ctx);
    txiki_bridge_cache_release(ctx);
    TJS_FreeRuntime(rt);
    slot->runtime = NULL;
    slot->ctx = NULL;
    slot->active = 0;
    return NULL;
}

// --- C API ---

bool txiki_worker_create(const char* script_url, const char* owner_id, const char* worker_id) {
    if (!script_url || !worker_id) return false;

    pthread_mutex_lock(&txiki_mutex);
    TxikiWorkerSlot* slot = NULL;
    for (int i = 0; i < TXIKI_MAX_WORKERS; i++) {
        if (!txiki_workers[i].active) {
            slot = &txiki_workers[i];
            break;
        }
    }
    if (!slot) { pthread_mutex_unlock(&txiki_mutex); return false; }

    memset(slot, 0, sizeof(TxikiWorkerSlot));
    strncpy(slot->worker_id, worker_id, 63);
    strncpy(slot->owner_id, owner_id ? owner_id : "", 63);
    strncpy(slot->script_url, script_url, 255);
    slot->active = 1;
    msgqueue_init(&slot->inbox);
    msgqueue_init(&slot->sync_inbox);

    TJS_Initialize(0, NULL);
    pthread_create(&slot->thread, NULL, txiki_worker_thread, slot);
    pthread_detach(slot->thread);
    pthread_mutex_unlock(&txiki_mutex);

    fprintf(stderr, "[zapp] txiki worker created: %s\n", worker_id);
    return true;
}

void txiki_worker_post_message(const char* worker_id, const char* data_json) {
    if (!worker_id || !data_json) return;
    pthread_mutex_lock(&txiki_mutex);
    TxikiWorkerSlot* slot = txiki_find_slot(worker_id);
    if (!slot || !slot->async_initialized) {
        pthread_mutex_unlock(&txiki_mutex);
        return;
    }
    msgqueue_push(&slot->inbox, data_json);
    uv_async_send(&slot->async);  // Wake the worker's event loop
    pthread_mutex_unlock(&txiki_mutex);
}

void txiki_worker_terminate(const char* worker_id) {
    if (!worker_id) return;
    pthread_mutex_lock(&txiki_mutex);
    TxikiWorkerSlot* slot = txiki_find_slot(worker_id);
    if (slot) {
        if (slot->runtime) TJS_Stop(slot->runtime);
        msgqueue_destroy(&slot->inbox);
        msgqueue_destroy(&slot->sync_inbox);
        slot->active = 0;
        fprintf(stderr, "[zapp] txiki worker terminated: %s\n", worker_id);
    }
    pthread_mutex_unlock(&txiki_mutex);
}

void txiki_worker_terminate_owner(const char* owner_id) {
    if (!owner_id) return;
    pthread_mutex_lock(&txiki_mutex);
    for (int i = 0; i < TXIKI_MAX_WORKERS; i++) {
        if (txiki_workers[i].active && strcmp(txiki_workers[i].owner_id, owner_id) == 0) {
            if (txiki_workers[i].runtime) TJS_Stop(txiki_workers[i].runtime);
            msgqueue_destroy(&txiki_workers[i].inbox);
            msgqueue_destroy(&txiki_workers[i].sync_inbox);
            txiki_workers[i].active = 0;
        }
    }
    pthread_mutex_unlock(&txiki_mutex);
}

// --- Backend worker (privileged, app-level context with web APIs) ---
// Uses txiki.js for fetch, WebSocket, timers, crypto — opt-in via build config.

TxikiWorkerSlot txiki_backend = {0};
int txiki_backend_running = 0;

// Backend-specific async handler: evals queued JS strings
static void txiki_backend_on_async(uv_async_t* handle) {
    TxikiWorkerSlot* slot = (TxikiWorkerSlot*)handle->data;
    if (!slot || !slot->ctx) return;
    JSContext* ctx = slot->ctx;

    // Drain Sync.wait results first — resolves pending promises on the
    // backend's event loop.
    txiki_drain_sync_inbox(slot, ctx);

    char* msg;
    while ((msg = msgqueue_pop(&slot->inbox)) != NULL) {
        JSValue result = JS_Eval(ctx, msg, strlen(msg), "<backend-eval>", JS_EVAL_TYPE_GLOBAL);
        if (JS_IsException(result)) {
            JSValue exc = JS_GetException(ctx);
            const char* err = JS_ToCString(ctx, exc);
            fprintf(stderr, "[backend ERROR] %s\n", err ? err : "unknown");
            if (err) JS_FreeCString(ctx, err);
            JS_FreeValue(ctx, exc);
        }
        JS_FreeValue(ctx, result);
        free(msg);
    }
}

static JSValue zapp_backend_quit(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)ctx; (void)this_val; (void)argc; (void)argv;
    exit(0);
    return JS_UNDEFINED;
}

static JSValue zapp_backend_subscribe_window(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 2) return JS_UNDEFINED;
    int wid = 0, eid = 0;
    JS_ToInt32(ctx, &wid, argv[0]);
    JS_ToInt32(ctx, &eid, argv[1]);

    extern void zapp_window_set_backend_listener(int id, int event_id, int has_listener);
    if (wid < 0) {
        for (int i = 0; i < 64; i++) {
            zapp_window_set_backend_listener(i, eid, 1);
        }
    } else {
        zapp_window_set_backend_listener(wid, eid, 1);
    }
    return JS_UNDEFINED;
}

static void* txiki_backend_thread(void* arg) {
    TxikiWorkerSlot* slot = (TxikiWorkerSlot*)arg;

    TJSRuntime* rt = TJS_NewRuntimeWorker();
    if (!rt) {
        fprintf(stderr, "[zapp] txiki backend: failed to create runtime\n");
        txiki_backend_running = 0;
        return NULL;
    }

    // libwebsockets needs a non-NULL cookie jar path before any WebSocket use.
    {
        char cookie_dir[1024];
        char cookie_path[1280];
        const char* home = getenv("HOME");
        snprintf(cookie_dir, sizeof(cookie_dir), "%s/Library/Caches/zapp", home ? home : "/tmp");
        mkdir(cookie_dir, 0755);
        snprintf(cookie_path, sizeof(cookie_path), "%s/cookies-backend.txt", cookie_dir);
        TJS_SetCookieJarPath(rt, cookie_path);
    }

    JSContext* ctx = TJS_GetJSContext(rt);
    slot->runtime = rt;
    slot->ctx = ctx;

    // Register uv_async for JS eval dispatch
    uv_loop_t* loop = TJS_GetLoop(rt);
    uv_async_init(loop, &slot->async, txiki_backend_on_async);
    slot->async.data = slot;
    slot->async_initialized = 1;

    // Set up bridge (invokeService, postToWebview, etc.)
    txiki_setup_bridge(ctx, "__backend__");

    // Add backend-specific host objects
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue bridge = JS_GetPropertyStr(ctx, global, "__zappBridge");
    JS_SetPropertyStr(ctx, bridge, "quit",
        JS_NewCFunction(ctx, zapp_backend_quit, "quit", 0));
    JS_SetPropertyStr(ctx, bridge, "subscribeWindowEvent",
        JS_NewCFunction(ctx, zapp_backend_subscribe_window, "subscribeWindowEvent", 2));
    JS_FreeValue(ctx, bridge);
    JS_FreeValue(ctx, global);

    // Note: dead code path — app_start_backend no longer dispatches here.
    // Backend bootstrap was merged into the worker bootstrap; this function
    // is left in place until the full txiki backend removal lands.

    // Load user backend script — try embedded first, then filesystem.
    // slot->script_url is the canonical URL form ("/_workers/backend.mjs").
    char* code = NULL;
    long code_len = 0;

    extern int zapp_build_use_embedded_assets(void);
    if (zapp_build_use_embedded_assets()) {
        extern ZappEmbeddedAsset zapp_embedded_assets[];
        extern int zapp_embedded_assets_count;
        for (int ai = 0; ai < zapp_embedded_assets_count; ai++) {
            if (strcmp(zapp_embedded_assets[ai].path, slot->script_url) == 0) {
                if (zapp_embedded_assets[ai].is_brotli && zapp_embedded_assets[ai].uncompressed_len > 0) {
                    code = (char*)malloc(zapp_embedded_assets[ai].uncompressed_len + 1);
                    code_len = compression_decode_buffer(
                        (uint8_t*)code, zapp_embedded_assets[ai].uncompressed_len,
                        zapp_embedded_assets[ai].data, zapp_embedded_assets[ai].len,
                        NULL, COMPRESSION_BROTLI);
                    code[code_len] = '\0';
                } else {
                    code_len = zapp_embedded_assets[ai].len;
                    code = (char*)malloc(code_len + 1);
                    memcpy(code, zapp_embedded_assets[ai].data, code_len);
                    code[code_len] = '\0';
                }
                fprintf(stderr, "[zapp] txiki backend loaded from embedded: %s\n", slot->script_url);
                break;
            }
        }
    }

    if (!code) {
        // Dev: Vite plugin writes workers to .zapp/workers/<basename>
        char cwd[1024];
        char script_path[1280];
        const char* basename = strrchr(slot->script_url, '/');
        basename = basename ? basename + 1 : slot->script_url;
        if (getcwd(cwd, sizeof(cwd))) {
            snprintf(script_path, sizeof(script_path), "%s/.zapp/workers/%s", cwd, basename);
        } else {
            strncpy(script_path, slot->script_url, sizeof(script_path) - 1);
        }
        FILE* f = fopen(script_path, "r");
        if (f) {
            fseek(f, 0, SEEK_END);
            code_len = ftell(f);
            fseek(f, 0, SEEK_SET);
            code = (char*)malloc(code_len + 1);
            if (code) {
                fread(code, 1, code_len, f);
                code[code_len] = '\0';
                fprintf(stderr, "[zapp] txiki backend started: %s\n", script_path);
            }
            fclose(f);
        } else {
            fprintf(stderr, "[zapp] txiki backend script not found: %s\n", script_path);
        }
    }

    if (code) {
        // Module mode for top-level await — see worker thread for rationale.
        JSValue result = JS_Eval(ctx, code, code_len, "backend.mjs", JS_EVAL_TYPE_MODULE);
        if (JS_IsException(result)) {
            JSValue exc = JS_GetException(ctx);
            const char* err = JS_ToCString(ctx, exc);
            fprintf(stderr, "[backend ERROR] %s\n", err ? err : "unknown");
            if (err) JS_FreeCString(ctx, err);
            JS_FreeValue(ctx, exc);
        }
        JS_FreeValue(ctx, result);
        free(code);

        // Run event loop — handles fetch, WebSocket, timers, AND our async eval messages
        TJS_Run(rt);
    } else {
        fprintf(stderr, "[zapp] txiki backend script not found: %s\n", slot->script_url);
    }

    // Cleanup
    if (slot->async_initialized) {
        uv_close((uv_handle_t*)&slot->async, NULL);
    }
    txiki_sync_pending_release_ctx(ctx);
    txiki_bridge_cache_release(ctx);
    TJS_FreeRuntime(rt);
    slot->runtime = NULL;
    slot->ctx = NULL;
    txiki_backend_running = 0;
    return NULL;
}

bool txiki_backend_create(const char* script_path) {
    if (txiki_backend_running || !script_path) return false;

    memset(&txiki_backend, 0, sizeof(TxikiWorkerSlot));
    strncpy(txiki_backend.worker_id, "__backend__", 63);
    strncpy(txiki_backend.owner_id, "", 63);
    strncpy(txiki_backend.script_url, script_path, 255);
    txiki_backend.active = 1;
    msgqueue_init(&txiki_backend.inbox);
    msgqueue_init(&txiki_backend.sync_inbox);

    TJS_Initialize(0, NULL);
    txiki_backend_running = 1;
    pthread_t thread;
    pthread_create(&thread, NULL, txiki_backend_thread, &txiki_backend);
    pthread_detach(thread);

    fprintf(stderr, "[zapp] txiki backend worker created\n");
    return true;
}

void txiki_backend_terminate(void) {
    if (!txiki_backend_running) return;
    if (txiki_backend.runtime) TJS_Stop(txiki_backend.runtime);
    msgqueue_destroy(&txiki_backend.inbox);
    msgqueue_destroy(&txiki_backend.sync_inbox);
    txiki_backend.active = 0;
    txiki_backend_running = 0;
    fprintf(stderr, "[zapp] txiki backend terminated\n");
}

void txiki_backend_eval_js(const char* js) {
    if (!txiki_backend_running || !js) return;
    msgqueue_push(&txiki_backend.inbox, js);
    if (txiki_backend.async_initialized) {
        uv_async_send(&txiki_backend.async);
    }
}

bool txiki_backend_is_running(void) {
    return txiki_backend_running != 0;
}

// Broadcast a JS snippet to every active worker. Counterpart of
// jsc_broadcast_eval_js — used by native event dispatch to deliver app and
// window events to every worker. TODO: txiki uses a message-queue/libuv
// dispatch pattern rather than direct eval; a full implementation requires
// adding an "eval this JS" message type handled in on_async_message. For now
// this is a stub so the JSC engine path works; txiki headless workers will
// not receive forwarded events until this is wired up.
void txiki_broadcast_eval_js(const char* js) {
    (void)js;
}
