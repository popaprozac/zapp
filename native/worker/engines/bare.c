// Bare worker engine — stub implementation for the spike branch.
//
// This file exists so cli/src/build-config.ts can reference it as a
// source whenever `ZAPP_WORKER_ENGINE_BARE_*` defines are set in
// build.zc, even before the full integration lands. The dispatcher in
// `native/worker/worker.zc` will wire actual `bare_worker_*`
// implementations in a follow-up commit.
//
// For now: declare the symbols the dispatcher will call so link
// succeeds. Each is a no-op that returns false / nothing; if a worker
// is mistakenly routed here it just doesn't run, instead of crashing.

#include <stdbool.h>
#include <stdint.h>

#if defined(ZAPP_WORKER_ENGINE_BARE_V8)     \
 || defined(ZAPP_WORKER_ENGINE_BARE_JSC)    \
 || defined(ZAPP_WORKER_ENGINE_BARE_QUICKJS) \
 || defined(ZAPP_WORKER_ENGINE_BARE_MQJS)

#include <stdio.h>

bool bare_worker_create(const char* script_url, const char* owner_id, const char* worker_id) {
    (void)owner_id;
    fprintf(stderr,
        "[zapp] bare_worker_create stub fired for %s (%s) — engine not yet implemented on spike branch\n",
        worker_id ? worker_id : "(null)", script_url ? script_url : "(null)");
    return false;
}

void bare_worker_post_message(const char* worker_id, const char* data_json) {
    (void)worker_id; (void)data_json;
}

void bare_worker_terminate(const char* worker_id) { (void)worker_id; }

void bare_worker_terminate_owner(const char* owner_id) { (void)owner_id; }

#endif // ZAPP_WORKER_ENGINE_BARE_*
