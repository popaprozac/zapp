// C API for JSC worker engine.
// Implementation in jsc.m (Objective-C).

#ifndef ZAPP_WORKER_JSC_H
#define ZAPP_WORKER_JSC_H

#include <stdbool.h>
#include <stdint.h>

// Create a JSC worker context. Runs script on a serial dispatch queue.
bool jsc_worker_create(const char* script_url, const char* owner_id, const char* worker_id);

// Send a message to a worker (JSON string).
void jsc_worker_post_message(const char* worker_id, const char* data_json);

// Terminate a specific worker.
void jsc_worker_terminate(const char* worker_id);

// Terminate all workers owned by a window.
void jsc_worker_terminate_owner(const char* owner_id);

// Dispatch a message from a worker back to the WebView.
// Called by the worker's host object postToWebview().
// Implemented in Zen-C (bridge/dispatch.zc), declared here for jsc.m to call.
extern void worker_dispatch_to_webview(char* worker_id, char* data_json);

// --- Backend worker (privileged, app-level JS context) ---

// Create the backend worker. Loads script from path. Starts on serial queue.
bool jsc_backend_create(const char* script_path);

// Terminate the backend worker.
void jsc_backend_terminate(void);

// Evaluate JS in the backend worker context.
void jsc_backend_eval_js(const char* js);

// Check if backend worker is running.
bool jsc_backend_is_running(void);

#endif
