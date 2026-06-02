// C API for the zjs worker engine.
// Implementation in zjs.c (pure C — no ObjC needed).
//
// zjs is Zapp's first-party JS engine. It runs each worker on its own
// pthread with its own uv_loop, talks to host code through a direct
// ZjsValue ↔ JsonValue bridge (no JSON.stringify/parse round-trip),
// and ships microtask + timer semantics correctly out of the box.

#ifndef ZAPP_WORKER_ZJS_H
#define ZAPP_WORKER_ZJS_H

#include <stdbool.h>
#include <stdint.h>

// Create a zjs worker. Runs on a pthread with its own uv_loop +
// ZjsContext. script_url is the canonical "/_workers/<file>.mjs" the
// Vite plugin emits; the engine resolves it via the same embedded-asset
// → filesystem → iOS-dev-URL fallback chain the other engines use.
bool zjs_worker_create(const char* script_url, const char* owner_id, const char* worker_id);

// Send a message to a worker. JSON string for engine-agnostic transport
// — the Z2 cut adds a direct value path that skips JSON for zjs↔zjs
// hops; the JSON form stays as the fallback for cross-engine messaging.
void zjs_worker_post_message(const char* worker_id, const char* data_json);

// Terminate a specific worker.
void zjs_worker_terminate(const char* worker_id);

// Terminate all workers owned by a window.
void zjs_worker_terminate_owner(const char* owner_id);

// Evaluate JS in a specific zjs worker's context. Used by sync.m to
// deliver bridge.dispatchSyncResult(payload) to the right worker.
// No-op if the worker isn't found / not yet initialized. Mirrors
// bare_worker_eval_js (bare.h:37).
void zjs_worker_eval_js(const char* worker_id, const char* js);

// Broadcast a JS snippet to every active zjs worker. Used by the
// dispatcher (bridge/dispatch.zc) to fan webview/native-emitted events
// into worker contexts so their `bridge._onEvent` listeners fire — same
// route txiki_broadcast_eval_js / bare_broadcast_eval_js take for their
// engines.
void zjs_broadcast_eval_js(const char* js);

// Dispatch a message from a worker back to the WebView (provided by
// the router; defined in worker.zc).
extern void worker_dispatch_to_webview(char* worker_id, char* data_json);

#endif
