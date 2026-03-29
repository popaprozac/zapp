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
#include <pthread.h>
#include <uv.h>

// txiki.js private API — needed for TJS_GetLoop and TJS_NewRuntimeWorker
extern uv_loop_t* TJS_GetLoop(TJSRuntime* qrt);
extern TJSRuntime* TJS_NewRuntimeWorker(void);

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
    MsgQueue inbox;          // Thread-safe message queue
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

// --- Host objects (same as before) ---

static JSValue zapp_bridge_invoke_service(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    const char* method = JS_ToCString(ctx, argv[0]);
    if (!method) return JS_UNDEFINED;

    const char* args_json = "{}";
    char* args_str = NULL;
    if (argc >= 2 && !JS_IsUndefined(argv[1])) {
        JSValue global = JS_GetGlobalObject(ctx);
        JSValue json_obj = JS_GetPropertyStr(ctx, global, "JSON");
        JSValue stringify = JS_GetPropertyStr(ctx, json_obj, "stringify");
        JSValue result = JS_Call(ctx, stringify, json_obj, 1, &argv[1]);
        JS_FreeValue(ctx, stringify);
        JS_FreeValue(ctx, json_obj);
        JS_FreeValue(ctx, global);
        if (!JS_IsException(result)) {
            args_str = (char*)JS_ToCString(ctx, result);
            if (args_str) args_json = args_str;
        }
        JS_FreeValue(ctx, result);
    }

    void* app = app_get_active();
    const char* svc_result = app ? service_invoke_sync(app, method, args_json) : NULL;
    JS_FreeCString(ctx, method);
    if (args_str) JS_FreeCString(ctx, args_str);

    if (!svc_result || svc_result[0] == '\0') return JS_UNDEFINED;
    JSValue parsed = JS_ParseJSON(ctx, svc_result, strlen(svc_result), "<service>");
    if (JS_IsException(parsed)) return JS_NewString(ctx, svc_result);
    return parsed;
}

static JSValue zapp_bridge_post_to_webview(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    JSValue wid_val = JS_GetPropertyStr(ctx, JS_GetGlobalObject(ctx), "__zappWorkerId");
    const char* wid = JS_ToCString(ctx, wid_val);
    JS_FreeValue(ctx, wid_val);
    if (!wid) return JS_UNDEFINED;

    JSValue global = JS_GetGlobalObject(ctx);
    JSValue json_obj = JS_GetPropertyStr(ctx, global, "JSON");
    JSValue stringify = JS_GetPropertyStr(ctx, json_obj, "stringify");
    JSValue json_str = JS_Call(ctx, stringify, json_obj, 1, argv);
    JS_FreeValue(ctx, stringify);
    JS_FreeValue(ctx, json_obj);
    JS_FreeValue(ctx, global);

    if (!JS_IsException(json_str)) {
        const char* json = JS_ToCString(ctx, json_str);
        if (json) {
            worker_dispatch_to_webview((char*)wid, (char*)json);
            JS_FreeCString(ctx, json);
        }
    }
    JS_FreeValue(ctx, json_str);
    JS_FreeCString(ctx, wid);
    return JS_UNDEFINED;
}

static JSValue zapp_bridge_emit_to_host(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
    (void)this_val; (void)ctx; (void)argc; (void)argv;
    return JS_UNDEFINED;
}

static void txiki_setup_bridge(JSContext* ctx, const char* worker_id) {
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "__zappWorkerId", JS_NewString(ctx, worker_id));

    JSValue bridge = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, bridge, "invokeService",
        JS_NewCFunction(ctx, zapp_bridge_invoke_service, "invokeService", 2));
    JS_SetPropertyStr(ctx, bridge, "postToWebview",
        JS_NewCFunction(ctx, zapp_bridge_post_to_webview, "postToWebview", 1));
    JS_SetPropertyStr(ctx, bridge, "emitToHost",
        JS_NewCFunction(ctx, zapp_bridge_emit_to_host, "emitToHost", 2));
    JS_SetPropertyStr(ctx, global, "__zappBridge", bridge);
    JS_SetPropertyStr(ctx, global, "postMessage",
        JS_NewCFunction(ctx, zapp_bridge_post_to_webview, "postMessage", 1));

    const char* channel_api =
        "self = globalThis;"
        "self.send = function(channel, data) { self.postMessage({ __zc: channel, d: data }); };"
        "self._channelHandlers = {};"
        "self._messageHandlers = [];"
        "self.receive = function(channel, handler) {"
        "  if (!self._channelHandlers[channel]) self._channelHandlers[channel] = [];"
        "  self._channelHandlers[channel].push(handler);"
        "  if (!self._channelSetup) {"
        "    self._channelSetup = true;"
        "    self._messageHandlers.push(function(ev) {"
        "      var msg = ev.data;"
        "      if (msg && msg.__zc && self._channelHandlers[msg.__zc]) {"
        "        var hs = self._channelHandlers[msg.__zc];"
        "        for (var i = 0; i < hs.length; i++) try { hs[i](msg.d); } catch(e) { console.error(e); }"
        "      }"
        "    });"
        "  }"
        "  return function() {"
        "    self._channelHandlers[channel] = (self._channelHandlers[channel] || []).filter(function(h) { return h !== handler; });"
        "  };"
        "};";
    JS_Eval(ctx, channel_api, strlen(channel_api), "<bridge>", JS_EVAL_TYPE_GLOBAL);
    JS_FreeValue(ctx, global);
}

// --- Async message delivery (runs on worker thread) ---

