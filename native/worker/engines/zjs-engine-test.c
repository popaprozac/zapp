// Integration test for engines/zjs.c — exercises the full worker
// lifecycle (zjs_worker_create → pthread → uv_loop → ZjsContext →
// bootstrap → script eval → timer fire → terminate). Compiles against
// the same zjs.c the framework will link, plus the minimum extern
// stubs to satisfy its dependencies on Zapp's asset + iOS-dev plumbing.
//
// Build:
//   clang -O1 -Wall -Wextra -std=c11 \
//     -I vendor/zjs/include -I /opt/homebrew/include \
//     -I native/worker/engines \
//     native/worker/engines/zjs.c \
//     native/worker/engines/zjs-engine-test.c \
//     vendor/zjs/build/libzjs.a /opt/homebrew/lib/libuv.dylib \
//     -framework Foundation -fobjc-arc \
//     -o build/zjs-engine-test
//
// Acceptance: 4 [js-console] ticks at ~200ms cadence, then clean exit.

#include "zjs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// --- Stubs for the externs zjs.c expects from Zapp's build ---

typedef struct {
    const char* path;
    unsigned char* data;
    int len;
    int uncompressed_len;
    int is_brotli;
} ZappEmbeddedAsset;

int zapp_build_use_embedded_assets(void) { return 0; }
ZappEmbeddedAsset zapp_embedded_assets[] = {};
int zapp_embedded_assets_count = 0;

// Router callback the engine would invoke when a worker sends a
// message back to the webview. No webview in this test — just print.
void worker_dispatch_to_webview(char* worker_id, char* data_json) {
    fprintf(stderr, "[router] dispatch from '%s': %s\n",
        worker_id ? worker_id : "<null>", data_json ? data_json : "<null>");
}

// Service dispatch stubs — zjs.c's invokeService path calls
// app_get_active() then service_invoke_native(app, method, args).
// Stand in for those with a dummy app + an echo service that hands the
// caller back its own args as JSON so we can prove the round-trip.

// Minimal C stubs for the JsonValue API. In the real Zapp framework
// these are implemented by std/json.zc compiled to C. Layout is
// shared with the real impl (kind tag first, value fields second)
// so the engine code under test sees the same bytes either way.

typedef struct JsonValueOpaque JsonValue;

#define KIND_NULL    0
#define KIND_BOOL    1
#define KIND_NUMBER  2
#define KIND_STRING  3
#define KIND_ARRAY   4
#define KIND_OBJECT  5
#define MAX_CHILDREN 32

typedef struct JsonValueOpaque {
    int    kind_tag;     // matches std/json.zc's JsonType enum tags
    char*  string_val;
    double number_val;
    int    bool_val;
    JsonValue* children[MAX_CHILDREN];
    char*  keys[MAX_CHILDREN];   // populated for objects
    int    child_count;
} JsonValueOpaque;

static JsonValue* mk(int tag) {
    JsonValue* v = (JsonValue*) calloc(1, sizeof(JsonValueOpaque));
    ((JsonValueOpaque*) v)->kind_tag = tag;
    return v;
}
JsonValue* JsonValue__null_ptr(void)        { return mk(KIND_NULL); }
JsonValue* JsonValue__bool_ptr(int b)       { JsonValue* v = mk(KIND_BOOL); ((JsonValueOpaque*) v)->bool_val = !!b; return v; }
JsonValue* JsonValue__number_ptr(double n)  { JsonValue* v = mk(KIND_NUMBER); ((JsonValueOpaque*) v)->number_val = n; return v; }
JsonValue* JsonValue__string_ptr(char* s)   { JsonValue* v = mk(KIND_STRING); ((JsonValueOpaque*) v)->string_val = s ? strdup(s) : strdup(""); return v; }
JsonValue* JsonValue__array_ptr(void)       { return mk(KIND_ARRAY); }
JsonValue* JsonValue__object_ptr(void)      { return mk(KIND_OBJECT); }

void json_array_push_owned(JsonValue* arr, JsonValue* val) {
    JsonValueOpaque* a = (JsonValueOpaque*) arr;
    if (a->child_count < MAX_CHILDREN) a->children[a->child_count++] = val;
}
void json_object_set_owned(JsonValue* obj, char* key, JsonValue* val) {
    JsonValueOpaque* o = (JsonValueOpaque*) obj;
    if (o->child_count < MAX_CHILDREN) {
        o->keys[o->child_count] = key ? strdup(key) : strdup("");
        o->children[o->child_count] = val;
        o->child_count++;
    }
}
void json_free_tree(JsonValue* v) {
    if (!v) return;
    JsonValueOpaque* j = (JsonValueOpaque*) v;
    for (int i = 0; i < j->child_count; i++) {
        free(j->keys[i]);
        json_free_tree(j->children[i]);
    }
    free(j->string_val);
    free(v);
}

void* app_get_active(void) { return (void*) 0x1; }  // any non-NULL works

