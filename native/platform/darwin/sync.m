// Sync — native wait/notify coordination.
// Per-key FIFO waiter queues. Wait enqueues, notify dequeues and resolves.
// Results dispatched back to originating JS context (WebView or Worker).

#import <Foundation/Foundation.h>
#import "sync.h"

// --- State ---

// requestId → { key, targetWorkerId, dispatched }
static NSMutableDictionary<NSString*, NSMutableDictionary*>* zapp_sync_waits = nil;
// key → [requestId, requestId, ...] (FIFO)
static NSMutableDictionary<NSString*, NSMutableArray<NSString*>*>* zapp_sync_queues = nil;

static void zapp_sync_ensure_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        zapp_sync_waits = [NSMutableDictionary new];
        zapp_sync_queues = [NSMutableDictionary new];
    });
}

// --- Result dispatch ---

static void zapp_sync_dispatch_result(NSString* requestId, BOOL ok, NSString* status, NSString* targetWorkerId) {
    // Build JSON payload
    NSString* safeId = [requestId stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString* payload = [NSString stringWithFormat:
        @"{\"id\":\"%@\",\"ok\":%@,\"status\":\"%@\"}",
        safeId,
        ok ? @"true" : @"false",
        status];

    if (targetWorkerId && targetWorkerId.length > 0) {
        darwin_sync_dispatch_to_worker([targetWorkerId UTF8String], [payload UTF8String]);
    } else {
        darwin_sync_dispatch_to_webviews([payload UTF8String]);
    }
}

static void zapp_sync_remove_waiter(NSString* requestId) {
    NSDictionary* wait = zapp_sync_waits[requestId];
    if (!wait) return;

    NSString* key = wait[@"key"];
    [zapp_sync_waits removeObjectForKey:requestId];

    // Remove from queue
    NSMutableArray* queue = zapp_sync_queues[key];
    if (queue) {
        [queue removeObject:requestId];
        if (queue.count == 0) [zapp_sync_queues removeObjectForKey:key];
    }
}

// --- Handlers ---

static void zapp_sync_handle_wait(NSDictionary* args) {
    NSString* requestId = args[@"id"];
    NSString* key = args[@"key"];
    NSNumber* timeoutMs = args[@"timeoutMs"];
    NSString* targetWorkerId = args[@"targetWorkerId"] ?: @"";

    if (!requestId || !key || key.length == 0) {
        NSLog(@"[zapp:sync] wait rejected — missing id (%@) or key (%@)",
            requestId ?: @"<nil>", key ?: @"<nil>");
        return;
    }
    NSLog(@"[zapp:sync] wait registered key=%@ id=%@ timeout=%@ target=%@",
        key, requestId, timeoutMs ?: @"none",
        targetWorkerId.length > 0 ? targetWorkerId : @"webview");

    zapp_sync_ensure_init();

    // Create wait entry
    NSMutableDictionary* entry = [NSMutableDictionary dictionaryWithDictionary:@{
        @"key": key,
        @"targetWorkerId": targetWorkerId,
        @"dispatched": @NO,
    }];
    zapp_sync_waits[requestId] = entry;

    // Add to per-key FIFO queue
    NSMutableArray* queue = zapp_sync_queues[key];
    if (!queue) {
        queue = [NSMutableArray new];
        zapp_sync_queues[key] = queue;
    }
    [queue addObject:requestId];

    // Set timeout if specified
    if (timeoutMs && ![timeoutMs isKindOfClass:[NSNull class]]) {
        double ms = [timeoutMs doubleValue];
        if (ms > 0) {
            NSString* ridCopy = [requestId copy];
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
                dispatch_get_main_queue(), ^{
                    NSDictionary* w = zapp_sync_waits[ridCopy];
                    if (w && ![w[@"dispatched"] boolValue]) {
                        NSLog(@"[zapp:sync] wait timed-out key=%@ id=%@",
                            w[@"key"], ridCopy);
                        zapp_sync_remove_waiter(ridCopy);
                        zapp_sync_dispatch_result(ridCopy, YES, @"timed-out",
                            w[@"targetWorkerId"]);
                    }
                });
        }
    }
}

static void zapp_sync_handle_notify(NSDictionary* args) {
    NSString* key = args[@"key"];
    NSNumber* countNum = args[@"count"];
    int count = countNum ? [countNum intValue] : 1;
    if (count < 1) count = 1;

    if (!key || key.length == 0) {
        NSLog(@"[zapp:sync] notify rejected — missing key");
        return;
    }

    zapp_sync_ensure_init();

    NSMutableArray* queue = zapp_sync_queues[key];
    if (!queue || queue.count == 0) {
        NSLog(@"[zapp:sync] notify key=%@ — no waiters", key);
        return;
    }
    NSLog(@"[zapp:sync] notify key=%@ count=%d waiters=%lu",
        key, count, (unsigned long)queue.count);

    int delivered = 0;
    while (queue.count > 0 && delivered < count) {
        NSString* requestId = queue[0];
        [queue removeObjectAtIndex:0];

        NSMutableDictionary* wait = zapp_sync_waits[requestId];
        if (wait && ![wait[@"dispatched"] boolValue]) {
            wait[@"dispatched"] = @YES;

            // Check for blocking semaphore (native sync_wait)
            dispatch_semaphore_t sem = wait[@"semaphore"];
            if (sem) {
                [zapp_sync_waits removeObjectForKey:requestId];
                dispatch_semaphore_signal(sem);
            } else {
                // Async path (JS bridge)
                NSString* targetWorkerId = wait[@"targetWorkerId"];
                [zapp_sync_waits removeObjectForKey:requestId];
                zapp_sync_dispatch_result(requestId, YES, @"notified", targetWorkerId);
            }
            delivered++;
        }
    }

    if (queue.count == 0) [zapp_sync_queues removeObjectForKey:key];
    NSLog(@"[zapp:sync] notify key=%@ delivered=%d", key, delivered);
}