static void on_async_message(uv_async_t* handle) {
    TxikiWorkerSlot* slot = (TxikiWorkerSlot*)handle->data;
    if (!slot || !slot->ctx) return;

    JSContext* ctx = slot->ctx;
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

    JSContext* ctx = TJS_GetJSContext(rt);
    slot->runtime = rt;
    slot->ctx = ctx;

    // Register uv_async on the worker's event loop BEFORE TJS_Run
    uv_loop_t* loop = TJS_GetLoop(rt);
    uv_async_init(loop, &slot->async, on_async_message);
    slot->async.data = slot;
    slot->async_initialized = 1;

    txiki_setup_bridge(ctx, slot->worker_id);

    // Load script
    char script_path[512];
    char cwd[256];
    if (getcwd(cwd, sizeof(cwd))) {
        const char* basename = strrchr(slot->script_url, '/');
        basename = basename ? basename + 1 : slot->script_url;
        char mjs_name[128];
        strncpy(mjs_name, basename, sizeof(mjs_name) - 1);
        char* dot = strrchr(mjs_name, '.');
        if (dot) strcpy(dot, ".mjs");
        snprintf(script_path, sizeof(script_path), "%s/.zapp/workers/%s", cwd, mjs_name);
    } else {
        strncpy(script_path, slot->script_url, sizeof(script_path) - 1);
    }

    FILE* f = fopen(script_path, "r");
    if (f) {
        fseek(f, 0, SEEK_END);
        long len = ftell(f);
        fseek(f, 0, SEEK_SET);
        char* code = (char*)malloc(len + 1);
        if (code) {
            fread(code, 1, len, f);
            code[len] = '\0';
            fprintf(stderr, "[zapp] txiki worker script loaded: %s\n", script_path);
            JSValue result = JS_Eval(ctx, code, len, slot->script_url, JS_EVAL_TYPE_GLOBAL);
            if (JS_IsException(result)) {
                JSValue exc = JS_GetException(ctx);
                const char* err = JS_ToCString(ctx, exc);
                fprintf(stderr, "[zapp] txiki worker error: %s\n", err ? err : "unknown");
                if (err) JS_FreeCString(ctx, err);
                JS_FreeValue(ctx, exc);
            }
            JS_FreeValue(ctx, result);
            free(code);
        }
        fclose(f);

        // Run the event loop — handles fetch, timers, WebSocket, AND our uv_async messages
        TJS_Run(rt);
    } else {
        fprintf(stderr, "[zapp] txiki worker script not found: %s\n", script_path);
    }

    // Cleanup
    if (slot->async_initialized) {
        uv_close((uv_handle_t*)&slot->async, NULL);
    }
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
            txiki_workers[i].active = 0;
        }
    }
    pthread_mutex_unlock(&txiki_mutex);
}

// --- Backend worker (privileged, app-level context with web APIs) ---
// Uses txiki.js for fetch, WebSocket, timers, crypto — opt-in via build config.

static TxikiWorkerSlot txiki_backend = {0};
static int txiki_backend_running = 0;

// Backend-specific async handler: evals queued JS strings
static void txiki_backend_on_async(uv_async_t* handle) {
    TxikiWorkerSlot* slot = (TxikiWorkerSlot*)handle->data;
    if (!slot || !slot->ctx) return;
    JSContext* ctx = slot->ctx;

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

static void* txiki_backend_thread(void* arg) {
    TxikiWorkerSlot* slot = (TxikiWorkerSlot*)arg;

    TJSRuntime* rt = TJS_NewRuntimeWorker();
    if (!rt) {
        fprintf(stderr, "[zapp] txiki backend: failed to create runtime\n");
        txiki_backend_running = 0;
        return NULL;
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
    JS_FreeValue(ctx, bridge);
    JS_FreeValue(ctx, global);

    // Load backend bootstrap
    extern const char* zapp_backend_bootstrap_script(void);
    const char* bootstrap = zapp_backend_bootstrap_script();
    if (bootstrap && bootstrap[0] != '\0') {
        JSValue r = JS_Eval(ctx, bootstrap, strlen(bootstrap), "<backend-bootstrap>", JS_EVAL_TYPE_GLOBAL);
        JS_FreeValue(ctx, r);
    }

    // Load user script
    char cwd[1024];
    char script_path[1280];
    if (getcwd(cwd, sizeof(cwd))) {
        snprintf(script_path, sizeof(script_path), "%s/%s", cwd, slot->script_url);
    } else {
        strncpy(script_path, slot->script_url, sizeof(script_path) - 1);
    }

    FILE* f = fopen(script_path, "r");
    if (f) {
        fseek(f, 0, SEEK_END);
        long len = ftell(f);
        fseek(f, 0, SEEK_SET);
        char* code = (char*)malloc(len + 1);
        if (code) {
            fread(code, 1, len, f);
            code[len] = '\0';
            fprintf(stderr, "[zapp] txiki backend started: %s\n", script_path);
            JSValue result = JS_Eval(ctx, code, len, "backend.mjs", JS_EVAL_TYPE_GLOBAL);
            if (JS_IsException(result)) {
                JSValue exc = JS_GetException(ctx);
                const char* err = JS_ToCString(ctx, exc);
                fprintf(stderr, "[backend ERROR] %s\n", err ? err : "unknown");
                if (err) JS_FreeCString(ctx, err);
                JS_FreeValue(ctx, exc);
            }
            JS_FreeValue(ctx, result);
            free(code);
        }
        fclose(f);

        // Run event loop — handles fetch, WebSocket, timers, AND our async eval messages
        TJS_Run(rt);
    } else {
        fprintf(stderr, "[zapp] txiki backend script not found: %s\n", script_path);
    }

    // Cleanup
    if (slot->async_initialized) {
        uv_close((uv_handle_t*)&slot->async, NULL);
    }
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
