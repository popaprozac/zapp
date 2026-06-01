// Windows sync — wait/notify coordination.
// Per-key FIFO waiter queues with timeout.
// Results dispatched back to originating JS context (WebView or Worker).

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sync.h"

extern void windows_webview_eval_all(const char* js);

// --- Waiter entries ---

#define ZAPP_SYNC_MAX_WAITERS 128

typedef struct {
    int active;
    char request_id[128];
    char key[128];
    char target_worker_id[64];
    int dispatched;
    HANDLE event; // For blocking wait (manual-reset event)
} ZappSyncWaiter;

static ZappSyncWaiter zapp_sync_waiters[ZAPP_SYNC_MAX_WAITERS] = {0};
static CRITICAL_SECTION zapp_sync_cs;
static int zapp_sync_initialized = 0;

static void zapp_sync_init(void) {
    if (!zapp_sync_initialized) {
        InitializeCriticalSection(&zapp_sync_cs);
        zapp_sync_initialized = 1;
    }
}

static ZappSyncWaiter* find_waiter(const char* request_id) {
    for (int i = 0; i < ZAPP_SYNC_MAX_WAITERS; i++) {
        if (zapp_sync_waiters[i].active &&
            strcmp(zapp_sync_waiters[i].request_id, request_id) == 0) {
            return &zapp_sync_waiters[i];
        }
    }
    return NULL;
}

static ZappSyncWaiter* alloc_waiter(void) {
    for (int i = 0; i < ZAPP_SYNC_MAX_WAITERS; i++) {
        if (!zapp_sync_waiters[i].active) {
            memset(&zapp_sync_waiters[i], 0, sizeof(ZappSyncWaiter));
            zapp_sync_waiters[i].active = 1;
            return &zapp_sync_waiters[i];
        }
    }
    return NULL;
}

// --- Result dispatch ---

static void dispatch_result(const char* request_id, const char* status, const char* target_worker_id) {
    char js[512];
    snprintf(js, sizeof(js),
        "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&typeof b.dispatchSyncResult==='function')"
        "b.dispatchSyncResult('{\"id\":\"%s\",\"ok\":true,\"status\":\"%s\"}');})();",
        request_id, status);
    // TODO: worker dispatch when workers are implemented on Windows
    (void)target_worker_id;
    windows_webview_eval_all(js);
}

// --- Minimal JSON helpers ---

static const char* sync_json_str(const char* json, const char* key, char* buf, int buf_size) {
    if (!json || !key) return NULL;
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", key);
    const char* p = strstr(json, pattern);
    if (!p) return NULL;
    p += strlen(pattern);
    int i = 0;
    while (*p && *p != '"' && i < buf_size - 1) {
        if (*p == '\\' && *(p+1)) { buf[i++] = *(p+1); p += 2; }
        else { buf[i++] = *p++; }
    }
    buf[i] = '\0';
    return buf;
}

static int sync_json_int(const char* json, const char* key) {
    if (!json || !key) return 0;
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char* p = strstr(json, pattern);
    if (!p) return 0;
    p += strlen(pattern);
    while (*p == ' ') p++;
    return atoi(p);
}

// --- Handlers ---

static void handle_wait(const char* payload_json) {
    char request_id[128] = {0};
    char key[128] = {0};
    char worker_id[64] = {0};

    sync_json_str(payload_json, "id", request_id, sizeof(request_id));
    sync_json_str(payload_json, "key", key, sizeof(key));
    sync_json_str(payload_json, "targetWorkerId", worker_id, sizeof(worker_id));
    int timeout_ms = sync_json_int(payload_json, "timeoutMs");

    if (!request_id[0] || !key[0]) return;

    EnterCriticalSection(&zapp_sync_cs);
    ZappSyncWaiter* w = alloc_waiter();
    if (!w) { LeaveCriticalSection(&zapp_sync_cs); return; }

    strncpy(w->request_id, request_id, sizeof(w->request_id) - 1);
    strncpy(w->key, key, sizeof(w->key) - 1);
    strncpy(w->target_worker_id, worker_id, sizeof(w->target_worker_id) - 1);
    LeaveCriticalSection(&zapp_sync_cs);

    // Set timeout timer if specified
    if (timeout_ms > 0) {
        // Use SetTimer with a window message, or just use a thread.
        // For simplicity, use a one-shot timer thread.
        // The main thread will check and dispatch on timeout.
        // For now, we rely on notify to resolve. Full timeout needs a timer.
    }
}

