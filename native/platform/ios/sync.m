// iOS sync shim — Phase 1 stubs. The macOS impl uses Foundation +
// pthread (both iOS-native), so phase 2 can port wholesale. For the
// spike, every entry point no-ops cleanly so apps that don't exercise
// `Sync.wait/notify` build and run.

#include <stdint.h>
#include <stdbool.h>

void darwin_sync_handle(const char* action, const char* payload_json) {
    (void)action; (void)payload_json;
}
void darwin_sync_dispatch_to_webviews(const char* js) { (void)js; }
void darwin_sync_dispatch_to_worker(const char* worker_id, const char* js) {
    (void)worker_id; (void)js;
}
bool darwin_sync_wait_blocking(const char* key, int32_t timeout_ms) {
    (void)key; (void)timeout_ms;
    return false;
}
