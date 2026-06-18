// zjs worker engine — first-party JS engine for Zapp workers.
//
// Each worker runs on its own pthread with its own ZjsContext. The
// thread structure mirrors txiki.c (slot table + mutex, per-worker
// async/inbox plumbing, embedded-asset → filesystem → iOS dev-URL
// script load chain).
//
// The novel piece is how zjs's timer queue is driven from the
// embedder's event loop. zjs ships no embedded loop of its own —
// instead it exposes a pure polling interface (`zjs_has_pending_work`
// / `zjs_next_timer_ms` / `zjs_run_pending_timers` /
// `zjs_drain_microtasks`). Two embeddings here:
//
//   - **Apple (macOS + iOS)** — kqueue + CFRunLoop hybrid. EVFILT_USER
//     triggers (FILTER_SHUTDOWN / FILTER_INBOX / FILTER_EVAL_INBOX)
//     replace libuv's uv_async_t for cross-thread signaling; the
//     kevent() timeout is fed by zjs_next_timer_ms each iteration;
//     CFRunLoop is ticked once per iteration to drain NSURLSession
//     completions for zjs's fetch / WebSocket. No libuv dependency.
//   - **Linux / Windows** — libuv (uv_loop_t + uv_check_t pump +
//     uv_timer_t armed to zjs_next_timer_ms + 3× uv_async_t).
//     Preserved unchanged until those targets ship their own
//     platform-native loops.
//
// Host bridge (invokeService, dispatchEventToAll, send/receive,
// syncWait/syncNotify, workerCrash) is wired through the same
// __zappBridge global as the other engines.

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
#if defined(__APPLE__)
  // Apple loop: kqueue + CFRunLoop hybrid replaces libuv. kqueue handles
  // timers + cross-thread EVFILT_USER triggers; CFRunLoop is ticked each
  // iteration to drain NSURLSession completions (zjs fetch/WebSocket).
  #include <sys/event.h>
  #include <sys/time.h>
  #include <errno.h>
  #include <CoreFoundation/CoreFoundation.h>
  // GCD — used by the nim-build async invoke host fn (dispatch_async to main).
  // Included unconditionally on Apple; the #ifdef ZAPP_NIM_BUILD gate on the
  // fn body keeps the zc build from generating any dispatch_async call-sites.
  #include <dispatch/dispatch.h>
#else
  #include <uv.h>
#endif
#include <stdatomic.h>

#if defined(__APPLE__)
// EVFILT_USER idents for cross-thread signaling. Each is one-shot
// (EV_CLEAR) so the trigger fires once per kevent() drain. Coalesces
// naturally — multiple triggers between drains = one wake (matches
// uv_async_send semantics).
#define FILTER_SHUTDOWN     1
#define FILTER_INBOX        2
#define FILTER_EVAL_INBOX   3
#endif

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
// Zen-C JsonValue construction (same externs txiki.c uses).
//
// JsonValue is opaque to this translation unit; we only manipulate it via
// pointers. The _ptr constructors return heap-allocated nodes; the
// _owned setters transfer ownership without an extra malloc.
// ---------------------------------------------------------------------------

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

extern void* app_get_active(void);
extern const char* service_invoke_native(void* app, const char* method, JsonValue* args);

// Permission gates (native/permissions/permissions.zc + router.zc — Zen-C,
// plain C symbols). The router gates the webview invoke path; workers reach
// native through this host object, bypassing the router, so the worker path
// runs the SAME mapping + check here. permission_id_for_invoke returns "" for
// ungated methods (user services, __app:/__zapp: plumbing).
extern bool permissions_check(const char* id, const char* method);
extern const char* permission_id_for_invoke(const char* method);

// Fan-out fire-and-forget events to every webview's
// __zappBridge._onEvent listener. Same destination JSC / txiki / bare
// hit; the per-engine difference is how we get the JS payload value
// to a C string. zjs caches JSON.stringify on the slot and calls it
// directly (no JS-side property dance, no second eval).
extern void dispatch_event_to_all(const char* event_name, const char* payload);

// Worker→worker delivery. Routes through the dispatcher (worker.zc) so the
// target engine doesn't have to match — a zjs worker can `Workers.send`
// to a bare/txiki/jsc worker and vice versa. The dispatcher hands off to
// the target engine's *_worker_post_message.
extern void worker_post_message(char* worker_id, char* data_json);

// Supervisor failure recorder. Bumps `fail_count` against the registry's
// configured restart policy and dispatches `worker:gave-up` when the
// window cap is exhausted. Same callee bare.c uses from workerCrash.
extern int zapp_worker_supervisor_record_failure(const char* worker_id);

extern int zapp_worker_supervisor_get_window_state(
    const char* worker_id, int* out_count, int* out_cap, int* out_window_ms);

// Heap JSON array of all active workers (registry.zc). Single source of
// truth for Workers.list(); the worker-context host fn returns this string
// verbatim and the JS runtime wrapper JSON.parses it. Caller free()s.
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
    ZjsContext*  ctx;

#if defined(__APPLE__)
    // Apple loop: kqueue() fd + EVFILT_USER triggers (FILTER_SHUTDOWN /
    // FILTER_INBOX / FILTER_EVAL_INBOX). zjs's timer queue is polled
    // each iteration via zjs_next_timer_ms; no separate uv_timer_t /
    // uv_check_t needed (drain happens inline after kevent returns).
    // CFRunLoopRunInMode is ticked each iteration to drain NSURLSession
    // completions for zjs's fetch/WebSocket.
    int          kq;
    int          kq_initialized;
#else
    // Non-Apple loop: libuv (Linux/Windows). Apple targets use the
    // kqueue + CFRunLoop path above.
    uv_loop_t    loop;
    uv_check_t   check;
    uv_timer_t   zjs_wake;
    uv_async_t   shutdown_async;     // signaled from terminate to wake the loop
    uv_async_t   inbox_async;        // signaled from post_message to drain inbox
    uv_async_t   eval_inbox_async;   // signaled from broadcast_eval_js to drain eval ring
    int          loop_initialized;
#endif

    // Cross-thread inbox — postMessage queues here; the inbox_async
    // callback drains on the worker thread. Simple ring with a mutex;
    // bounded so a runaway producer can't OOM the worker. Cap matches
    // txiki.c's MSG_QUEUE_MAX for consistency.
    pthread_mutex_t inbox_mutex;
    char*           inbox[256];
    int             inbox_head;
    int             inbox_tail;
    int             inbox_count;

    // Cross-thread eval inbox — dispatch_event_to_all → zjs_broadcast_
    // eval_js pushes raw JS snippets here (the bridge._onEvent call
    // emitted by bridge/dispatch.zc). on_eval_inbox_async drains and
    // zjs_evals each one on the worker thread. Kept separate from the
    // message inbox so each direction has its own backpressure cap and
    // the drain semantics stay simple (eval vs. dispatch shim call).
    pthread_mutex_t eval_inbox_mutex;
    char*           eval_inbox[256];
    int             eval_inbox_head;
    int             eval_inbox_tail;
    int             eval_inbox_count;

    // Cached host-side handles to JS built-ins that the bridge uses on
    // every host call. Cheaper than rehydrating via zjs_eval each call
    // (a zjs_get_global lookup beats an eval+parse) and avoids polluting
    // globalThis with intermediate variables.
    //
    // Held via zjs_root so the GC can't reclaim them between calls —
    // the previous "leave as a ZjsValue field on the slot" only worked
    // because the slot itself was reachable from the static workers[]
    // table; that was incidental, not enforced. ZjsRoot makes the hold
    // explicit and survives a future change where the slot is moved or
    // the JSValue's underlying cell migrates.
    uint32_t     object_keys_root;
    uint32_t     json_parse_root;
    uint32_t     json_stringify_root;

    // Cached message dispatcher — installed at bridge-setup time as a
    // small JS shim that JSON.parses the incoming string and fans it
    // out through globalThis.onmessage + the _messageHandlers array
    // (the channel-routing registry the engine-agnostic worker
    // bootstrap installs). Held via zjs_root for the same reason as
    // the JSON helpers above.
    uint32_t     dispatch_message_root;

    // Reincarnation counter — 1 on first start, +1 each successful restart.
    // Read on the worker thread inside setup_state; written there too.
    int incarnation;

    // Control flags — set from host_worker_crash (worker thread) or
    // from zjs_worker_terminate (any thread). The kqueue trigger
    // (apple_trigger_shutdown) / uv_async_send (libuv) wakes the loop;
    // the inner loop in zjs_worker_thread reads these atomics each
    // iteration. wants_terminate wins over wants_restart.
    _Atomic int wants_restart;
    _Atomic int wants_terminate;
} ZjsWorkerSlot;

static ZjsWorkerSlot zjs_workers[ZJS_MAX_WORKERS] = {{0}};
static pthread_mutex_t zjs_workers_mutex = PTHREAD_MUTEX_INITIALIZER;

#if defined(__APPLE__)
// Forward decls — Apple-only kqueue trigger helpers used by host_worker_crash
// (defined earlier in the file than the helper bodies).
static void apple_trigger_inbox(ZjsWorkerSlot* slot);
static void apple_trigger_eval_inbox(ZjsWorkerSlot* slot);
static void apple_trigger_shutdown(ZjsWorkerSlot* slot);
#endif

