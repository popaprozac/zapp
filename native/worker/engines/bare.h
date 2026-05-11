// C API for Bare worker engine.
// Implementation in bare.c (one file, gated by ZAPP_WORKER_ENGINE_BARE_*).

#ifndef ZAPP_WORKER_BARE_H
#define ZAPP_WORKER_BARE_H

#include <stdbool.h>
#include <stdint.h>

// Create a Bare worker. Spawns a thread, sets up libuv loop +
// js_platform + bare instance, registers Zapp host functions on the
// `js_env_t`, loads the worker script, and runs the loop. The exact
// JS engine inside Bare (libjsc / libjs / libqjs / libmqjs) is
// determined at link time by which `ZAPP_WORKER_ENGINE_BARE_*` is
// defined; bare.c is engine-agnostic above the libjs ABI.
bool bare_worker_create(const char* script_url, const char* owner_id, const char* worker_id);

// Send a message to a worker (JSON string). Pushes onto the worker's
// inbox and signals the libuv async handle to wake the worker thread.
void bare_worker_post_message(const char* worker_id, const char* data_json);

// Terminate a specific worker. Tears down bare + libuv + thread.
void bare_worker_terminate(const char* worker_id);

// Terminate all workers owned by a given window.
void bare_worker_terminate_owner(const char* owner_id);

// Broadcast a raw JS string to every active bare worker. Each worker
// drains its eval_inbox on the next libuv async tick. Used by the
// event-broadcast paths (Events.emit, app events).
void bare_broadcast_eval_js(const char* js);

// Evaluate JS in a specific bare worker's context. Used by
// `darwin_sync_dispatch_to_worker` (sync.m) to deliver
// `bridge.dispatchSyncResult(payload)` to the right worker.
// No-op if the worker isn't found / not yet initialized.
void bare_worker_eval_js(const char* worker_id, const char* js);

#endif
