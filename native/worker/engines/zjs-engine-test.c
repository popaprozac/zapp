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