static void handle_notify(const char* payload_json) {
    char key[128] = {0};
    sync_json_str(payload_json, "key", key, sizeof(key));
    int count = sync_json_int(payload_json, "count");
    if (count < 1) count = 1;
    if (!key[0]) return;

    EnterCriticalSection(&zapp_sync_cs);
    int delivered = 0;
    // FIFO: find oldest active waiter for this key
    for (int pass = 0; pass < count; pass++) {
        ZappSyncWaiter* oldest = NULL;
        for (int i = 0; i < ZAPP_SYNC_MAX_WAITERS; i++) {
            ZappSyncWaiter* w = &zapp_sync_waiters[i];
            if (w->active && !w->dispatched && strcmp(w->key, key) == 0) {
                oldest = w; // First match is oldest (FIFO by array order)
                break;
            }
        }
        if (!oldest) break;

        oldest->dispatched = 1;
        if (oldest->event) {
            // Blocking wait path
            SetEvent(oldest->event);
        } else {
            // Async path — dispatch to JS
            char rid[128], wid[64];
            strncpy(rid, oldest->request_id, sizeof(rid) - 1);
            strncpy(wid, oldest->target_worker_id, sizeof(wid) - 1);
            oldest->active = 0;
            LeaveCriticalSection(&zapp_sync_cs);
            dispatch_result(rid, "notified", wid);
            EnterCriticalSection(&zapp_sync_cs);
        }
        delivered++;
    }
    LeaveCriticalSection(&zapp_sync_cs);
}

static void handle_cancel(const char* payload_json) {
    char request_id[128] = {0};
    sync_json_str(payload_json, "id", request_id, sizeof(request_id));
    if (!request_id[0]) return;

    EnterCriticalSection(&zapp_sync_cs);
    ZappSyncWaiter* w = find_waiter(request_id);
    if (w && !w->dispatched) {
        char rid[128], wid[64];
        strncpy(rid, w->request_id, sizeof(rid) - 1);
        strncpy(wid, w->target_worker_id, sizeof(wid) - 1);
        w->active = 0;
        LeaveCriticalSection(&zapp_sync_cs);
        dispatch_result(rid, "cancelled", wid);
        return;
    }
    LeaveCriticalSection(&zapp_sync_cs);
}

// --- Public API ---

void windows_sync_handle(const char* action, const char* payload_json) {
    if (!action || !payload_json) return;
    zapp_sync_init();

    if (strcmp(action, "wait") == 0) handle_wait(payload_json);
    else if (strcmp(action, "notify") == 0) handle_notify(payload_json);
    else if (strcmp(action, "cancel") == 0) handle_cancel(payload_json);
}

void windows_sync_dispatch_to_webviews(const char* payload_json) {
    if (!payload_json) return;
    char js[512];
    snprintf(js, sizeof(js),
        "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&typeof b.dispatchSyncResult==='function')b.dispatchSyncResult('%s');})();",
        payload_json);
    windows_webview_eval_all(js);
}

void windows_sync_dispatch_to_worker(const char* worker_id, const char* payload_json) {
    // TODO: dispatch to bare/zjs worker when workers are implemented on Windows
    (void)worker_id;
    (void)payload_json;
}

// --- Blocking wait (for background threads / workers ONLY) ---

int windows_sync_wait_blocking(const char* key, int timeout_ms) {
    if (!key || key[0] == '\0') return 0;
    zapp_sync_init();

    // Create a manual-reset event for this wait
    HANDLE event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!event) return 0;

    // Generate unique request ID
    char request_id[128];
    snprintf(request_id, sizeof(request_id), "blocking-%lu-%lu",
             (unsigned long)GetCurrentThreadId(), (unsigned long)GetTickCount());

    // Register waiter
    EnterCriticalSection(&zapp_sync_cs);
    ZappSyncWaiter* w = alloc_waiter();
    if (!w) {
        LeaveCriticalSection(&zapp_sync_cs);
        CloseHandle(event);
        return 0;
    }
    strncpy(w->request_id, request_id, sizeof(w->request_id) - 1);
    strncpy(w->key, key, sizeof(w->key) - 1);
    w->event = event;
    LeaveCriticalSection(&zapp_sync_cs);

    // Block until signaled or timeout
    DWORD wait_ms = (timeout_ms > 0) ? (DWORD)timeout_ms : INFINITE;
    DWORD result = WaitForSingleObject(event, wait_ms);
    CloseHandle(event);

    // Clean up
    EnterCriticalSection(&zapp_sync_cs);
    w->active = 0;
    w->event = NULL;
    LeaveCriticalSection(&zapp_sync_cs);

    return (result == WAIT_OBJECT_0) ? 1 : 0; // 1 = notified, 0 = timed out
}
