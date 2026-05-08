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
 || defined(ZAPP_WORKER_ENGINE_BARE_MQJS)

#include <bare.h>
#include <js.h>
#include <uv.h>

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
} BareWorkerSlot;

static BareWorkerSlot bare_workers[BARE_MAX_WORKERS] = {0};
static pthread_mutex_t bare_mutex = PTHREAD_MUTEX_INITIALIZER;

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
            fprintf(stderr, "[zapp] bare worker loaded from embedded: %s\n", script_url);
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
        FILE* f = fopen(path_buf, "r");
        if (f) {
            fseek(f, 0, SEEK_END);
            long len = ftell(f);
            fseek(f, 0, SEEK_SET);
            char* code = (char*)malloc(len + 1);
            if (code) {
                fread(code, 1, len, f);
                code[len] = '\0';
                fclose(f);
                fprintf(stderr, "[zapp] bare worker loaded from disk: %s\n", path_buf);
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
        const char* worker_id = slot ? slot->worker_id : "?";
        fprintf(stderr, "[bare:%s] %s\n", worker_id, buf);
    }

    js_value_t* undef;
    js_get_undefined(env, &undef);
    return undef;
}

// --- Worker thread entry ---

static void* bare_worker_thread(void* data) {
    BareWorkerSlot* slot = (BareWorkerSlot*)data;
    int err;

    uv_loop_t loop;
    err = uv_loop_init(&loop);
    if (err) {
        fprintf(stderr, "[zapp] bare worker '%s' uv_loop_init failed: %s\n",
            slot->worker_id, uv_strerror(err));
        slot->active = false;
        return NULL;
    }
    slot->loop = &loop;

    js_platform_options_t platform_opts = {0};
    err = js_create_platform(&loop, &platform_opts, &slot->platform);
    if (err) {
        fprintf(stderr, "[zapp] bare worker '%s' js_create_platform failed (err=%d)\n",
            slot->worker_id, err);
        uv_loop_close(&loop);
        slot->active = false;
        return NULL;
    }

    bare_options_t bare_opts = {0};
    const char* argv[] = { "zapp-bare-worker", NULL };
    err = bare_setup(&loop, slot->platform, &slot->env, 1, argv, &bare_opts, &slot->bare);
    if (err) {
        fprintf(stderr, "[zapp] bare worker '%s' bare_setup failed (err=%d)\n",
            slot->worker_id, err);
        js_destroy_platform(slot->platform);
        uv_loop_close(&loop);
        slot->active = false;
        return NULL;
    }

    // Register host functions on globalThis.__zappBridge.
    js_value_t* global;
    js_get_global(slot->env, &global);

    js_value_t* bridge;
    js_create_object(slot->env, &bridge);

    js_value_t* log_fn;
    js_create_function(slot->env, "log", -1, bare_host_log, slot, &log_fn);
    js_set_named_property(slot->env, bridge, "log", log_fn);

    js_value_t* worker_id_str;
    js_create_string_utf8(slot->env, (utf8_t*)slot->worker_id,
        strlen(slot->worker_id), &worker_id_str);
    js_set_named_property(slot->env, bridge, "workerId", worker_id_str);

    js_set_named_property(slot->env, global, "__zappBridge", bridge);

    fprintf(stderr, "[zapp] bare worker created: %s\n", slot->worker_id);

    // Load + run the script.
    if (slot->script_source && slot->script_len > 0) {
        uv_buf_t source = uv_buf_init(slot->script_source, slot->script_len);
        js_value_t* result;
        err = bare_load(slot->bare, slot->script_url, &source, &result);
        if (err) {
            fprintf(stderr, "[zapp] bare worker '%s' bare_load failed (err=%d)\n",
                slot->worker_id, err);
        }
    }

    // Run the loop until something terminates the bare instance.
    bare_run(slot->bare, UV_RUN_DEFAULT);

    int exit_code = 0;
    bare_teardown(slot->bare, UV_RUN_NOWAIT, &exit_code);
    js_destroy_platform(slot->platform);
    uv_loop_close(&loop);

    free(slot->script_source);
    slot->script_source = NULL;
    slot->bare = NULL;
    slot->env = NULL;
    slot->platform = NULL;
    slot->loop = NULL;
    slot->active = false;

    fprintf(stderr, "[zapp] bare worker exited: %s (code=%d)\n",
        slot->worker_id, exit_code);
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
        fprintf(stderr, "[zapp] bare worker '%s' pthread_create failed (err=%d)\n",
            slot->worker_id, err);
        free(slot->script_source);
        slot->script_source = NULL;
        slot->active = false;
        return false;
    }
    pthread_detach(slot->thread);
    return true;
}

void bare_worker_post_message(const char* worker_id, const char* data_json) {
    // Message passing TBD — needs an inbox queue + uv_async_t the
    // worker thread can react to. Coming in a follow-up commit
    // alongside Services.invokeSync.
    (void)worker_id;
    (void)data_json;
}

void bare_worker_terminate(const char* worker_id) {
    pthread_mutex_lock(&bare_mutex);
    BareWorkerSlot* slot = bare_find_slot(worker_id);
    if (slot && slot->bare) {
        bare_terminate(slot->bare);  // signals bare_run to return; thread cleans up
    }
    pthread_mutex_unlock(&bare_mutex);
}

void bare_worker_terminate_owner(const char* owner_id) {
    if (!owner_id) return;
    pthread_mutex_lock(&bare_mutex);
    for (int i = 0; i < BARE_MAX_WORKERS; i++) {
        if (bare_workers[i].active &&
            strcmp(bare_workers[i].owner_id, owner_id) == 0 &&
            bare_workers[i].bare) {
            bare_terminate(bare_workers[i].bare);
        }
    }
    pthread_mutex_unlock(&bare_mutex);
}

#endif // ZAPP_WORKER_ENGINE_BARE_*
