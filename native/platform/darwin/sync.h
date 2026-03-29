// Sync — native wait/notify coordination for cross-context synchronization.
// Per-key FIFO waiter queues with timeout support.

#ifndef ZAPP_SYNC_H
#define ZAPP_SYNC_H

#include <stdbool.h>
#include <stdint.h>

// Handle a sync action from the bridge: "wait", "notify", or "cancel".
void darwin_sync_handle(const char* action, const char* payload_json);

// Dispatch a sync result to all WebViews.
void darwin_sync_dispatch_to_webviews(const char* payload_json);

// Dispatch a sync result to a specific worker context.
void darwin_sync_dispatch_to_worker(const char* worker_id, const char* payload_json);

// Blocking wait — for background threads ONLY, NOT main thread.
// Returns: 1 = notified, 0 = timed out
int darwin_sync_wait_blocking(const char* key, int timeout_ms);

#endif
