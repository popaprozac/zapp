// C API for Windows sync (wait/notify coordination).
// Implementation in sync.c (Win32 CONDITION_VARIABLE).

#ifndef ZAPP_WINDOWS_SYNC_H
#define ZAPP_WINDOWS_SYNC_H

#include <stdbool.h>
#include <stdint.h>

// Handle a sync action from the bridge: "wait", "notify", or "cancel".
void windows_sync_handle(const char* action, const char* payload_json);

// Dispatch a sync result to all WebViews.
void windows_sync_dispatch_to_webviews(const char* payload_json);

// Dispatch a sync result to a specific worker context.
void windows_sync_dispatch_to_worker(const char* worker_id, const char* payload_json);

// Blocking wait — for background threads ONLY, NOT main thread.
// Returns: 1 = notified, 0 = timed out
int windows_sync_wait_blocking(const char* key, int timeout_ms);

#endif
