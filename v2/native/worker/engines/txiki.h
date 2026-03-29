// C API for txiki.js worker engine.
// Implementation in txiki.c (pure C — no ObjC needed).
// txiki.js provides: QuickJS-ng + libuv + fetch/WebSocket/timers/crypto.

#ifndef ZAPP_WORKER_TXIKI_H
#define ZAPP_WORKER_TXIKI_H

#include <stdbool.h>
#include <stdint.h>

// Create a txiki.js worker. Runs on a libuv thread with its own event loop.
bool txiki_worker_create(const char* script_url, const char* owner_id, const char* worker_id);

// Send a message to a worker (JSON string).
void txiki_worker_post_message(const char* worker_id, const char* data_json);

// Terminate a specific worker.
void txiki_worker_terminate(const char* worker_id);

// Terminate all workers owned by a window.
void txiki_worker_terminate_owner(const char* owner_id);

// Dispatch a message from a worker back to the WebView.
extern void worker_dispatch_to_webview(char* worker_id, char* data_json);

// --- Backend worker (privileged, app-level JS context with web APIs) ---

bool txiki_backend_create(const char* script_path);
void txiki_backend_terminate(void);
void txiki_backend_eval_js(const char* js);
bool txiki_backend_is_running(void);

#endif