static ZjsWorkerSlot* zjs_find_slot(const char* worker_id) {
    for (int i = 0; i < ZJS_MAX_WORKERS; i++) {
        if (zjs_workers[i].active && strcmp(zjs_workers[i].worker_id, worker_id) == 0) {
            return &zjs_workers[i];
        }
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// Cross-thread inbox helpers. Bounded ring, mutex-guarded. push from
// any thread (typically the main thread via zjs_worker_post_message),
// pop on the worker thread inside on_inbox_async.
// ---------------------------------------------------------------------------

static int inbox_push(ZjsWorkerSlot* slot, const char* msg) {
    pthread_mutex_lock(&slot->inbox_mutex);
    if (slot->inbox_count >= (int)(sizeof(slot->inbox) / sizeof(slot->inbox[0]))) {
        pthread_mutex_unlock(&slot->inbox_mutex);
        return -1;  // overflow — caller logs
    }
    slot->inbox[slot->inbox_tail] = strdup(msg);
    slot->inbox_tail = (slot->inbox_tail + 1) % (int)(sizeof(slot->inbox) / sizeof(slot->inbox[0]));
    slot->inbox_count++;
    pthread_mutex_unlock(&slot->inbox_mutex);
    return 0;
}

static char* inbox_pop(ZjsWorkerSlot* slot) {
    pthread_mutex_lock(&slot->inbox_mutex);
    if (slot->inbox_count == 0) {
        pthread_mutex_unlock(&slot->inbox_mutex);
        return NULL;
    }
    char* m = slot->inbox[slot->inbox_head];
    slot->inbox_head = (slot->inbox_head + 1) % (int)(sizeof(slot->inbox) / sizeof(slot->inbox[0]));
    slot->inbox_count--;
    pthread_mutex_unlock(&slot->inbox_mutex);
    return m;
}

static int eval_inbox_push(ZjsWorkerSlot* slot, const char* js) {
    pthread_mutex_lock(&slot->eval_inbox_mutex);
    if (slot->eval_inbox_count >= (int)(sizeof(slot->eval_inbox) / sizeof(slot->eval_inbox[0]))) {
        pthread_mutex_unlock(&slot->eval_inbox_mutex);
        return -1;
    }
    slot->eval_inbox[slot->eval_inbox_tail] = strdup(js);
    slot->eval_inbox_tail = (slot->eval_inbox_tail + 1) % (int)(sizeof(slot->eval_inbox) / sizeof(slot->eval_inbox[0]));
    slot->eval_inbox_count++;
    pthread_mutex_unlock(&slot->eval_inbox_mutex);
    return 0;
}

static char* eval_inbox_pop(ZjsWorkerSlot* slot) {
    pthread_mutex_lock(&slot->eval_inbox_mutex);
    if (slot->eval_inbox_count == 0) {
        pthread_mutex_unlock(&slot->eval_inbox_mutex);
        return NULL;
    }
    char* m = slot->eval_inbox[slot->eval_inbox_head];
    slot->eval_inbox_head = (slot->eval_inbox_head + 1) % (int)(sizeof(slot->eval_inbox) / sizeof(slot->eval_inbox[0]));
    slot->eval_inbox_count--;
    pthread_mutex_unlock(&slot->eval_inbox_mutex);
    return m;
}

// Host functions only see ZjsContext*, so they look their slot up here
// to reach the cached helper handles + worker_id. Reads are lock-free
// (each context belongs to one worker thread; the worker only ever sees
// its own ctx, and only its own thread reads/writes the cached handles).
static ZjsWorkerSlot* zjs_slot_for_ctx(ZjsContext* ctx) {
    for (int i = 0; i < ZJS_MAX_WORKERS; i++) {
        if (zjs_workers[i].active && zjs_workers[i].ctx == ctx) {
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

// ---------------------------------------------------------------------------
// ZjsValue → JsonValue walker.
//
// The whole reason we wrote a first-party engine: the bridge gets to
// skip the JS-side JSON.stringify hop. Bare/txiki/jsc invoke services
// by stringifying args in JS, calling a C trampoline that takes a
// string, parsing the string back into a JsonValue. Two full traversals
// of the data + an allocator churn for the intermediate string.
//
// Here we walk the ZjsValue tree directly into a JsonValue tree —
// one traversal, no string buffer. The cost is the per-object key
// iteration (zjs.h doesn't expose a built-in iterator, so we call
// Object.keys via the cached handle — that's a single zjs_call per
// object instead of an eval per property).
// ---------------------------------------------------------------------------

static JsonValue* zjsvalue_to_jsonvalue(ZjsWorkerSlot* slot, ZjsValue v) {
    ZjsContext* ctx = slot->ctx;

    if (zjs_is_undefined(v) || zjs_is_null(v)) {
        return JsonValue__null_ptr();
    }
    if (zjs_is_bool(v)) {
        return JsonValue__bool_ptr(zjs_as_bool(v) ? true : false);
    }
    if (zjs_is_int32(v)) {
        return JsonValue__number_ptr((double) zjs_as_int32(v));
    }
    if (zjs_is_double(v)) {
        return JsonValue__number_ptr(zjs_as_double(v));
    }
    if (zjs_is_string(v)) {
        uint32_t len = 0;
        const char* s = zjs_string_bytes(v, &len);
        // JsonValue__string_ptr strdups internally; passing a non-NUL'd
        // buffer is unsafe, so build a NUL-terminated copy. Most worker
        // payloads are small enough that this temp alloc is noise.
        char* tmp = (char*) malloc((size_t) len + 1);
        if (tmp) {
            if (s && len > 0) memcpy(tmp, s, len);
            tmp[len] = '\0';
            JsonValue* jv = JsonValue__string_ptr(tmp);
            free(tmp);
            return jv;
        }
        return JsonValue__null_ptr();
    }
    if (zjs_is_array(v)) {
        JsonValue* arr = JsonValue__array_ptr();
        // Pin `v` for the iteration — each recursive descent may
        // allocate (string + JsonValue + child Object.keys() etc.)
        // and trigger GC; without a pin, `v` gets reclaimed and the
        // next `zjs_get_element(v, i)` reads freed memory.
        zjs_pin(ctx, v);
        uint32_t n = zjs_array_length(v);
        for (uint32_t i = 0; i < n; i++) {
            ZjsValue elem = zjs_get_element(ctx, v, i);
            json_array_push_owned(arr, zjsvalue_to_jsonvalue(slot, elem));
        }
        zjs_unpin(ctx);
        return arr;
    }
    if (zjs_is_object(v)) {
        JsonValue* obj = JsonValue__object_ptr();
        // Object.keys(v) — cached at bridge setup. Returns an array of
        // string keys (own enumerable, same as JSON.stringify uses).
        //
        // Two pins are needed: `v` itself (the object being walked)
        // and `keys` (the array Object.keys() returned). Both sit
        // only on the C stack and each recursive walk into a child
        // value may allocate enough to trigger GC. Without either
        // pin, the next iteration reads freed memory and either
        // hangs (garbage indices) or crashes.
        zjs_pin(ctx, v);
        ZjsValue arg = v;
        ZjsValue keys = zjs_call(ctx, zjs_root_get(ctx, slot->object_keys_root),
                                 zjs_undefined(), &arg, 1);
        zjs_drain_microtasks(ctx);
        zjs_pin(ctx, keys);
        uint32_t n = zjs_array_length(keys);
        for (uint32_t i = 0; i < n; i++) {
            ZjsValue key = zjs_get_element(ctx, keys, i);
            uint32_t klen = 0;
            const char* kbytes = zjs_string_bytes(key, &klen);
            char* kbuf = (char*) malloc((size_t) klen + 1);
            if (!kbuf) continue;
            if (kbytes && klen > 0) memcpy(kbuf, kbytes, klen);
            kbuf[klen] = '\0';
            ZjsValue val = zjs_get_property(ctx, v, kbuf);
            json_object_set_owned(obj, kbuf, zjsvalue_to_jsonvalue(slot, val));
            free(kbuf);
        }
        zjs_unpin(ctx);   // keys
        zjs_unpin(ctx);   // v
        return obj;
    }
    // Function / symbol / anything else → null (matches JSON.stringify).
    return JsonValue__null_ptr();
}

// ---------------------------------------------------------------------------
// __zappBridge.invokeService(method: string, args?: any) -> any
//
// Direct value path — no JS-side stringify, no JS-side parse on the
// way in. Return value still hops through JSON (service_invoke_native
// returns a string today); upgrading that to a direct JsonValue→ZjsValue
// walk is a follow-up once we have a zenc-friendly return shape.
// ---------------------------------------------------------------------------

static ZjsValue host_invoke_service(ZjsContext* ctx, ZjsValue* argv, uint32_t argc) {
    if (argc < 1 || !zjs_is_string(argv[0])) return zjs_undefined();

    ZjsWorkerSlot* slot = zjs_slot_for_ctx(ctx);
    if (!slot) return zjs_undefined();

    uint32_t method_len = 0;
    const char* method_bytes = zjs_string_bytes(argv[0], &method_len);
    if (!method_bytes) return zjs_undefined();
    // Method name needs to be NUL-terminated for service_invoke_native;
    // copy locally so we own the string.
    char* method = (char*) malloc((size_t) method_len + 1);
    if (!method) return zjs_undefined();
    memcpy(method, method_bytes, method_len);
    method[method_len] = '\0';

    // Permission gate (same mapping the router runs for the webview path).
    // Gated method + manifest active + not granted → throw so the synchronous
    // invokeService() call rejects/throws on the JS side (parity with the
    // webview path, which rejects with new Error("PERMISSION_DENIED:<id>")).
    const char* perm_id = permission_id_for_invoke(method);
    if (perm_id && perm_id[0] && !permissions_check(perm_id, method)) {
        char msg[160];
        snprintf(msg, sizeof(msg), "PERMISSION_DENIED:%s", perm_id);
        // Build `new Error(msg)` across several allocating zjs_* calls. Per
        // zjs's value-lifetime contract (zjs.h), a ZjsValue is live only until
        // the NEXT allocating call, so err_ctor/err_msg must be pinned across
        // the construction or GC under pressure could reclaim them mid-build
        // (use-after-free). Mirrors the zjsvalue_to_jsonvalue walker's
        // pin/unpin stack discipline.
        ZjsValue err_ctor = zjs_get_global(ctx, "Error");
        zjs_pin(ctx, err_ctor);
        ZjsValue err_msg = zjs_new_string(ctx, msg, (uint32_t) strlen(msg));
        zjs_pin(ctx, err_msg);
        ZjsValue err = zjs_call(ctx, err_ctor, zjs_undefined(), &err_msg, 1);
        // Capture the error flag immediately after the call — zjs_had_error is
        // sticky, so reading it later could reflect an unrelated earlier op.
        bool ctor_failed = zjs_had_error(ctx);
        // If Error construction somehow failed, fall back to throwing the
        // message string itself — still surfaces as a throw on the JS side.
        zjs_throw(ctx, ctor_failed ? err_msg : err);
        zjs_unpin(ctx);   // err_msg
        zjs_unpin(ctx);   // err_ctor
        free(method);
        return zjs_undefined();
    }

    JsonValue* args_jv = NULL;
    if (argc >= 2 && !zjs_is_undefined(argv[1]) && !zjs_is_null(argv[1])) {
        args_jv = zjsvalue_to_jsonvalue(slot, argv[1]);
    }

    void* app = app_get_active();
    const char* svc_result = app ? service_invoke_native(app, method, args_jv) : NULL;
    free(method);
    if (args_jv) json_free_tree(args_jv);

    if (!svc_result || svc_result[0] == '\0') return zjs_undefined();

    // Return walk: JSON.parse the service's output back into a ZjsValue.
    // Cached JSON.parse beats zjs_eval(ctx, "JSON.parse(...)") because
    // it avoids the parser + a string concat for the JS source.
    ZjsValue raw = zjs_new_string(ctx, svc_result, (uint32_t) strlen(svc_result));
    ZjsValue parsed = zjs_call(ctx, zjs_root_get(ctx, slot->json_parse_root),
                               zjs_undefined(), &raw, 1);
    zjs_drain_microtasks(ctx);
    if (zjs_had_error(ctx)) {
        // Bad JSON from a service — surface the raw string instead.
        return raw;
    }
    return parsed;
}

// ---------------------------------------------------------------------------
// __zappBridge.invokeServiceAsync(method, args?) -> int (request id)   [NIM BUILD]
//
// Async companion to invokeService. The worker thread does NOT block —
// it allocates a monotonic request id, strdups method + JSON-stringified
// args, then fires a GCD block to the main queue that calls the Nim entry
// zapp_worker_invoke_on_main (runs the real service handler with gCurrentApp,
// then delivers the result back via zjs_worker_eval_js → bridge._resolveInvoke).
// The JS bootstrap (Task 3) wraps the returned id in a Promise and stores
// { resolve, reject } in bridge._pendingInvokes[id].
//
// Gated to ZAPP_NIM_BUILD because the zc build's worker invoke uses the
// synchronous host path (zc async-from-worker is a future parity item).
// ---------------------------------------------------------------------------

#ifdef ZAPP_NIM_BUILD
extern void zapp_worker_invoke_on_main(const char* worker_id, int req_id,
                                       const char* method, const char* args_json);
static _Atomic int g_async_req_id = 1;

static ZjsValue host_invoke_service_async(ZjsContext* ctx, ZjsValue* argv, uint32_t argc) {
    ZjsWorkerSlot* slot = zjs_slot_for_ctx(ctx);
    if (!slot || argc < 1 || !zjs_is_string(argv[0])) return zjs_undefined();

    // Extract method — mirror host_invoke_service exactly.
    uint32_t method_len = 0;
    const char* method_bytes = zjs_string_bytes(argv[0], &method_len);
    if (!method_bytes) return zjs_undefined();
    char* method = (char*) malloc((size_t) method_len + 1);
    if (!method) return zjs_undefined();
    memcpy(method, method_bytes, method_len);
    method[method_len] = '\0';

    // Stringify args — mirror host_dispatch_event_to_all / host_post_to_webview:
    // call the cached JSON.stringify (json_stringify_root) on argv[1].
    // Falls back to strdup("null") when args is absent/undefined/null.
    char* args_json = NULL;
    if (argc >= 2 && !zjs_is_undefined(argv[1]) && !zjs_is_null(argv[1])) {
        ZjsValue stringified = zjs_call(ctx, zjs_root_get(ctx, slot->json_stringify_root),
                                        zjs_undefined(), &argv[1], 1);
        zjs_drain_microtasks(ctx);
        if (!zjs_had_error(ctx) && zjs_is_string(stringified)) {
            uint32_t plen = 0;
            const char* pbytes = zjs_string_bytes(stringified, &plen);
            if (pbytes) {
                args_json = (char*) malloc((size_t) plen + 1);
                if (args_json) {
                    memcpy(args_json, pbytes, plen);
                    args_json[plen] = '\0';
                }
            }
        }
    }
    if (!args_json) {
        args_json = strdup("null");
        if (!args_json) { free(method); return zjs_undefined(); }
    }

    // Allocate a monotonic request id (worker thread never blocks on this).
    int id = atomic_fetch_add(&g_async_req_id, 1);

    // Strdup worker_id for the block — slot->worker_id is stack-adjacent static
    // storage in the workers[] table; it is stable but we strdup for symmetry
    // with method/args_json (all three freed inside the block after the call).
    char* wid = strdup(slot->worker_id);
    if (!wid) { free(method); free(args_json); return zjs_undefined(); }

    dispatch_async(dispatch_get_main_queue(), ^{
        zapp_worker_invoke_on_main(wid, id, method, args_json);
        free(method);
        free(args_json);
        free(wid);
    });

    // Return the request id so the JS bootstrap can build a Promise around it.
    return zjs_int32(id);
}
#endif  // ZAPP_NIM_BUILD

// ---------------------------------------------------------------------------
// __zappBridge.listWorkers() -> string (JSON array of active workers)
//
// Worker-context Workers.list() on zjs. Returns the registry's JSON string
// verbatim; the JS runtime wrapper JSON.parses it (it accepts a string or a
// parsed array). Workers.list() is a rarely-called debug API, not a hot
// path, so returning the string keeps the native side minimal — no JS array
// value to build by hand. Returns "[]" (a valid empty array) on alloc
// failure so the JS side always gets something parseable.
// ---------------------------------------------------------------------------

static ZjsValue host_list_workers(ZjsContext* ctx, ZjsValue* argv, uint32_t argc) {
    (void) argv;
    (void) argc;
    char* json = zapp_workers_registry_list_json();
    if (!json) return zjs_new_string(ctx, "[]", 2);
    // zjs_new_string copies the bytes into engine-managed storage, so the
    // heap buffer is ours to free immediately after construction.
    ZjsValue result = zjs_new_string(ctx, json, (uint32_t) strlen(json));
    free(json);
    return result;
}

// ---------------------------------------------------------------------------
// __zappBridge.dispatchEventToAll(name: string, payload?: any) -> undefined
//
// Fire-and-forget broadcast. dispatch_event_to_all takes a JSON string,
// so the payload always needs serialising on the way out — no return
// path means a JsonValue tree-walk would just be extra work vs.
// calling the engine's own JSON.stringify (cached on the slot). The
// real perf wedge is invokeService (Z2); events stay simple.
// ---------------------------------------------------------------------------

static ZjsValue host_dispatch_event_to_all(ZjsContext* ctx, ZjsValue* argv, uint32_t argc) {
    if (argc < 1 || !zjs_is_string(argv[0])) return zjs_undefined();

    ZjsWorkerSlot* slot = zjs_slot_for_ctx(ctx);
    if (!slot) return zjs_undefined();

    uint32_t name_len = 0;
    const char* name_bytes = zjs_string_bytes(argv[0], &name_len);
    if (!name_bytes) return zjs_undefined();
    char* name = (char*) malloc((size_t) name_len + 1);
    if (!name) return zjs_undefined();
    memcpy(name, name_bytes, name_len);
    name[name_len] = '\0';

    // Default payload is "{}" so receivers don't crash on a missing field.
    // Real payload, if present, goes through __zappSafeStringify (JS-level
    // try/catch wrapper around JSON.stringify) so a stringify throw is
    // contained inside JS and never leaks back to the calling JS frame.
    char* payload = NULL;
    if (argc >= 2 && !zjs_is_undefined(argv[1]) && !zjs_is_null(argv[1])) {
        ZjsValue stringified = zjs_call(ctx, zjs_root_get(ctx, slot->json_stringify_root),
                                        zjs_undefined(), &argv[1], 1);
        zjs_drain_microtasks(ctx);
        if (!zjs_had_error(ctx) && zjs_is_string(stringified)) {
            uint32_t plen = 0;
            const char* pbytes = zjs_string_bytes(stringified, &plen);
            if (pbytes) {
                payload = (char*) malloc((size_t) plen + 1);
                if (payload) {
                    memcpy(payload, pbytes, plen);
                    payload[plen] = '\0';
                }
            }
        }
    }

    dispatch_event_to_all(name, payload ? payload : "{}");

    free(name);
    free(payload);
    return zjs_undefined();
}

// ---------------------------------------------------------------------------
// Worker → webview: postMessage / __zappBridge.postToWebview
//
// Worker code uses `self.postMessage(data)` directly (Web Worker
// convention) and the engine-agnostic bootstrap turns `self.send(ch,
// data)` into `self.postMessage({__zc: ch, d: data})` — so both
// channel-routed (`Workers.send`) and raw postMessage flows end up
// here. Reply hits the webview's `_messageHandlers` registry that
// bootstrap/webview.ts installs.
// ---------------------------------------------------------------------------

static ZjsValue host_post_to_webview(ZjsContext* ctx, ZjsValue* argv, uint32_t argc) {
    if (argc < 1) return zjs_undefined();
    ZjsWorkerSlot* slot = zjs_slot_for_ctx(ctx);
    if (!slot) return zjs_undefined();

    // The C side wants the worker_id + the payload as JSON. Allocate
    // a writable copy of worker_id because worker_dispatch_to_webview
    // takes non-const char*; allocate the JSON via cached
    // JSON.stringify when the payload is non-trivial.
    char* worker_id_copy = strdup(slot->worker_id);
    char* payload = NULL;

    if (!zjs_is_undefined(argv[0]) && !zjs_is_null(argv[0])) {
        ZjsValue stringified = zjs_call(ctx, zjs_root_get(ctx, slot->json_stringify_root),
                                        zjs_undefined(), &argv[0], 1);
        zjs_drain_microtasks(ctx);
        if (!zjs_had_error(ctx) && zjs_is_string(stringified)) {
            uint32_t plen = 0;
            const char* pbytes = zjs_string_bytes(stringified, &plen);
            if (pbytes) {
                payload = (char*) malloc((size_t) plen + 1);
                if (payload) {
                    memcpy(payload, pbytes, plen);
                    payload[plen] = '\0';
                }
            }
        }
    }

    worker_dispatch_to_webview(worker_id_copy, payload ? payload : (char*) "{}");

    free(worker_id_copy);
    free(payload);
    return zjs_undefined();
}

// ---------------------------------------------------------------------------
// Worker → worker: __zappBridge.postToWorker(targetId, data)
//
// Routes through the dispatcher (worker.zc → worker_post_message) so the
// target can be any engine. Used by `Workers.postMessage(id, data)` and
// (after channel wrapping) `Workers.send(id, channel, data)` from inside
// a worker. Same direction the dispatcher already handles for webview →
// worker; this lets workers talk to each other without a webview hop.
// ---------------------------------------------------------------------------

static ZjsValue host_post_to_worker(ZjsContext* ctx, ZjsValue* argv, uint32_t argc) {
    if (argc < 1 || !zjs_is_string(argv[0])) return zjs_undefined();
    ZjsWorkerSlot* slot = zjs_slot_for_ctx(ctx);
    if (!slot) return zjs_undefined();

    uint32_t id_len = 0;
    const char* id_bytes = zjs_string_bytes(argv[0], &id_len);
    if (!id_bytes) return zjs_undefined();
    char* target_id = (char*) malloc((size_t) id_len + 1);
    if (!target_id) return zjs_undefined();
    memcpy(target_id, id_bytes, id_len);
    target_id[id_len] = '\0';

    char* payload = NULL;
    if (argc >= 2 && !zjs_is_undefined(argv[1]) && !zjs_is_null(argv[1])) {
        ZjsValue stringified = zjs_call(ctx, zjs_root_get(ctx, slot->json_stringify_root),
                                        zjs_undefined(), &argv[1], 1);
        zjs_drain_microtasks(ctx);
        if (!zjs_had_error(ctx) && zjs_is_string(stringified)) {
            uint32_t plen = 0;
            const char* pbytes = zjs_string_bytes(stringified, &plen);
            if (pbytes) {
                payload = (char*) malloc((size_t) plen + 1);
                if (payload) {
                    memcpy(payload, pbytes, plen);
                    payload[plen] = '\0';
                }
            }
        }
    }

    // worker_post_message takes ownership of neither pointer — it copies
    // internally and signals the target's inbox async. Free both here.
    worker_post_message(target_id, payload ? payload : (char*) "{}");

    free(target_id);
    free(payload);
    return zjs_undefined();
}

// ---------------------------------------------------------------------------
// __zappBridge.workerCrash(message, stack) — bootstrap calls this when an
// uncaught error escapes a setTimeout / setInterval callback or a channel
// handler. We broadcast `worker:crashed` so observers (UI, telemetry) can
// react, then ask the supervisor to bump fail_count against the worker's
// restart policy — once the configured cap is hit the supervisor fires
// `worker:gave-up`. Same shape bare.c / txiki.c use.
// ---------------------------------------------------------------------------

static char* zjs_stringify_to_dup(ZjsContext* ctx, ZjsWorkerSlot* slot, ZjsValue v) {
    ZjsValue stringified = zjs_call(ctx, zjs_root_get(ctx, slot->json_stringify_root),
                                    zjs_undefined(), &v, 1);
    zjs_drain_microtasks(ctx);
    if (zjs_had_error(ctx) || !zjs_is_string(stringified)) return NULL;
    uint32_t len = 0;
    const char* bytes = zjs_string_bytes(stringified, &len);
    if (!bytes) return NULL;
    char* out = (char*) malloc((size_t) len + 1);
    if (!out) return NULL;
    memcpy(out, bytes, len);
    out[len] = '\0';
    return out;
}

static ZjsValue host_worker_crash(ZjsContext* ctx, ZjsValue* argv, uint32_t argc) {
    ZjsWorkerSlot* slot = zjs_slot_for_ctx(ctx);
    if (!slot) return zjs_undefined();

    // JSON.stringify produces quoted, escaped JSON strings — splice them in
    // as values directly. Empty defaults so the payload always parses.
    char* msg_json   = (argc >= 1) ? zjs_stringify_to_dup(ctx, slot, argv[0]) : NULL;
    char* stack_json = (argc >= 2) ? zjs_stringify_to_dup(ctx, slot, argv[1]) : NULL;
    const char* msg_v   = msg_json   ? msg_json   : "\"\"";
    const char* stack_v = stack_json ? stack_json : "\"\"";

    size_t need = strlen(slot->worker_id) + strlen(msg_v) + strlen(stack_v) + 64;
    char* payload = (char*) malloc(need);
    if (payload) {
        snprintf(payload, need,
                 "{\"id\":\"%s\",\"message\":%s,\"stack\":%s,\"incarnation\":%d}",
                 slot->worker_id, msg_v, stack_v, slot->incarnation);
        dispatch_event_to_all("worker:crashed", payload);
        free(payload);
    }

    int decision = zapp_worker_supervisor_record_failure(slot->worker_id);
    if (decision == 1) {
        // Restart approved. Signal the outer loop in zjs_worker_thread
        // to break the inner loop and re-incarnate the JS state. The
        // worker:restarted event fires from there after setup_state
        // completes for the next incarnation.
        atomic_store(&slot->wants_restart, 1);
#if defined(__APPLE__)
        if (slot->kq_initialized) apple_trigger_shutdown(slot);
#else
        uv_async_send(&slot->shutdown_async);
#endif
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

    free(msg_json);
    free(stack_json);
    return zjs_undefined();
}

static ZjsValue host_console_log(ZjsContext* ctx, ZjsValue* argv, uint32_t argc) {
    // Worker console is the app's OWN output — always shown, never gated by
    // verbosity. Prefix with the registry display name ([zapp/<worker>]) the
    // same way the lifecycle log sites do, mapping ctx -> slot via the shared
    // zjs_slot_for_ctx helper (host fns only receive ctx, not the slot).
    ZjsWorkerSlot* cslot = zjs_slot_for_ctx(ctx);
    const char* cwid = cslot ? cslot->worker_id : "?";
    fprintf(stderr, "[zapp/%s]", zapp_worker_registry_get_display_name(cwid));
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

static void zjs_setup_bridge(ZjsWorkerSlot* slot) {
    ZjsContext* ctx = slot->ctx;

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

    // Cache Object.keys + JSON.parse handles for the value walker. Doing
    // this once at setup beats looking them up on every invokeService
    // call; both are tiny zjs_get_global lookups but the savings add up
    // on high-rate workloads.
    slot->object_keys_root    = zjs_root(ctx, zjs_eval(ctx, "Object.keys"));
    slot->json_parse_root     = zjs_root(ctx, zjs_eval(ctx, "JSON.parse"));
    // Wrap JSON.stringify in a JS-level try/catch so host functions that
    // serialise a payload never leak a pending error back to the calling
    // JS frame. There's no zjs_clear_error API, so the only way to keep
    // the host-call boundary clean is to handle the throw on the JS side.
    // Returns `null` on failure; the host fn then falls back to "{}".
    //
    // Assigned to a global first, then rooted, rather than expression-eval'd
    // inline — zjs_eval of `(function(){...})` doesn't always return the
    // function value (depends on whether the engine treats the snippet as
    // an expression or a statement), but `globalThis.X = fn; globalThis.X`
    // is unambiguous.
    zjs_eval(ctx,
        "globalThis.__zappSafeStringify = function (v) {"
        "  try { return JSON.stringify(v); } catch (_) { return null; }"
        "};");
    slot->json_stringify_root = zjs_root(ctx, zjs_eval(ctx, "globalThis.__zappSafeStringify"));

    // Install the message dispatcher shim — called from on_inbox_async
    // when a cross-thread postMessage lands. Routes through onmessage +
    // _messageHandlers, same surface bare-worker.ts installs for bare
    // engines (via __zappBridge._dispatchMessage). We attach as a
    // top-level fn rather than on the bridge so the on_inbox_async
    // call path doesn't have to walk through __zappBridge each time.
    zjs_eval(ctx,
        "globalThis.__zapp_dispatch_message = function (rawJson) {"
        "  var data = rawJson;"
        "  try { data = JSON.parse(rawJson); } catch (_) {}"
        "  var ev = { data: data };"
        "  if (typeof globalThis.onmessage === 'function') {"
        "    try { globalThis.onmessage(ev); }"
        "    catch (e) { console.error('[zapp] onmessage threw:', e); }"
        "  }"
        "  var hs = globalThis._messageHandlers;"
        "  if (Array.isArray(hs)) {"
        "    for (var i = 0; i < hs.length; i++) {"
        "      try { hs[i](ev); }"
        "      catch (e) { console.error('[zapp] message handler threw:', e); }"
        "    }"
        "  }"
        "};");
    slot->dispatch_message_root = zjs_root(ctx, zjs_eval(ctx, "globalThis.__zapp_dispatch_message"));

    // globalThis.__zappBridge — the engine-agnostic host surface. zjs
    // gets the direct value-path invokeService; bare/jsc/txiki get the
    // JSON-stringifying wrapper in their per-engine bootstraps. Same
    // public API (`b.invokeService(method, args)`) either way.
    ZjsValue bridge = zjs_new_object(ctx);
    ZjsValue invoke_fn = zjs_register_host_function(ctx, "__zapp_invoke_service",
                                                    host_invoke_service);
    ZjsValue emit_fn   = zjs_register_host_function(ctx, "__zapp_dispatch_event",
                                                    host_dispatch_event_to_all);
    ZjsValue post_fn   = zjs_register_host_function(ctx, "__zapp_post_to_webview",
                                                    host_post_to_webview);
    ZjsValue post_worker_fn = zjs_register_host_function(ctx, "__zapp_post_to_worker",
                                                        host_post_to_worker);
    ZjsValue crash_fn  = zjs_register_host_function(ctx, "__zapp_worker_crash",
                                                    host_worker_crash);
    ZjsValue list_fn   = zjs_register_host_function(ctx, "__zapp_list_workers",
                                                    host_list_workers);
    zjs_set_property(ctx, bridge, "invokeService",      invoke_fn);
    zjs_set_property(ctx, bridge, "dispatchEventToAll", emit_fn);
    // Alias to match the legacy name some runtime code still uses.
    zjs_set_property(ctx, bridge, "emitToHost",         emit_fn);
    zjs_set_property(ctx, bridge, "postToWebview",      post_fn);
    zjs_set_property(ctx, bridge, "postToWorker",       post_worker_fn);
    zjs_set_property(ctx, bridge, "workerCrash",        crash_fn);
    zjs_set_property(ctx, bridge, "listWorkers",        list_fn);
#ifdef ZAPP_NIM_BUILD
    // Async invoke — marshals to the main thread via GCD; JS side wraps the
    // returned request id in a Promise and stores resolve/reject in
    // bridge._pendingInvokes[id]. Main resolves via bridge._resolveInvoke.
    ZjsValue invoke_async_fn = zjs_register_host_function(ctx, "__zapp_invoke_service_async",
                                                          host_invoke_service_async);
    zjs_set_property(ctx, bridge, "invokeServiceAsync", invoke_async_fn);
#endif  // ZAPP_NIM_BUILD
    // workerId — bench harness + bare-worker.ts sync-coordination both
    // read `bridge.workerId` to identify the slot. Bare/jsc/txiki set
    // the same property; mirror here so engine-agnostic bootstrap +
    // diagnostic tooling work uniformly.
    ZjsValue wid_str = zjs_new_string(ctx, slot->worker_id, (uint32_t) strlen(slot->worker_id));
    zjs_set_property(ctx, bridge, "workerId", wid_str);
    zjs_set_global(ctx, "__zappBridge", bridge);
    // Web Worker convention — bootstrap/worker.ts's `self.send` routes
    // through `self.postMessage`, so wire the same host function up as a
    // global. Same direction (worker → webview), same payload shape.
    zjs_set_global(ctx, "postMessage", post_fn);
}

// ---------------------------------------------------------------------------
// Loop integration — Apple uses kqueue + CFRunLoop with inline drain
// helpers; non-Apple targets use libuv callbacks (definitions below).
// ---------------------------------------------------------------------------

// Cap on entries drained per inbox fire. Without it the `while (pop)`
// loop starves the worker's own JS thread when several other workers
// are emitting at high frequency: new IIFEs land in the inbox during
// the drain itself, the loop never exits, and the bench loop (or any
// foreground work) makes no forward progress. Capping yields back to
// the loop between batches; if entries remain we re-arm the trigger so
// the next loop tick picks up the rest. 32 was picked empirically —
// large enough to amortise the fire cost, small enough to keep response
// latency tight when broadcasts spike.
#define ZJS_EVAL_INBOX_DRAIN_BATCH 32

#if defined(__APPLE__)
// Apple drain helpers — called from the kqueue+CFRunLoop main loop in
// zjs_worker_thread after kevent() returns a triggered FILTER_INBOX /
// FILTER_EVAL_INBOX event. Same body as the libuv on_*_async callbacks
// below, minus the `(ZjsWorkerSlot*) h->data` unpack at the top.
// (apple_trigger_* forward decls live near the slot table at the top.)

static void drain_inbox_apple(ZjsWorkerSlot* slot) {
    if (atomic_load(&slot->wants_terminate)) return;

    char* msg;
    while ((msg = inbox_pop(slot)) != NULL) {
        ZjsValue arg = zjs_new_string(slot->ctx, msg, (uint32_t) strlen(msg));
        ZjsValue dispatch = zjs_root_get(slot->ctx, slot->dispatch_message_root);
        zjs_call(slot->ctx, dispatch, zjs_undefined(), &arg, 1);
        zjs_drain_microtasks(slot->ctx);
        if (zjs_had_error(slot->ctx)) {
            ZjsValue err = zjs_get_error(slot->ctx);
            uint32_t len = 0;
            ZjsValue mv = zjs_get_property(slot->ctx, err, "message");
            const char* m = zjs_is_string(mv)
                ? zjs_string_bytes(mv, &len)
                : zjs_string_bytes(err, &len);
            fprintf(stderr, "[zapp/%s] message handler threw: %.*s\n",
                zapp_worker_registry_get_display_name(slot->worker_id),
                (int) len, m ? m : "<unreadable>");
        }
        free(msg);
    }
}

static void drain_eval_inbox_apple(ZjsWorkerSlot* slot) {
    if (atomic_load(&slot->wants_terminate)) return;

    char* js;
    int drained = 0;
    while (drained < ZJS_EVAL_INBOX_DRAIN_BATCH && (js = eval_inbox_pop(slot)) != NULL) {
        zjs_eval(slot->ctx, js);
        zjs_drain_microtasks(slot->ctx);
        if (zjs_had_error(slot->ctx)) {
            ZjsValue err = zjs_get_error(slot->ctx);
            uint32_t len = 0;
            ZjsValue mv = zjs_get_property(slot->ctx, err, "message");
            const char* m = zjs_is_string(mv)
                ? zjs_string_bytes(mv, &len)
                : zjs_string_bytes(err, &len);
            fprintf(stderr, "[zapp/%s] broadcast eval threw: %.*s\n",
                zapp_worker_registry_get_display_name(slot->worker_id),
                (int) len, m ? m : "<unreadable>");
        }
        free(js);
        drained++;
    }

    // If we hit the batch cap and the inbox still has entries, re-arm
    // the EVFILT_USER trigger so the next kevent() drain picks it up.
    // Bounded peek under the inbox mutex so we don't race with a
    // producer push.
    pthread_mutex_lock(&slot->eval_inbox_mutex);
    int remaining = slot->eval_inbox_count;
    pthread_mutex_unlock(&slot->eval_inbox_mutex);
    if (remaining > 0) {
        apple_trigger_eval_inbox(slot);
    }
}

// Tiny kevent trigger helpers — one per EVFILT_USER ident. Used from
// both the worker thread (re-arm on batch overflow) and any thread
// that signals the worker (zjs_worker_post_message, terminate, etc).
// EV_CLEAR | NOTE_TRIGGER is the documented one-shot wake pattern.
//
// Note: callers guard each trigger with `slot->kq_initialized` (or
// `slot->loop_initialized` on libuv) under `zjs_workers_mutex`, but
// the worker thread mutates that flag inside teardown_state WITHOUT
// holding the workers mutex — so a trigger call can race a teardown.
// On Apple the worst case is kevent() against a closed fd returning
// EBADF, which is harmless; on libuv, uv_async_send against a closed
// handle is undefined behavior. The pattern is preserved from the
// libuv path; tightening it is out of scope for this commit.
static void apple_trigger_inbox(ZjsWorkerSlot* slot) {
    struct kevent trigger;
    EV_SET(&trigger, FILTER_INBOX, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    kevent(slot->kq, &trigger, 1, NULL, 0, NULL);
}

static void apple_trigger_eval_inbox(ZjsWorkerSlot* slot) {
    struct kevent trigger;
    EV_SET(&trigger, FILTER_EVAL_INBOX, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    kevent(slot->kq, &trigger, 1, NULL, 0, NULL);
}

static void apple_trigger_shutdown(ZjsWorkerSlot* slot) {
    struct kevent trigger;
    EV_SET(&trigger, FILTER_SHUTDOWN, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    kevent(slot->kq, &trigger, 1, NULL, 0, NULL);
}
#endif // __APPLE__

#if !defined(__APPLE__)
// ---------------------------------------------------------------------------
// libuv loop integration (Linux / Windows). Apple targets use the
// kqueue + CFRunLoop helpers above.
// ---------------------------------------------------------------------------

// Forward decl — the timer callback and the check handle share the
// same pump (see the phase-ordering note on zjs_pump below).
static void zjs_pump(ZjsWorkerSlot* slot);

static void on_zjs_wake(uv_timer_t* h) {
    ZjsWorkerSlot* s = (ZjsWorkerSlot*) h->data;
    // The drain MUST happen here, not only in the check handle: libuv
    // runs check handles AFTER the poll phase, and once this one-shot
    // timer is consumed the poll timeout computes as infinite (only
    // async handles remain) — the loop blocks before the check phase
    // ever runs. Symptom: a fetch whose wake timer fired still never
    // resolved until unrelated traffic (a ping) tripped an async and
    // let the iteration complete.
    zjs_pump(s);
}

// Fires when zjs_worker_terminate (or terminate_owner) sets
// wants_terminate. We stop the loop here — the on_check tick also bails,
// and the teardown label after uv_run handles the close calls. Splitting
// the signaling (uv_async_send is thread-safe) from the actual teardown
// (only the worker thread touches its handles) keeps the locking story
// simple — no mutex around the loop itself.
static void on_shutdown_async(uv_async_t* h) {
    ZjsWorkerSlot* slot = (ZjsWorkerSlot*) h->data;
    uv_stop(&slot->loop);
}

// Drain the inbox and dispatch each message into JS. Runs on the worker
// thread (libuv async-callback contract). The dispatcher itself is a
// small JS shim cached at bridge-setup time — it parses the JSON and
// fans out to globalThis.onmessage + _messageHandlers, same shape the
// bare engines get from bare-worker.ts's _dispatchMessage helper.
//
// One uv_async_send may coalesce multiple post_message calls into a
// single firing — that's the documented uv behaviour and exactly why
// the inbox is a queue, not a single slot.
static void on_inbox_async(uv_async_t* h) {
    ZjsWorkerSlot* slot = (ZjsWorkerSlot*) h->data;
    if (atomic_load(&slot->wants_terminate)) return;

    char* msg;
    while ((msg = inbox_pop(slot)) != NULL) {
        ZjsValue arg = zjs_new_string(slot->ctx, msg, (uint32_t) strlen(msg));
        ZjsValue dispatch = zjs_root_get(slot->ctx, slot->dispatch_message_root);
        zjs_call(slot->ctx, dispatch, zjs_undefined(), &arg, 1);
        zjs_drain_microtasks(slot->ctx);
        if (zjs_had_error(slot->ctx)) {
            ZjsValue err = zjs_get_error(slot->ctx);
            uint32_t len = 0;
            ZjsValue mv = zjs_get_property(slot->ctx, err, "message");
            const char* m = zjs_is_string(mv)
                ? zjs_string_bytes(mv, &len)
                : zjs_string_bytes(err, &len);
            fprintf(stderr, "[zapp/%s] message handler threw: %.*s\n",
                zapp_worker_registry_get_display_name(slot->worker_id),
                (int) len, m ? m : "<unreadable>");
        }
        free(msg);
    }
}

// Drains JS snippets pushed by dispatch_event_to_all → zjs_broadcast_eval_js.
// Each entry is a self-invoking IIFE that calls `bridge._onEvent(name,
// payload)` — same shape webviews / bare workers / txiki workers see.
static void on_eval_inbox_async(uv_async_t* h) {
    ZjsWorkerSlot* slot = (ZjsWorkerSlot*) h->data;
    if (atomic_load(&slot->wants_terminate)) return;

    char* js;
    int drained = 0;
    while (drained < ZJS_EVAL_INBOX_DRAIN_BATCH && (js = eval_inbox_pop(slot)) != NULL) {
        zjs_eval(slot->ctx, js);
        zjs_drain_microtasks(slot->ctx);
        if (zjs_had_error(slot->ctx)) {
            ZjsValue err = zjs_get_error(slot->ctx);
            uint32_t len = 0;
            ZjsValue mv = zjs_get_property(slot->ctx, err, "message");
            const char* m = zjs_is_string(mv)
                ? zjs_string_bytes(mv, &len)
                : zjs_string_bytes(err, &len);
            fprintf(stderr, "[zapp/%s] broadcast eval threw: %.*s\n",
                zapp_worker_registry_get_display_name(slot->worker_id),
                (int) len, m ? m : "<unreadable>");
        }
        free(js);
        drained++;
    }

    // If we hit the batch cap and the inbox still has entries, re-arm
    // the async so libuv schedules another fire next iteration. Bounded
    // peek under the inbox mutex so we don't race with a producer push.
    pthread_mutex_lock(&slot->eval_inbox_mutex);
    int remaining = slot->eval_inbox_count;
    pthread_mutex_unlock(&slot->eval_inbox_mutex);
    if (remaining > 0) {
        uv_async_send(&slot->eval_inbox_async);
    }
}

// Shared drain + re-arm. Called from BOTH the wake-timer callback and
// the check handle:
//   - on_zjs_wake: timers/IO due — drain NOW, because once the
//     one-shot timer is consumed the poll phase blocks indefinitely
//     and the check phase (which runs post-poll) is unreachable.
//   - on_check: runs whenever the loop iterates for any other reason
//     (inbox/eval asyncs) so JS activity from those paths re-arms the
//     wake timer for whatever it scheduled.
static void zjs_pump(ZjsWorkerSlot* slot) {
    if (atomic_load(&slot->wants_terminate)) return;

    zjs_run_pending_timers(slot->ctx);

    if (zjs_had_error(slot->ctx)) {
        ZjsValue err = zjs_get_error(slot->ctx);
        uint32_t len = 0;
        const char* msg = zjs_string_bytes(err, &len);
        fprintf(stderr, "[zapp/%s] timer threw: %.*s\n",
            zapp_worker_registry_get_display_name(slot->worker_id),
            (int) len, msg ? msg : "<non-string throw>");
        // Surface but keep running — matches txiki / bare behaviour, where
        // a single throw in a setInterval cb doesn't tear the worker down.
    }

    int64_t next_ms = zjs_next_timer_ms(slot->ctx);
    if (next_ms < 0) {
        // No timers — but zjs's polling contract surfaces in-flight
        // async I/O (fetch / WebSocket / net) through has_pending_work,
        // and completions only drain inside zjs_run_pending_timers.
        // Without this, a worker whose script holds an in-flight fetch
        // but registered no timers parks the uv loop forever and the
        // response never resolves (the bug class: fetch works in a
        // worker WITH a setInterval, hangs in one without). Poll at
        // 10ms while I/O is outstanding; stay fully idle otherwise.
        if (!zjs_has_pending_work(slot->ctx)) return;   // truly idle
        next_ms = 10;
    }
    if (next_ms == 0) next_ms = 1;       // uv_timer_start treats 0 specially
    uv_timer_start(&slot->zjs_wake, on_zjs_wake, (uint64_t) next_ms, 0);
}

static void on_check(uv_check_t* h) {
    ZjsWorkerSlot* slot = (ZjsWorkerSlot*) h->data;
    zjs_pump(slot);
}
#endif // !__APPLE__

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
                if (zapp_log_level >= 1) {
                    fprintf(stderr, "[zapp] zjs worker script loaded from embedded: %s\n", script_url);
                }
                break;
            }
        }
    }

    if (!code) {
        // "rb", not "r": on Windows text mode translates CRLF and stops
        // at Ctrl-Z, so fread returns fewer bytes than ftell's length
        // for any binary artifact (.zbc bytecode) — the strict length
        // check below then frees the buffer and the load reports
        // "script not found". POSIX ignores the 'b'.
        FILE* f = fopen(script_path, "rb");
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
                    if (zapp_log_level >= 1) {
                        fprintf(stderr, "[zapp] zjs worker script loaded: %s\n", script_path);
                    }
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
                if (zapp_log_level >= 1) {
                    fprintf(stderr, "[zapp] zjs worker loaded from dev server: %s\n", full_url);
                }
            }
        }
    }
#endif

    if (out_len) *out_len = code_len;
    return code;
}

// ---------------------------------------------------------------------------
// Worker thread — owns its event loop (kqueue+CFRunLoop on Apple,
// uv_loop_t elsewhere) + ZjsContext for the lifetime of the worker.
// The slot.active flag is the authoritative "this worker is up"
// state; the supervisor / dispatch path uses it to gate routing.
// ---------------------------------------------------------------------------

// setup_state outcome — drives the outer reincarnation loop in later tasks.
// In this task only ZJS_SETUP_OK and ZJS_SETUP_FATAL are returned; the
// CRASHED variant is wired up in Task 1.5 (post-eval error check).
typedef enum {
    ZJS_SETUP_OK = 0,         // ctx + bridge + bootstrap + script eval all OK
    ZJS_SETUP_CRASHED = 1,    // script eval threw; host_worker_crash already called
    ZJS_SETUP_FATAL = 2,      // zjs_new_context failed — unrecoverable
} ZjsSetupResult;

static ZjsSetupResult zjs_worker_setup_state(ZjsWorkerSlot* slot);
static void zjs_worker_teardown_state(ZjsWorkerSlot* slot, int keep_loop);

// Synthetic crash signal — called from setup_state when zjs_eval_module_source /
// zjs_eval_bytecode returns an error at top level, or when zjs_load_script
// fails to find the file. Mirrors host_worker_crash's dispatch + supervisor
// handshake without needing a live JS frame.
//
// Caller returns ZJS_SETUP_CRASHED so the outer loop in zjs_worker_thread
// teardown + iterate per verdict.
extern char* zapp_escape_dup(const char* s);  // bridge/dispatch.zc

static void zjs_setup_synthesize_crash(ZjsWorkerSlot* slot,
                                       const char* msg,
                                       const char* stack) {
    size_t mlen = msg ? strlen(msg) : 0;
    size_t slen = stack ? strlen(stack) : 0;
    size_t need = strlen(slot->worker_id) + mlen + slen + 128;
    char* payload = (char*) malloc(need);
    if (payload) {
        char* msg_esc   = zapp_escape_dup(msg   ? msg   : "");
        char* stack_esc = zapp_escape_dup(stack ? stack : "");
        snprintf(payload, need,
                 "{\"id\":\"%s\",\"message\":\"%s\",\"stack\":\"%s\",\"incarnation\":%d}",
                 slot->worker_id,
                 msg_esc   ? msg_esc   : "",
                 stack_esc ? stack_esc : "",
                 slot->incarnation);
        dispatch_event_to_all("worker:crashed", payload);
        free(msg_esc);
        free(stack_esc);
        free(payload);
    }

    int decision = zapp_worker_supervisor_record_failure(slot->worker_id);
    if (decision == 1) {
        atomic_store(&slot->wants_restart, 1);
        // No uv_async_send here — we're inside setup_state, not running
        // the loop yet. The outer while-loop in zjs_worker_thread sees
        // SETUP_CRASHED return value and proceeds to teardown + iterate
        // without entering uv_run.
    } else if (decision == 2) {
        char gp[256];
        snprintf(gp, sizeof(gp),
                 "{\"id\":\"%s\",\"finalIncarnation\":%d,\"retriesAttempted\":%d}",
                 slot->worker_id, slot->incarnation,
                 slot->incarnation > 0 ? slot->incarnation - 1 : 0);
        dispatch_event_to_all("worker:gave-up", gp);
    }
    // decision == 0: no policy; setup_state caller still gets CRASHED but
    // wants_restart stays 0, so the while-loop breaks and the worker exits.
}

static ZjsSetupResult zjs_worker_setup_state(ZjsWorkerSlot* slot) {
    slot->ctx = zjs_new_context();
    if (!slot->ctx) {
        fprintf(stderr, "[zapp/%s] zjs_new_context failed\n",
            zapp_worker_registry_get_display_name(slot->worker_id));
        return ZJS_SETUP_FATAL;
    }

    // Bridge first, then user script. The user script may call host
    // functions during top-level execution (Services.invokeSync from
    // module scope is a real pattern), so console.log + invokeService
    // must be reachable before the eval runs.
    zjs_setup_bridge(slot);

    // Engine-agnostic worker bootstrap — installs the JS-side surface
    // every Zapp worker expects: self.send / self.receive (channel
    // routing), getBridge()'s `Symbol.for("zapp.bridge")` lookup,
    // _dispatchAppEvent, dispatchSyncResult, the setInterval/setTimeout
    // crash wrappers, _onEvent.
    //
    // Same script bare-* engines run via their per-engine bootstrap
    // path. zjs already has the C-side host bridge installed on
    // globalThis as __zappBridge — this script adapts that surface to
    // the runtime API (Symbol.for("zapp.bridge"), self.send, etc).
    //
    // zjs is a generic embed engine and doesn't provide the Web Worker
    // `self` global out of the box. The bootstrap (and most worker
    // payloads adopting Web Worker conventions) reads `self` heavily,
    // so alias it to globalThis here once before running the bootstrap.
    zjs_eval(slot->ctx, "var self = globalThis;");
    if (zjs_had_error(slot->ctx)) {
        fprintf(stderr, "[zapp/%s] could not install `self` alias\n",
            zapp_worker_registry_get_display_name(slot->worker_id));
    }

    {
        extern const char* zapp_worker_bootstrap_script(void);
        const char* boot = zapp_worker_bootstrap_script();
        if (boot && boot[0] != '\0') {
            zjs_eval(slot->ctx, boot);
            // zjs exposes setTimeout / setInterval / clearTimeout /
            // clearInterval as **lexical** globals — distinct slots from
            // `globalThis.setTimeout` etc. The bootstrap's wrap reassigns
            // the `globalThis` properties (the convention bare/jsc/txiki
            // honour), but user code's bare `setTimeout(...)` resolves
            // via the lexical binding, which still points at the raw
            // un-wrapped original. Result: throws in setTimeout callbacks
            // skip `bridge.workerCrash` and surface in the engine's error
            // handler with no supervisor reporting.
            //
            // Re-point the lexical bindings at the wrapped versions the
            // bootstrap installed on globalThis so the user-visible
            // identifier and the wrap line up. Wrapped in try/catch so a
            // future zjs change to const-bindings doesn't break startup.
            zjs_eval(slot->ctx,
                "try { setTimeout = globalThis.setTimeout; } catch (_) {}"
                "try { setInterval = globalThis.setInterval; } catch (_) {}"
                "try { clearTimeout = globalThis.clearTimeout; } catch (_) {}"
                "try { clearInterval = globalThis.clearInterval; } catch (_) {}");

            if (zjs_had_error(slot->ctx)) {
                ZjsValue err = zjs_get_error(slot->ctx);
                uint32_t mlen = 0;
                ZjsValue mv = zjs_get_property(slot->ctx, err, "message");
                const char* m = zjs_is_string(mv)
                    ? zjs_string_bytes(mv, &mlen)
                    : zjs_string_bytes(err, &mlen);
                fprintf(stderr, "[zapp/%s] bootstrap threw: %.*s\n",
                    zapp_worker_registry_get_display_name(slot->worker_id),
                    (int) mlen, m ? m : "<unreadable>");
                // Continue anyway — partial bootstrap may still be useful
                // for diagnostics; the user script just won't have full
                // bridge access.
            }
        }
    }

    // Hook the loop wiring BEFORE eval so any setInterval / setTimeout
    // the script registers immediately gets pumped from the first tick.
#if defined(__APPLE__)
    // kqueue fd + three EVFILT_USER triggers (one per signal channel).
    // EV_CLEAR makes each trigger one-shot — coalesces back-to-back
    // signals into a single wake, matching uv_async_send semantics.
    slot->kq = kqueue();
    if (slot->kq < 0) {
        fprintf(stderr, "[zapp/%s] kqueue() failed: %s\n",
                zapp_worker_registry_get_display_name(slot->worker_id), strerror(errno));
        return ZJS_SETUP_FATAL;
    }
    slot->kq_initialized = 1;
    {
        struct kevent change[3];
        EV_SET(&change[0], FILTER_SHUTDOWN,   EVFILT_USER, EV_ADD|EV_CLEAR, 0, 0, NULL);
        EV_SET(&change[1], FILTER_INBOX,      EVFILT_USER, EV_ADD|EV_CLEAR, 0, 0, NULL);
        EV_SET(&change[2], FILTER_EVAL_INBOX, EVFILT_USER, EV_ADD|EV_CLEAR, 0, 0, NULL);
        if (kevent(slot->kq, change, 3, NULL, 0, NULL) < 0) {
            fprintf(stderr, "[zapp/%s] kevent EV_ADD failed: %s\n",
                    zapp_worker_registry_get_display_name(slot->worker_id), strerror(errno));
            close(slot->kq);
            slot->kq = -1;
            slot->kq_initialized = 0;
            return ZJS_SETUP_FATAL;
        }
    }
    pthread_mutex_init(&slot->inbox_mutex, NULL);
    pthread_mutex_init(&slot->eval_inbox_mutex, NULL);
#else
    uv_check_init(&slot->loop, &slot->check);
    slot->check.data = slot;
    uv_check_start(&slot->check, on_check);

    uv_timer_init(&slot->loop, &slot->zjs_wake);
    slot->zjs_wake.data = slot;

    uv_async_init(&slot->loop, &slot->shutdown_async, on_shutdown_async);
    slot->shutdown_async.data = slot;

    pthread_mutex_init(&slot->inbox_mutex, NULL);
    uv_async_init(&slot->loop, &slot->inbox_async, on_inbox_async);
    slot->inbox_async.data = slot;

    pthread_mutex_init(&slot->eval_inbox_mutex, NULL);
    uv_async_init(&slot->loop, &slot->eval_inbox_async, on_eval_inbox_async);
    slot->eval_inbox_async.data = slot;
#endif

    long  code_len = 0;
    char* code = zjs_load_script(slot->script_url, &code_len);
    if (!code) {
        fprintf(stderr, "[zapp/%s] script not found: %s\n",
            zapp_worker_registry_get_display_name(slot->worker_id), slot->script_url);
        zjs_setup_synthesize_crash(slot, "script load failed", "");
        return ZJS_SETUP_CRASHED;
    }

    // Two evaluation paths depending on the worker artifact format:
    //
    //   `.zbc` (zjs bytecode) — produced when the user opts into
    //     `bytecode: true` in zapp.config.ts and the CLI ran `zjs
    //     compile` after Vite bundled the source. We dispatch via
    //     zjs_eval_bytecode, which deserializes the buffer (magic
    //     header "ZJSb" verified internally) and runs it without a
    //     parse pass. Parse-free start is the perf win, especially
    //     on iOS where JIT is gated.
    //
    //   `.mjs` (everything else) — Vite-bundled source. Eval via
    //     zjs_eval_module_source (ESM semantics, microtask drain per
    //     module evaluation per spec). The virtual_path arg is the
    //     module cache key — using the canonical worker URL (e.g.
    //     "/_workers/_headless_ticker.mjs") ensures a second spawn
    //     of the same worker reuses the cached module if the source
    //     hasn't changed. Bundle is in-memory already (loaded by
    //     zjs_load_script via embedded asset / filesystem / dev URL),
    //     so the _source entry skips the disk hop the path-based
    //     zjs_eval_module would have to do.
    int is_bytecode = 0;
    {
        const char* dot = strrchr(slot->script_url, '.');
        if (dot && strcmp(dot, ".zbc") == 0) is_bytecode = 1;
    }
    if (is_bytecode) {
        zjs_eval_bytecode(slot->ctx, (const unsigned char*) code, (size_t) code_len);
    } else {
        zjs_eval_module_source(slot->ctx, code, (size_t) code_len, slot->script_url);
    }
    if (zjs_had_error(slot->ctx)) {
        ZjsValue err = zjs_get_error(slot->ctx);
        const char* msg = NULL;
        uint32_t    len = 0;
        ZjsValue    msg_val = zjs_get_property(slot->ctx, err, "message");
        if (zjs_is_string(msg_val)) msg = zjs_string_bytes(msg_val, &len);
        if (!msg) msg = zjs_string_bytes(err, &len);
        if (!msg) {
            zjs_set_global(slot->ctx, "__zapp_err_tmp", err);
            ZjsValue str = zjs_eval(slot->ctx, "String(__zapp_err_tmp)");
            msg = zjs_string_bytes(str, &len);
        }
        const char* stack = NULL;
        uint32_t    slen  = 0;
        ZjsValue    stack_val = zjs_get_property(slot->ctx, err, "stack");
        if (zjs_is_string(stack_val)) stack = zjs_string_bytes(stack_val, &slen);

        fprintf(stderr, "[zapp/%s] script threw: %.*s%s%.*s\n",
            zapp_worker_registry_get_display_name(slot->worker_id),
            (int) len, msg ? msg : "<unreadable>",
            stack ? "\n" : "",
            (int) slen, stack ? stack : "");

        // Copy to NUL-terminated buffers — zjs_string_bytes returns length-
        // counted, not NUL-terminated, so we need a local buffer to safely
        // pass to zjs_setup_synthesize_crash (which expects C-strings).
        char msg_buf[1024]   = {0};
        char stack_buf[4096] = {0};
        if (msg)   { size_t cp = len  < sizeof(msg_buf)   - 1 ? len  : sizeof(msg_buf)   - 1; memcpy(msg_buf,   msg,   cp); }
        if (stack) { size_t cp = slen < sizeof(stack_buf) - 1 ? slen : sizeof(stack_buf) - 1; memcpy(stack_buf, stack, cp); }

        free(code);
        zjs_setup_synthesize_crash(slot, msg_buf, stack_buf);
        return ZJS_SETUP_CRASHED;
    }
    free(code);

    // Arm the wake timer for the first scheduled callback (if any). uv
    // would otherwise idle until the next setInterval period; this
    // guarantees the loop wakes for whatever the script just registered.
    //
    // Apple loop polls zjs_next_timer_ms each iteration before kevent(),
    // so there's no separate timer handle to pre-arm — first iteration
    // picks up whatever the script just scheduled.
#if !defined(__APPLE__)
    {
        int64_t next_ms = zjs_next_timer_ms(slot->ctx);
        // Same in-flight-I/O fallback as on_check: a script whose
        // module-top code started a fetch but registered no timers
        // still needs the loop ticking to drain the completion.
        if (next_ms < 0 && zjs_has_pending_work(slot->ctx)) next_ms = 10;
        if (next_ms >= 0) {
            if (next_ms == 0) next_ms = 1;
            uv_timer_start(&slot->zjs_wake, on_zjs_wake, (uint64_t) next_ms, 0);
        }
    }
#endif

    return ZJS_SETUP_OK;
}

static void zjs_worker_teardown_state(ZjsWorkerSlot* slot, int keep_loop) {
#if defined(__APPLE__)
    // Closing the kqueue fd reclaims all registered EVFILT_USER
    // triggers atomically — no per-handle close needed. `keep_loop` is
    // a no-op here (close-and-reopen is cheap on Apple); the next
    // incarnation's setup_state will kqueue() again.
    (void) keep_loop;
    if (slot->kq_initialized) {
        close(slot->kq);
        slot->kq = -1;
        slot->kq_initialized = 0;
    }
#else
    if (slot->loop_initialized) {
        uv_check_stop(&slot->check);
        uv_timer_stop(&slot->zjs_wake);
        uv_close((uv_handle_t*) &slot->check,            NULL);
        uv_close((uv_handle_t*) &slot->zjs_wake,         NULL);
        uv_close((uv_handle_t*) &slot->shutdown_async,   NULL);
        uv_close((uv_handle_t*) &slot->inbox_async,      NULL);
        uv_close((uv_handle_t*) &slot->eval_inbox_async, NULL);
        // Drain close callbacks. UV_RUN_DEFAULT returns once close callbacks fire.
        uv_run(&slot->loop, UV_RUN_DEFAULT);
        if (!keep_loop) {
            uv_loop_close(&slot->loop);
            slot->loop_initialized = 0;
        }
    }
#endif
    // Free any messages stranded in the inbox before context teardown
    // (the worker may have been terminated mid-flight with pending
    // messages the JS side never got to process).
    {
        char* drained;
        while ((drained = inbox_pop(slot)) != NULL) free(drained);
        pthread_mutex_destroy(&slot->inbox_mutex);
        while ((drained = eval_inbox_pop(slot)) != NULL) free(drained);
        pthread_mutex_destroy(&slot->eval_inbox_mutex);
    }
    if (slot->ctx) {
        // Release the rooted helpers before tearing the context down.
        // zjs_free_context would clean them up implicitly via root-table
        // reset, but unrooting here matches symmetric "every root has a
        // matching unroot" hygiene and would be load-bearing if the
        // bridge ever moves to a shared context across workers.
        if (slot->object_keys_root)    zjs_unroot(slot->ctx, slot->object_keys_root);
        if (slot->json_parse_root)     zjs_unroot(slot->ctx, slot->json_parse_root);
        if (slot->json_stringify_root) zjs_unroot(slot->ctx, slot->json_stringify_root);
        zjs_free_context(slot->ctx);
        slot->ctx = NULL;
    }
    slot->active = 0;
}

static void* zjs_worker_thread(void* arg) {
    ZjsWorkerSlot* slot = (ZjsWorkerSlot*) arg;

#if defined(__APPLE__)
    // Apple loop: kqueue is created inside setup_state per incarnation.
    // Nothing to allocate up front — the kq fd is the loop, and
    // close-and-reopen across reincarnations is cheap.
#else
    if (uv_loop_init(&slot->loop) != 0) {
        fprintf(stderr, "[zapp/%s] uv_loop_init failed\n",
            zapp_worker_registry_get_display_name(slot->worker_id));
        slot->active = 0;
        return NULL;
    }
    slot->loop_initialized = 1;
#endif
    slot->incarnation = 0;

    // Initialize Nim foreign-thread GC for this worker pthread so the Nim service
    // registry + handlers can run inline here (service_invoke_native). Extern;
    // the zc build provides a no-op stub (zc has no GC).
    extern void zapp_worker_thread_gc_init(void);
    zapp_worker_thread_gc_init();

    while (1) {
        slot->incarnation++;
        slot->active = 1;

        ZjsSetupResult setup = zjs_worker_setup_state(slot);

        if (setup == ZJS_SETUP_FATAL) {
            fprintf(stderr, "[zapp/%s] setup fatal (incarnation %d)\n",
                    zapp_worker_registry_get_display_name(slot->worker_id), slot->incarnation);
            break;
        }

        if (setup == ZJS_SETUP_CRASHED) {
            // host_worker_crash already fired; wants_restart set per
            // supervisor verdict. Skip the loop — nothing live to run.
            zjs_worker_teardown_state(slot, /*keep_loop=*/1);
        } else {
            // SETUP_OK
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

#if defined(__APPLE__)
            // Main loop — kqueue + CFRunLoop hybrid.
            //
            // Each iteration:
            //   1. Drain any pending JS work (timers + microtasks) BEFORE
            //      blocking so anything queued by the previous iteration
            //      fires immediately.
            //   2. Check shutdown/restart flags; bail before sleeping.
            //   3. Compute next sleep duration from zjs_next_timer_ms, capped
            //      at 1s so CFRunLoop sources (NSURLSession completions
            //      driving zjs fetch/WebSocket) can't be starved when the
            //      worker is otherwise idle.
            //   4. kevent() — sleeps until a timer fires OR an EVFILT_USER
            //      trigger comes in (post_message / broadcast / shutdown).
            //   5. Dispatch triggered events to their drain helpers.
            //   6. CFRunLoopRunInMode tick (0.0 timeout = non-blocking) to
            //      drain any NSURLSession completions that arrived. JS
            //      callbacks scheduled by them may have queued microtasks,
            //      so re-drain at the bottom.
            while (1) {
                zjs_run_pending_timers(slot->ctx);
                if (zjs_had_error(slot->ctx)) {
                    ZjsValue err = zjs_get_error(slot->ctx);
                    uint32_t len = 0;
                    const char* msg = zjs_string_bytes(err, &len);
                    fprintf(stderr, "[zapp/%s] timer threw: %.*s\n",
                        zapp_worker_registry_get_display_name(slot->worker_id),
                        (int) len, msg ? msg : "<non-string throw>");
                    // Same recovery posture as on_check — surface but keep running.
                }
                zjs_drain_microtasks(slot->ctx);

                if (atomic_load(&slot->wants_terminate)) break;
                if (atomic_load(&slot->wants_restart))   break;

                int64_t next_ms = zjs_next_timer_ms(slot->ctx);
                struct timespec ts;
                if (next_ms < 0 || next_ms > 1000) {
                    ts.tv_sec  = 1;
                    ts.tv_nsec = 0;
                } else if (next_ms == 0) {
                    ts.tv_sec  = 0;
                    ts.tv_nsec = 1000000;  // 1ms minimum to avoid spin
                } else {
                    ts.tv_sec  = next_ms / 1000;
                    ts.tv_nsec = (next_ms % 1000) * 1000000;
                }

                struct kevent events[8];
                int n = kevent(slot->kq, NULL, 0, events, 8, &ts);
                if (n < 0) {
                    if (errno == EINTR) continue;
                    fprintf(stderr, "[zapp/%s] kevent() failed: %s\n",
                            zapp_worker_registry_get_display_name(slot->worker_id), strerror(errno));
                    break;
                }

                // Drain triggered EVFILT_USER events.
                for (int i = 0; i < n; i++) {
                    if (events[i].filter != EVFILT_USER) continue;
                    if (events[i].ident == FILTER_SHUTDOWN) {
                        // Wake-only — handled above via wants_terminate /
                        // wants_restart on the next iteration's check.
                    } else if (events[i].ident == FILTER_INBOX) {
                        drain_inbox_apple(slot);
                    } else if (events[i].ident == FILTER_EVAL_INBOX) {
                        drain_eval_inbox_apple(slot);
                    }
                }

                // Tick CFRunLoop for NSURLSession completions. With
                // returnAfterSourceHandled=true and a 0.0 timeout, each
                // call returns kCFRunLoopRunHandledSource after one
                // fetch/WebSocket completion fires, or
                // kCFRunLoopRunFinished / kCFRunLoopRunTimedOut when
                // nothing else is pending. Loop until drained so a
                // burst of parallel fetch responses doesn't stack up
                // across iterations of the outer kevent loop (which
                // would otherwise drain at most one completion per
                // second when the worker is idle).
                //
                // Each completion may fire JS callbacks that schedule
                // microtasks; drain those once after the burst, then
                // let the outer loop's top-of-iteration drain handle
                // any cascade.
                while (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true)
                       == kCFRunLoopRunHandledSource) {
                    /* drained one source; keep going */
                }
                zjs_drain_microtasks(slot->ctx);
            }
#else
            uv_run(&slot->loop, UV_RUN_DEFAULT);
#endif

            zjs_worker_teardown_state(slot, /*keep_loop=*/1);
        }

        if (atomic_load(&slot->wants_terminate)) break;
        if (!atomic_load(&slot->wants_restart)) break;
        atomic_store(&slot->wants_restart, 0);
    }

    // Final cleanup — release the loop now that we're really exiting.
#if defined(__APPLE__)
    // No-op on Apple — kqueue fd was already closed in teardown_state
    // for the final incarnation. Nothing to release here.
#else
    if (slot->loop_initialized) {
        uv_run(&slot->loop, UV_RUN_NOWAIT);
        uv_loop_close(&slot->loop);
        slot->loop_initialized = 0;
    }
#endif
    slot->active = 0;
    if (zapp_log_level >= 1) {
        fprintf(stderr, "[zapp/%s] exited\n",
            zapp_worker_registry_get_display_name(slot->worker_id));
    }
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
        fprintf(stderr, "[zapp/%s] pthread_create failed\n",
            zapp_worker_registry_get_display_name(worker_id));
        slot->active = 0;
        return false;
    }
    pthread_detach(slot->thread);
    return true;
}

void zjs_worker_post_message(const char* worker_id, const char* data_json) {
    if (!worker_id || !data_json) return;
    pthread_mutex_lock(&zjs_workers_mutex);
    ZjsWorkerSlot* slot = zjs_find_slot(worker_id);
    if (!slot || !slot->active || !slot->ctx) {
        pthread_mutex_unlock(&zjs_workers_mutex);
        fprintf(stderr, "[zapp/%s] message dropped (not ready; incarnation %d)\n",
                zapp_worker_registry_get_display_name(worker_id),
                slot ? slot->incarnation : 0);
        return;
    }
#if defined(__APPLE__)
    if (!slot->kq_initialized) {
#else
    if (!slot->loop_initialized) {
#endif
        pthread_mutex_unlock(&zjs_workers_mutex);
        fprintf(stderr, "[zapp/%s] not active for postMessage — dropping\n",
            zapp_worker_registry_get_display_name(worker_id));
        return;
    }
    int err = inbox_push(slot, data_json);
    if (err == 0) {
#if defined(__APPLE__)
        apple_trigger_inbox(slot);
#else
        uv_async_send(&slot->inbox_async);
#endif
    }
    pthread_mutex_unlock(&zjs_workers_mutex);
    if (err != 0) {
        fprintf(stderr, "[zapp/%s] inbox full — dropped message\n",
            zapp_worker_registry_get_display_name(worker_id));
    }
}

void zjs_worker_terminate(const char* worker_id) {
    if (!worker_id) return;
    pthread_mutex_lock(&zjs_workers_mutex);
    ZjsWorkerSlot* slot = zjs_find_slot(worker_id);
    if (slot) {
        atomic_store(&slot->wants_terminate, 1);
        // Wake the worker so it observes wants_terminate immediately
        // (kevent / uv_async_send are the thread-safe wake primitives).
        // The worker thread then unwinds via the teardown label.
#if defined(__APPLE__)
        if (slot->kq_initialized) apple_trigger_shutdown(slot);
#else
        if (slot->loop_initialized) uv_async_send(&slot->shutdown_async);
#endif
    }
    pthread_mutex_unlock(&zjs_workers_mutex);
    // Thread is detached — slot.active flips to 0 when it exits.
}

void zjs_worker_terminate_owner(const char* owner_id) {
    if (!owner_id) return;
    pthread_mutex_lock(&zjs_workers_mutex);
    for (int i = 0; i < ZJS_MAX_WORKERS; i++) {
        if (zjs_workers[i].active && strcmp(zjs_workers[i].owner_id, owner_id) == 0) {
            atomic_store(&zjs_workers[i].wants_terminate, 1);
#if defined(__APPLE__)
            if (zjs_workers[i].kq_initialized) apple_trigger_shutdown(&zjs_workers[i]);
#else
            if (zjs_workers[i].loop_initialized) {
                uv_async_send(&zjs_workers[i].shutdown_async);
            }
#endif
        }
    }
    pthread_mutex_unlock(&zjs_workers_mutex);
}

// --- zjs_worker_eval_js: target a specific worker's eval_inbox ---
//
// Same idea as zjs_broadcast_eval_js but scoped to one slot, looked
// up by worker_id. Mirrors bare_worker_eval_js (bare.c:1210).
//
// Slot lock + eval_inbox push + cross-thread wake (kqueue trigger on
// Apple, uv_async_send elsewhere). Safe to call from any thread.
void zjs_worker_eval_js(const char* worker_id, const char* js) {
    if (!worker_id || !js) return;
    pthread_mutex_lock(&zjs_workers_mutex);
    for (int i = 0; i < ZJS_MAX_WORKERS; i++) {
        ZjsWorkerSlot* slot = &zjs_workers[i];
        if (!slot->active) continue;
        if (strcmp(slot->worker_id, worker_id) != 0) continue;
#if defined(__APPLE__)
        if (!slot->kq_initialized) break;
#else
        if (!slot->loop_initialized) break;
#endif
        if (eval_inbox_push(slot, js) != 0) {
            fprintf(stderr, "[zapp/%s] eval inbox full — dropped targeted eval\n",
                zapp_worker_registry_get_display_name(slot->worker_id));
            break;
        }
#if defined(__APPLE__)
        apple_trigger_eval_inbox(slot);
#else
        uv_async_send(&slot->eval_inbox_async);
#endif
        break;
    }
    pthread_mutex_unlock(&zjs_workers_mutex);
}

// Broadcast a JS snippet (bridge._onEvent IIFE) to every active zjs worker.
// Counterpart of bare_broadcast_eval_js — the dispatcher fans events emitted
// from the webview (or anywhere else) into the worker pool by calling this.
// Each zjs worker owns its own loop, so we push the snippet into the
// slot's eval_inbox and signal it; the worker thread drains and evals.
void zjs_broadcast_eval_js(const char* js) {
    if (!js) return;
    pthread_mutex_lock(&zjs_workers_mutex);
    for (int i = 0; i < ZJS_MAX_WORKERS; i++) {
        ZjsWorkerSlot* slot = &zjs_workers[i];
#if defined(__APPLE__)
        if (!slot->active || !slot->kq_initialized) continue;
#else
        if (!slot->active || !slot->loop_initialized) continue;
#endif
        if (eval_inbox_push(slot, js) != 0) {
            fprintf(stderr, "[zapp/%s] eval inbox full — dropped broadcast\n",
                zapp_worker_registry_get_display_name(slot->worker_id));
            continue;
        }
#if defined(__APPLE__)
        apple_trigger_eval_inbox(slot);
#else
        uv_async_send(&slot->eval_inbox_async);
#endif
    }
    pthread_mutex_unlock(&zjs_workers_mutex);
}