// Crude JSON encoder so the test can show that the args walked from
// ZjsValue into a JsonValue tree the way invokeService expects. Only
// covers the primitives + container shapes our test payload uses.
// Production lives in service_invoke_native's real implementation.
static void encode(JsonValue* v, char** buf, size_t* len, size_t* cap);
static void append(char** buf, size_t* len, size_t* cap, const char* s, size_t n) {
    if (*len + n + 1 > *cap) {
        *cap = (*cap + n + 1) * 2;
        *buf = (char*) realloc(*buf, *cap);
    }
    memcpy(*buf + *len, s, n);
    *len += n;
    (*buf)[*len] = '\0';
}

static void encode(JsonValue* v, char** buf, size_t* len, size_t* cap) {
    if (!v) { append(buf, len, cap, "null", 4); return; }
    JsonValueOpaque* j = (JsonValueOpaque*) v;
    switch (j->kind_tag) {
        case KIND_NULL:   append(buf, len, cap, "null", 4); return;
        case KIND_BOOL:   append(buf, len, cap, j->bool_val ? "true" : "false",
                                 j->bool_val ? 4 : 5); return;
        case KIND_NUMBER: { char num[64]; int n = snprintf(num, sizeof(num), "%g", j->number_val);
                            append(buf, len, cap, num, (size_t) n); return; }
        case KIND_STRING: { append(buf, len, cap, "\"", 1);
                            if (j->string_val) append(buf, len, cap, j->string_val, strlen(j->string_val));
                            append(buf, len, cap, "\"", 1); return; }
        case KIND_ARRAY:  {
            append(buf, len, cap, "[", 1);
            for (int i = 0; i < j->child_count; i++) {
                if (i > 0) append(buf, len, cap, ",", 1);
                encode(j->children[i], buf, len, cap);
            }
            append(buf, len, cap, "]", 1);
            return;
        }
        case KIND_OBJECT: {
            append(buf, len, cap, "{", 1);
            for (int i = 0; i < j->child_count; i++) {
                if (i > 0) append(buf, len, cap, ",", 1);
                append(buf, len, cap, "\"", 1);
                append(buf, len, cap, j->keys[i], strlen(j->keys[i]));
                append(buf, len, cap, "\":", 2);
                encode(j->children[i], buf, len, cap);
            }
            append(buf, len, cap, "}", 1);
            return;
        }
        default: append(buf, len, cap, "null", 4); return;
    }
}

const char* service_invoke_native(void* app, const char* method, JsonValue* args) {
    (void) app;
    static char buf[2048];
    char* encoded = (char*) calloc(1, 64);
    size_t elen = 0, ecap = 64;
    encode(args, &encoded, &elen, &ecap);
    snprintf(buf, sizeof(buf),
        "{\"echoedMethod\":\"%s\",\"argsKind\":\"primitive\",\"argsRendered\":%s}",
        method ? method : "<null>", encoded);
    free(encoded);
    return buf;
}

// --- Test ---

static void write_script(const char* path, const char* body) {
    mkdir("/tmp/zjs-engine-test", 0755);
    mkdir("/tmp/zjs-engine-test/.zapp", 0755);
    mkdir("/tmp/zjs-engine-test/.zapp/workers", 0755);
    FILE* f = fopen(path, "w");
    if (!f) { perror("fopen"); exit(1); }
    fputs(body, f);
    fclose(f);
}

int main(void) {
    // The engine looks scripts up via `${cwd}/.zapp/workers/${basename}`,
    // so cd into a temp dir we control.
    if (chdir("/tmp/zjs-engine-test") != 0) {
        mkdir("/tmp/zjs-engine-test", 0755);
        chdir("/tmp/zjs-engine-test");
    }
    write_script("/tmp/zjs-engine-test/.zapp/workers/test.mjs",
        "console.log('hello from zjs worker');\n"
        "Promise.resolve('microtask drained').then(m => console.log(m));\n"
        // Z2 round-trip: pass an object through __zappBridge.invokeService,
        // read the echoed response back. The stub service in C JSON-encodes
        // the JsonValue tree it received from zjs's walker and returns it
        // as a JSON string; JSON.parse on the way out gives us a plain JS
        // object that we can probe for the expected fields.
        "var r = __zappBridge.invokeService('echo', { greeting: 'hi', count: 42 });\n"
        "console.log('invoke ->',"
        "  typeof r,"
        "  r && r.echoedMethod,"
        "  r && r.argsRendered);\n"
        "var n = 0;\n"
        "setInterval(() => { n++; console.log('tick', n); }, 200);\n"
    );

    fprintf(stderr, "[test] launching zjs worker...\n");
    if (!zjs_worker_create("/_workers/test.mjs", "owner-1", "worker-1")) {
        fprintf(stderr, "[test] zjs_worker_create FAILED\n");
        return 1;
    }

    // Run for ~900ms to see 4 ticks.
    struct timespec ts = { 0, 900 * 1000 * 1000 };
    nanosleep(&ts, NULL);

    fprintf(stderr, "[test] terminating worker...\n");
    zjs_worker_terminate("worker-1");

    // Give the worker thread a beat to observe the shutdown latch and
    // unwind cleanly. The thread is detached; this is a polite wait,
    // not a join.
    struct timespec wait_for_exit = { 0, 300 * 1000 * 1000 };
    nanosleep(&wait_for_exit, NULL);

    fprintf(stderr, "[test] done\n");
    return 0;
}