static void zapp_sync_handle_cancel(NSDictionary* args) {
    NSString* requestId = args[@"id"];
    if (!requestId) return;

    zapp_sync_ensure_init();

    NSDictionary* wait = zapp_sync_waits[requestId];
    if (!wait || [wait[@"dispatched"] boolValue]) return;

    NSString* targetWorkerId = wait[@"targetWorkerId"];
    NSLog(@"[zapp:sync] cancel key=%@ id=%@", wait[@"key"], requestId);
    zapp_sync_remove_waiter(requestId);
    zapp_sync_dispatch_result(requestId, YES, @"cancelled", targetWorkerId);
}

// --- Public API ---

void darwin_sync_handle(const char* action, const char* payload_json) {
    if (!action || !payload_json) return;

    NSString* act = [NSString stringWithUTF8String:action];
    NSData* data = [[NSString stringWithUTF8String:payload_json] dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    NSDictionary* parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![parsed isKindOfClass:[NSDictionary class]]) return;

    // Two callers package payloads differently:
    //   - Workers (jsc.m / txiki.c) pass a flat dict: {id, key, targetWorkerId}
    //   - Webviews route through the bridge as {t:6, m:"wait", a:{id, key, ...}}
    //     and the router forwards the *full* message as payload_json.
    // Unwrap the nested "a" field when present so both shapes work.
    NSDictionary* args = parsed;
    id wrapped = parsed[@"a"];
    if ([wrapped isKindOfClass:[NSDictionary class]]) {
        args = (NSDictionary*)wrapped;
    }

    if ([act isEqualToString:@"wait"]) {
        zapp_sync_handle_wait(args);
    } else if ([act isEqualToString:@"notify"]) {
        zapp_sync_handle_notify(args);
    } else if ([act isEqualToString:@"cancel"]) {
        zapp_sync_handle_cancel(args);
    }
}

void darwin_sync_dispatch_to_webviews(const char* payload_json) {
    if (!payload_json) return;
    NSString* escaped = [[NSString stringWithUTF8String:payload_json]
        stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&typeof b.dispatchSyncResult==='function')b.dispatchSyncResult('%@');})();",
        escaped];

    extern void darwin_webview_eval_all(const char* js);
    darwin_webview_eval_all([js UTF8String]);
}

void darwin_sync_dispatch_to_worker(const char* worker_id, const char* payload_json) {
    if (!worker_id || !payload_json) return;
    // Eval in worker's JSContext via the existing worker dispatch mechanism
    NSString* wid = [NSString stringWithUTF8String:worker_id];
    NSString* escaped = [[NSString stringWithUTF8String:payload_json]
        stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=self.__zappBridge||globalThis.__zappBridge;"
        "if(b&&typeof b.dispatchSyncResult==='function')b.dispatchSyncResult('%@');})();",
        escaped];

    extern void jsc_worker_eval_js(const char* worker_id, const char* js);
    jsc_worker_eval_js(worker_id, [js UTF8String]);
}

// --- Blocking wait (for background threads ONLY) ---

int darwin_sync_wait_blocking(const char* key, int timeout_ms) {
    if (!key || key[0] == '\0') return 0;

    zapp_sync_ensure_init();

    // Create semaphore
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSString* nsKey = [NSString stringWithUTF8String:key];
    NSString* requestId = [NSString stringWithFormat:@"blocking-%f-%u",
        [[NSDate date] timeIntervalSince1970], arc4random()];

    // Register waiter on main queue (sync data structures must be accessed from main)
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSMutableDictionary* entry = [NSMutableDictionary dictionaryWithDictionary:@{
            @"key": nsKey,
            @"targetWorkerId": @"",
            @"dispatched": @NO,
            @"semaphore": sem,
        }];
        zapp_sync_waits[requestId] = entry;

        NSMutableArray* queue = zapp_sync_queues[nsKey];
        if (!queue) {
            queue = [NSMutableArray new];
            zapp_sync_queues[nsKey] = queue;
        }
        [queue addObject:requestId];
    });

    // Block calling thread until signaled or timeout
    dispatch_time_t deadline = (timeout_ms > 0)
        ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC)
        : DISPATCH_TIME_FOREVER;

    long result = dispatch_semaphore_wait(sem, deadline);

    if (result != 0) {
        // Timed out — clean up on main queue
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableDictionary* wait = zapp_sync_waits[requestId];
            if (wait && ![wait[@"dispatched"] boolValue]) {
                NSMutableArray* queue = zapp_sync_queues[nsKey];
                if (queue) {
                    [queue removeObject:requestId];
                    if (queue.count == 0) [zapp_sync_queues removeObjectForKey:nsKey];
                }
                [zapp_sync_waits removeObjectForKey:requestId];
            }
        });
        return 0; // timed out
    }

    return 1; // notified
}
