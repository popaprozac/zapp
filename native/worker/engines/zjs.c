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

// Fan-out fire-and-forget events to every webview's
// __zappBridge._onEvent listener. Same destination JSC / txiki / bare
// hit; the per-engine difference is how we get the JS payload value
// to a C string. zjs caches JSON.stringify on the slot and calls it
// directly (no JS-side property dance, no second eval).
extern void dispatch_event_to_all(const char* event_name, const char* payload);

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
        uint32_t n = zjs_array_length(v);
        for (uint32_t i = 0; i < n; i++) {
            ZjsValue elem = zjs_get_element(ctx, v, i);
            json_array_push_owned(arr, zjsvalue_to_jsonvalue(slot, elem));
        }
        return arr;
    }
    if (zjs_is_object(v)) {
        JsonValue* obj = JsonValue__object_ptr();
        // Object.keys(v) — cached at bridge setup. Returns an array of
        // string keys (own enumerable, same as JSON.stringify uses).
        ZjsValue arg = v;
        ZjsValue keys = zjs_call(ctx, zjs_root_get(ctx, slot->object_keys_root),
                                 zjs_undefined(), &arg, 1);
        zjs_drain_microtasks(ctx);
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
    // Real payload, if present, goes through JSON.stringify via the cached
    // handle.
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
    slot->json_stringify_root = zjs_root(ctx, zjs_eval(ctx, "JSON.stringify"));

    // globalThis.__zappBridge — the engine-agnostic host surface. zjs
    // gets the direct value-path invokeService; bare/jsc/txiki get the
    // JSON-stringifying wrapper in their per-engine bootstraps. Same
    // public API (`b.invokeService(method, args)`) either way.
    ZjsValue bridge = zjs_new_object(ctx);
    ZjsValue invoke_fn = zjs_register_host_function(ctx, "__zapp_invoke_service",
                                                    host_invoke_service);
    ZjsValue emit_fn   = zjs_register_host_function(ctx, "__zapp_dispatch_event",
                                                    host_dispatch_event_to_all);
    zjs_set_property(ctx, bridge, "invokeService",      invoke_fn);
    zjs_set_property(ctx, bridge, "dispatchEventToAll", emit_fn);
    // Alias to match the legacy name some runtime code still uses.
    zjs_set_property(ctx, bridge, "emitToHost",         emit_fn);
    zjs_set_global(ctx, "__zappBridge", bridge);
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
    zjs_setup_bridge(slot);

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
        // Most user throws are Error objects (`throw new Error(...)`), not
        // bare strings. Read the .message field when present, then fall
        // back to String() coercion for anything else (numbers, objects
        // without .message, etc).
        const char* msg = NULL;
        uint32_t    len = 0;
        ZjsValue    msg_val = zjs_get_property(slot->ctx, err, "message");
        if (zjs_is_string(msg_val)) {
            msg = zjs_string_bytes(msg_val, &len);
        }
        if (!msg) msg = zjs_string_bytes(err, &len);
        if (!msg) {
            // Last resort: stash the value as a global and String() it
            // so we get *something* readable rather than "<non-string>".
            zjs_set_global(slot->ctx, "__zapp_err_tmp", err);
            ZjsValue str = zjs_eval(slot->ctx, "String(__zapp_err_tmp)");
            msg = zjs_string_bytes(str, &len);
        }
        // Stacks are non-standard but worth showing when present.
        const char* stack = NULL;
        uint32_t    slen  = 0;
        ZjsValue    stack_val = zjs_get_property(slot->ctx, err, "stack");
        if (zjs_is_string(stack_val)) stack = zjs_string_bytes(stack_val, &slen);
        fprintf(stderr, "[zapp] zjs worker '%s' script threw: %.*s%s%.*s\n",
            slot->worker_id,
            (int) len, msg ? msg : "<unreadable>",
            stack ? "\n" : "",
            (int) slen, stack ? stack : "");
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
