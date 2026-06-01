// JSC worker engine — Objective-C implementation.
// Each worker gets a JSContext on a serial dispatch queue.
// Bridge host objects provide direct native access.

#import <JavaScriptCore/JavaScriptCore.h>
#import <Foundation/Foundation.h>
#import <compression.h>
#import "jsc.h"

// Embedded asset struct (defined in zapp_assets.zc, accessed via weak extern)
typedef struct {
    const char* path;
    uint8_t* data;
    int len;
    int uncompressed_len;
    int is_brotli;
} ZappEmbeddedAsset;

// --- Worker storage ---

#define JSC_MAX_WORKERS 64

typedef struct {
    char worker_id[64];
    char owner_id[64];
    int active;
    int incarnation;
    // ObjC objects stored via associated storage below
} JSCWorkerSlot;

static JSCWorkerSlot jsc_workers[JSC_MAX_WORKERS] = {{0}};
static NSMutableDictionary<NSString*, JSContext*>* jsc_contexts = nil;
static NSMutableDictionary<NSString*, dispatch_queue_t>* jsc_queues = nil;
static JSVirtualMachine* jsc_vm = nil;

static void jsc_ensure_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        jsc_vm = [[JSVirtualMachine alloc] init];
        jsc_contexts = [NSMutableDictionary new];
        jsc_queues = [NSMutableDictionary new];
    });
}

// --- Forward declarations ---
extern void* app_get_active(void);
extern bool app_get_bootstrap_web_content_inspectable(void);

// Supervisor (registry.zc) — host-side restart policy decisions.
// Declared up here so jsc_setup_bridge's bridge.workerCrash handler
// can reach them without needing a second forward block.
extern int  zapp_worker_supervisor_record_failure(const char* worker_id);
extern const char* zapp_worker_supervisor_get_script_url(const char* worker_id);
extern const char* zapp_worker_supervisor_get_owner(const char* worker_id);
extern void dispatch_event_to_all(const char* event_name, const char* payload);

// Forward decls so the bridge handler defined inside jsc_setup_bridge
// (which lives near the top of the file) can reach the helpers + the
// init-context entry point defined further down.
@class JSContext;
static void jsc_worker_init_context(NSString* wid, NSString* oid, NSString* scriptUrl);
static int jsc_incarnation_for(NSString* wid);
static void jsc_dispatch_restarted(NSString* wid);
static void jsc_dispatch_gave_up(NSString* wid);

// Service invoke — legacy JSON-string path (still used for some callers).
extern const char* service_invoke_sync(void* app, const char* method, const char* args);

// --- Zen-C JsonValue construction (declared in std/json.zc + json_builder.zc) ---
// Mirror of the txiki walker — JSValue* → JsonValue* without going through
// JSON.stringify + JSON.parse.
typedef struct JsonValue JsonValue;
extern JsonValue* JsonValue__null_ptr(void);
extern JsonValue* JsonValue__bool_ptr(bool b);
extern JsonValue* JsonValue__number_ptr(double n);
extern JsonValue* JsonValue__string_ptr(char* s);
extern JsonValue* JsonValue__array_ptr(void);
extern JsonValue* JsonValue__object_ptr(void);
extern void json_object_set_owned(JsonValue* obj, char* key, JsonValue* val);
extern void json_array_push_owned(JsonValue* arr, JsonValue* val);
extern void json_free_tree(JsonValue* v);
extern const char* service_invoke_native(void* app, const char* method, JsonValue* args);

// Walk a JSValue (Cocoa API) into a Zen-C JsonValue tree.
// Returns a heap-allocated tree; caller frees via json_free_tree().
// Object enumeration uses the lower-level JSObjectCopyPropertyNames C API
// instead of [v toDictionary] — toDictionary would walk the entire tree into
// NSDictionary/NSArray/NSNumber/NSString once, defeating the whole point.
static JsonValue* jscvalue_to_jsonvalue(JSValue* v) {
    if (!v || [v isUndefined] || [v isNull]) {
        return JsonValue__null_ptr();
    }
    if ([v isBoolean]) {
        return JsonValue__bool_ptr([v toBool] ? true : false);
    }
    if ([v isNumber]) {
        return JsonValue__number_ptr([v toDouble]);
    }
    if ([v isString]) {
        const char* s = [[v toString] UTF8String];
        return JsonValue__string_ptr((char*)(s ? s : ""));
    }
    if ([v isArray]) {
        JsonValue* arr = JsonValue__array_ptr();
        uint32_t len = (uint32_t)[[v valueForProperty:@"length"] toUInt32];
        for (uint32_t i = 0; i < len; i++) {
            JSValue* elem = [v valueAtIndex:i];
            JsonValue* child = jscvalue_to_jsonvalue(elem);
            json_array_push_owned(arr, child);
        }
        return arr;
    }
    if ([v isObject]) {
        JsonValue* obj = JsonValue__object_ptr();
        JSContextRef ctxRef = v.context.JSGlobalContextRef;
        JSObjectRef objRef = JSValueToObject(ctxRef, v.JSValueRef, NULL);
        if (objRef) {
            JSPropertyNameArrayRef names = JSObjectCopyPropertyNames(ctxRef, objRef);
            size_t count = JSPropertyNameArrayGetCount(names);
            for (size_t i = 0; i < count; i++) {
                JSStringRef nameRef = JSPropertyNameArrayGetNameAtIndex(names, i);
                size_t utf8len = JSStringGetMaximumUTF8CStringSize(nameRef);
                char key_buf[256];
                char* key_heap = NULL;
                char* key_ptr = key_buf;
                if (utf8len > sizeof(key_buf)) {
                    key_heap = malloc(utf8len);
                    key_ptr = key_heap;
                }
                JSStringGetUTF8CString(nameRef, key_ptr, utf8len);

                JSValueRef propRef = JSObjectGetProperty(ctxRef, objRef, nameRef, NULL);
                JSValue* prop = [JSValue valueWithJSValueRef:propRef inContext:v.context];
                JsonValue* child = jscvalue_to_jsonvalue(prop);
                json_object_set_owned(obj, key_ptr, child);

                if (key_heap) free(key_heap);
            }
            JSPropertyNameArrayRelease(names);
        }
        return obj;
    }
    return JsonValue__null_ptr();
}

// --- Host object setup ---

static void jsc_setup_bridge(JSContext* ctx, NSString* workerId) {
    // Bridge object
    JSValue* bridge = [JSValue valueWithNewObjectInContext:ctx];

    // console.log/warn/error
    NSString* wid = [workerId copy];

    // Console — supports multiple arguments via JSContext.currentArguments
    JSValue* console = [JSValue valueWithNewObjectInContext:ctx];
    void (^logImpl)(NSString*, NSArray*) = ^(NSString* level, NSArray* rawArgs) {
        NSMutableString* out = [NSMutableString new];
        JSContext* currentCtx = [JSContext currentContext];
        JSValue* jsonStringify = [currentCtx evaluateScript:@"JSON.stringify"];
        for (JSValue* arg in rawArgs) {
            if (out.length > 0) [out appendString:@" "];
            if ([arg isObject] && ![arg isString]) {
                JSValue* jsonStr = [jsonStringify callWithArguments:@[arg]];
                if (jsonStr && ![jsonStr isUndefined] && ![jsonStr isNull]) {
                    [out appendString:[jsonStr toString]];
                } else {
                    [out appendString:[arg toString]];
                }
            } else {
                [out appendString:[arg toString]];
            }
        }
        NSLog(@"[worker:%@%@] %@", wid, level, out);
    };
    console[@"log"] = ^{ logImpl(@"", [JSContext currentArguments]); };
    console[@"warn"] = ^{ logImpl(@" WARN", [JSContext currentArguments]); };
    console[@"error"] = ^{ logImpl(@" ERROR", [JSContext currentArguments]); };
    ctx[@"console"] = console;

    // invokeService — zero-JSON args path: walk JS value directly into a
    // JsonValue tree (no NSJSONSerialization round-trip on the way in).
    // Result side still parses JSON for now — see task 21.
    bridge[@"invokeService"] = ^JSValue*(NSString* method, JSValue* argsVal) {
        void* app = app_get_active();
        if (!app || !method) return [JSValue valueWithUndefinedInContext:[JSContext currentContext]];

        JsonValue* args_jv = NULL;
        if (argsVal && ![argsVal isUndefined] && ![argsVal isNull]) {
            args_jv = jscvalue_to_jsonvalue(argsVal);
        }

        const char* result = service_invoke_native(app, [method UTF8String], args_jv);
        if (args_jv) json_free_tree(args_jv);

        if (!result || result[0] == '\0') {
            return [JSValue valueWithUndefinedInContext:[JSContext currentContext]];
        }
        // Parse result as JSON to return a proper JS object (not a string)
        NSString* resultStr = [NSString stringWithUTF8String:result];
        NSData* resultData = [resultStr dataUsingEncoding:NSUTF8StringEncoding];
        id resultObj = resultData ? [NSJSONSerialization JSONObjectWithData:resultData options:0 error:nil] : nil;
        if (resultObj) {
            return [JSValue valueWithObject:resultObj inContext:[JSContext currentContext]];
        }
        return [JSValue valueWithObject:resultStr inContext:[JSContext currentContext]];
    };

    // dispatchEventToAll — broadcast a fire-and-forget event to every webview.
    // The backend uses this to push state changes to all open windows; workers
    // can use it the same way. Native dispatch_event_to_all builds the JS that
    // every webview's bridge._onEvent listener picks up.
    extern void dispatch_event_to_all(const char* event_name, const char* payload);
    JSValue* (^broadcast)(NSString*, JSValue*) = ^JSValue*(NSString* name, JSValue* payload) {
        if (!name || name.length == 0) return [JSValue valueWithUndefinedInContext:[JSContext currentContext]];
        NSString* payloadJson = @"{}";
        if (payload && ![payload isUndefined] && ![payload isNull]) {
            NSData* d = [NSJSONSerialization dataWithJSONObject:[payload toObject] options:0 error:nil];
            if (d) payloadJson = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }
        const char* nameC = strdup([name UTF8String]);
        const char* jsonC = strdup([payloadJson UTF8String]);
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_event_to_all(nameC, jsonC);
            free((void*)nameC);
            free((void*)jsonC);
        });
        return [JSValue valueWithUndefinedInContext:[JSContext currentContext]];
    };
    bridge[@"dispatchEventToAll"] = broadcast;
    bridge[@"emitToHost"] = broadcast;  // legacy alias — workers use this name

    // postToWebview — send message back to the owner WebView
    bridge[@"postToWebview"] = ^(JSValue* data) {
        NSString* json = @"{}";
        if (data && ![data isUndefined]) {
            NSData* d = [NSJSONSerialization dataWithJSONObject:[data toObject] options:0 error:nil];
            if (d) json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }
        worker_dispatch_to_webview([wid UTF8String], [json UTF8String]);
    };

    // postToWorker(targetId, data) — direct worker→worker channel.
    // Workers.postMessage(targetId, data) and Workers.send(targetId,
    // channel, data) both route through here. Skips the webview hop
    // and the broadcast fan-out you'd get from Events.emit, so a
    // pipeline like ingest → db → sync stays point-to-point.
    bridge[@"postToWorker"] = ^(NSString* targetId, JSValue* data) {
        if (!targetId || targetId.length == 0) return;
        NSString* json = @"{}";
        if (data && ![data isUndefined]) {
            NSData* d = [NSJSONSerialization dataWithJSONObject:[data toObject] options:0 error:nil];
            if (d) json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }
        jsc_worker_post_message([targetId UTF8String], [json UTF8String]);
    };

    // syncWait — host object for Sync.wait() from workers.
    // Returns a real JS Promise whose resolver is stashed on bridge._syncPending
    // keyed by request_id. When the native sync dispatch eval's dispatchSyncResult
    // back into this worker's context, the bootstrap looks up and resolves.
    //
    // darwin_sync_handle is thread-safe (pthread_mutex), so the worker calls
    // it directly on its own thread — no main-queue bounce.
    extern void darwin_sync_handle(const char* action, const char* payload_json);
    bridge[@"syncWait"] = ^JSValue*(NSString* key, JSValue* timeoutVal) {
        JSContext* currentCtx = [JSContext currentContext];
        if (!key || key.length == 0) {
            return [JSValue valueWithNewPromiseResolvedWithResult:@"timed-out" inContext:currentCtx];
        }
        double timeoutMs = (timeoutVal && ![timeoutVal isUndefined]) ? [timeoutVal toDouble] : -1;

        NSString* requestId = [NSString stringWithFormat:@"%@:sync-%f-%u",
            wid, [[NSDate date] timeIntervalSince1970], arc4random()];

        // Create the promise and capture the resolve function (executor runs
        // synchronously during valueWithNewPromise...).
        __block JSValue* capturedResolve = nil;
        JSValue* promise = [JSValue valueWithNewPromiseInContext:currentCtx
            fromExecutor:^(JSValue* resolve, JSValue* reject) {
                (void)reject;
                capturedResolve = resolve;
            }];
        if (!capturedResolve) {
            return [JSValue valueWithNewPromiseResolvedWithResult:@"timed-out" inContext:currentCtx];
        }

        // Fetch the bridge fresh from the context each call. We can't capture
        // it in the setup closure because JSValue wrappers are released when
        // the setup function returns — ctx[@"__zappBridge"] gives us a fresh
        // wrapper around the (still-alive) underlying JS object.
        JSValue* liveBridge = currentCtx[@"__zappBridge"];
        JSValue* pending = liveBridge[@"_syncPending"];
        if (!pending || [pending isUndefined] || [pending isNull]) {
            pending = [JSValue valueWithNewObjectInContext:currentCtx];
            liveBridge[@"_syncPending"] = pending;
        }
        pending[requestId] = capturedResolve;

        // Register the wait with native.
        NSMutableDictionary* payload = [NSMutableDictionary dictionaryWithDictionary:@{
            @"id": requestId,
            @"key": key,
            @"targetWorkerId": wid,
        }];
        if (timeoutMs > 0) payload[@"timeoutMs"] = @(timeoutMs);

        NSData* data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (data) {
            NSString* json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            darwin_sync_handle("wait", [json UTF8String]);
        }

        return promise;
    };

    // syncNotify — same: direct call, no main-queue bounce.
    bridge[@"syncNotify"] = ^(NSString* key, JSValue* countVal) {
        if (!key || key.length == 0) return;
        int count = (countVal && ![countVal isUndefined]) ? [countVal toInt32] : 1;
        if (count < 1) count = 1;

        NSDictionary* payload = @{ @"key": key, @"count": @(count) };
        NSData* data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (!data) return;
        NSString* json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        darwin_sync_handle("notify", [json UTF8String]);
    };

    // --- Privileged host objects available in every worker ---

    // workerCrash(message, stack) — bootstrap calls this when an
    // uncaught error escapes a setTimeout callback or an event handler
    // (the bootstrap try/catch normally swallows them, hiding the
    // failure from the supervisor). On JSC we ALSO have ctx.exceptionHandler
    // for sync top-level throws — both paths feed into the same flow.
    bridge[@"workerCrash"] = ^(NSString* message, NSString* stack) {
        NSDictionary* d = @{
            @"id": wid ?: @"",
            @"message": message ?: @"",
            @"stack": stack ?: @"",
            @"incarnation": @(jsc_incarnation_for(wid)),
        };
        NSData* j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
        NSString* payload = j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : @"{}";
        dispatch_event_to_all((char*)"worker:crashed", (char*)[payload UTF8String]);

        int decision = zapp_worker_supervisor_record_failure([wid UTF8String]);
        if (decision == 2) {
            jsc_dispatch_gave_up(wid);
            return;
        }
        if (decision != 1) return;

        // Restart approved on JSC. Tear down + re-init in same queue.
        dispatch_queue_t queue = jsc_queues[wid];
        if (!queue) return;
        const char* scriptUrlC = zapp_worker_supervisor_get_script_url([wid UTF8String]);
        if (!scriptUrlC || !scriptUrlC[0]) return;
        NSString* scriptUrl = [NSString stringWithUTF8String:scriptUrlC];
        const char* ownerC = zapp_worker_supervisor_get_owner([wid UTF8String]);
        NSString* oid = ownerC ? [NSString stringWithUTF8String:ownerC] : @"";
        dispatch_async(queue, ^{
            [jsc_contexts removeObjectForKey:wid];
            for (int i = 0; i < JSC_MAX_WORKERS; i++) {
                if (jsc_workers[i].active && strcmp(jsc_workers[i].worker_id,
                                                   [wid UTF8String]) == 0) {
                    jsc_workers[i].incarnation++;
                    break;
                }
            }
            jsc_worker_init_context(wid, oid, scriptUrl);
            jsc_dispatch_restarted(wid);
        });
    };

    // quit — terminate the app from any worker
    bridge[@"quit"] = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            exit(0);
        });
    };

    // subscribeWindowEvent — register this worker for window events
    bridge[@"subscribeWindowEvent"] = ^(JSValue* windowIdVal, JSValue* eventIdVal) {
        int wId = [windowIdVal toInt32];
        int eId = [eventIdVal toInt32];
        dispatch_async(dispatch_get_main_queue(), ^{
            extern void zapp_window_set_backend_listener(int id, int event_id, int has_listener);
            if (wId < 0) {
                for (int i = 0; i < 64; i++) {
                    zapp_window_set_backend_listener(i, eId, 1);
                }
            } else {
                zapp_window_set_backend_listener(wId, eId, 1);
            }
        });
    };

    // showNotification — fire-and-forget system notification
    bridge[@"showNotification"] = ^(NSString* title, NSString* body) {
        const char* t = title ? [title UTF8String] : "";
        const char* b = body ? [body UTF8String] : "";
        char* tc = strdup(t);
        char* bc = strdup(b);
        dispatch_async(dispatch_get_main_queue(), ^{
            extern void darwin_notification_show_typed(const char*, const char*, const char*, const char*);
            darwin_notification_show_typed(tc, "", bc, "default");
            free(tc);
            free(bc);
        });
    };

    // createWindow — synchronously create a window from any worker.
    // Dispatches to main queue (window creation requires main thread on macOS),
    // waits for result, returns an object with windowId.
    //
    // Forwards the whole opts object as JSON so every WindowOptions field
    // (titleBarStyle, alwaysOnTop, acceptFirstMouse, ...) plumbs through,
    // not just title/url/width/height. Zen-C parses and applies via
    // window_opts_apply_json.
    bridge[@"createWindow"] = ^JSValue*(JSValue* optsVal) {
        JSContext* currentCtx = [JSContext currentContext];
        NSString* optsJson = @"{}";
        if (optsVal && ![optsVal isUndefined] && ![optsVal isNull]) {
            id optsObj = [optsVal toObject];
            if ([optsObj isKindOfClass:[NSDictionary class]]) {
                NSData* d = [NSJSONSerialization dataWithJSONObject:optsObj options:0 error:nil];
                if (d) optsJson = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            }
        }
        const char* jsonC = strdup([optsJson UTF8String]);
        __block int windowId = -1;
        extern int zapp_worker_create_window_from_json(const char* opts_json);
        // Guard against dispatch_sync deadlock when called from a block that
        // is already running on the main queue (e.g. a worker's setTimeout
        // callback — setTimeout currently dispatches to the main queue, so
        // JS that runs inside it is already main-thread when it calls us).
        if ([NSThread isMainThread]) {
            windowId = zapp_worker_create_window_from_json(jsonC);
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                windowId = zapp_worker_create_window_from_json(jsonC);
            });
        }
        free((void*)jsonC);
        JSValue* result = [JSValue valueWithNewObjectInContext:currentCtx];
        result[@"windowId"] = [NSString stringWithFormat:@"win-%d", windowId];
        return result;
    };

    // notif(action, args) — dispatcher for all notification operations.
    // Runtime's Notification.* methods call this directly in worker contexts,
    // bypassing getBridge().invoke() entirely for zero-overhead calls.
    bridge[@"notif"] = ^JSValue*(NSString* action, JSValue* argsVal) {
        JSContext* currentCtx = [JSContext currentContext];
        extern const char* darwin_notification_get_permission(void);
        extern void darwin_notification_show_typed(const char*, const char*, const char*, const char*);
        extern void darwin_notification_schedule_typed(const char*, const char*, double);
        extern void darwin_notification_cancel(const char*);
        extern void darwin_notification_cancel_all(void);
        extern void darwin_notification_remove_delivered(const char*);
        extern void darwin_notification_remove_all_delivered(void);
        extern void darwin_notification_update(const char*, const char*, const char*, const char*);

        NSString* act = action ?: @"";
        if ([act isEqualToString:@"getPermission"]) {
            const char* st = darwin_notification_get_permission();
            JSValue* r = [JSValue valueWithNewObjectInContext:currentCtx];
            r[@"status"] = st ? [NSString stringWithUTF8String:st] : @"notDetermined";
            return r;
        }
        if ([act isEqualToString:@"show"]) {
            NSString* title = argsVal[@"title"] ? [argsVal[@"title"] toString] : @"";
            NSString* subtitle = argsVal[@"subtitle"] ? [argsVal[@"subtitle"] toString] : @"";
            NSString* body = argsVal[@"body"] ? [argsVal[@"body"] toString] : @"";
            NSString* sound = argsVal[@"sound"] ? [argsVal[@"sound"] toString] : @"default";
            darwin_notification_show_typed([title UTF8String], [subtitle UTF8String], [body UTF8String], [sound UTF8String]);
            // Return an ID (clients use it for update/cancel). Workers don't get the native-generated ID in this
            // sync path — generate a client-side UUID-ish value so the API contract holds.
            JSValue* r = [JSValue valueWithNewObjectInContext:currentCtx];
            r[@"id"] = [NSString stringWithFormat:@"notif-%llu-%u", (unsigned long long)[[NSDate date] timeIntervalSince1970] * 1000, arc4random()];
            return r;
        }
        if ([act isEqualToString:@"schedule"]) {
            NSString* title = argsVal[@"title"] ? [argsVal[@"title"] toString] : @"";
            NSString* body = argsVal[@"body"] ? [argsVal[@"body"] toString] : @"";
            double delay = argsVal[@"delaySeconds"] ? [argsVal[@"delaySeconds"] toDouble] : 0;
            darwin_notification_schedule_typed([title UTF8String], [body UTF8String], delay);
            JSValue* r = [JSValue valueWithNewObjectInContext:currentCtx];
            r[@"id"] = [NSString stringWithFormat:@"notif-%llu-%u", (unsigned long long)[[NSDate date] timeIntervalSince1970] * 1000, arc4random()];
            return r;
        }
        if ([act isEqualToString:@"cancel"]) {
            NSString* id_ = argsVal[@"id"] ? [argsVal[@"id"] toString] : @"";
            darwin_notification_cancel([id_ UTF8String]);
            return [JSValue valueWithUndefinedInContext:currentCtx];
        }
        if ([act isEqualToString:@"cancelAll"]) {
            darwin_notification_cancel_all();
            return [JSValue valueWithUndefinedInContext:currentCtx];
        }
        if ([act isEqualToString:@"removeDelivered"]) {
            NSString* id_ = argsVal[@"id"] ? [argsVal[@"id"] toString] : @"";
            darwin_notification_remove_delivered([id_ UTF8String]);
            return [JSValue valueWithUndefinedInContext:currentCtx];
        }
        if ([act isEqualToString:@"removeAllDelivered"]) {
            darwin_notification_remove_all_delivered();
            return [JSValue valueWithUndefinedInContext:currentCtx];
        }
        if ([act isEqualToString:@"update"]) {
            NSString* id_ = argsVal[@"id"] ? [argsVal[@"id"] toString] : @"";
            NSString* title = argsVal[@"title"] ? [argsVal[@"title"] toString] : @"";
            NSString* subtitle = argsVal[@"subtitle"] ? [argsVal[@"subtitle"] toString] : @"";
            NSString* body = argsVal[@"body"] ? [argsVal[@"body"] toString] : @"";
            darwin_notification_update([id_ UTF8String], [title UTF8String], [subtitle UTF8String], [body UTF8String]);
            return [JSValue valueWithUndefinedInContext:currentCtx];
        }
        return [JSValue valueWithUndefinedInContext:currentCtx];
    };

    // dock(action, args) — dispatcher for all dock operations. All are sync,
    // fire-and-forget (they post to the main UI thread internally via the
    // Zen-C bridge and return immediately).
    bridge[@"dock"] = ^(NSString* action, JSValue* argsVal) {
        extern void darwin_dock_show_icon(void);
        extern void darwin_dock_hide_icon(void);
        extern void darwin_dock_set_badge(const char*);
        extern void darwin_dock_remove_badge(void);
        extern void darwin_dock_bounce(int);
        extern void darwin_dock_set_icon(const char*);
        extern void darwin_dock_reset_icon(void);

        NSString* act = action ?: @"";
        if ([act isEqualToString:@"showIcon"]) { darwin_dock_show_icon(); return; }
        if ([act isEqualToString:@"hideIcon"]) { darwin_dock_hide_icon(); return; }
        if ([act isEqualToString:@"setBadge"]) {
            NSString* label = argsVal[@"label"] ? [argsVal[@"label"] toString] : @"";
            darwin_dock_set_badge([label UTF8String]); return;
        }
        if ([act isEqualToString:@"removeBadge"]) { darwin_dock_remove_badge(); return; }
        if ([act isEqualToString:@"bounce"]) {
            int t = argsVal[@"type"] ? [argsVal[@"type"] toInt32] : 0;
            darwin_dock_bounce(t); return;
        }
        if ([act isEqualToString:@"setIcon"]) {
            NSString* p = argsVal[@"path"] ? [argsVal[@"path"] toString] : @"";
            darwin_dock_set_icon([p UTF8String]); return;
        }
        if ([act isEqualToString:@"resetIcon"]) { darwin_dock_reset_icon(); return; }
    };

    // clipboard(action, args) — dispatcher matching the notif/dock pattern.
    // Workers get sync access to NSPasteboard via this host without paying
    // the webview IPC roundtrip. Returns:
    //   readText / readHtml → string (empty if absent)
    //   readFiles → string[] (empty if absent)
    //   readImage → string (base64 PNG, empty if absent)
    //   has → boolean
    //   write* / clear → undefined
    bridge[@"clipboard"] = ^JSValue*(NSString* action, JSValue* argsVal) {
        JSContext* currentCtx = [JSContext currentContext];
        extern char* darwin_clipboard_read_text(void);
        extern bool darwin_clipboard_write_text(const char* text);
        extern char* darwin_clipboard_read_html(void);
        extern bool darwin_clipboard_write_html(const char* html);
        extern char* darwin_clipboard_read_files(void);
        extern char* darwin_clipboard_read_image_png_b64(void);
        extern bool darwin_clipboard_write_image_png_b64(const char* b64);
        extern bool darwin_clipboard_has(const char* fmt);
        extern void darwin_clipboard_clear(void);

        NSString* act = action ?: @"";
        if ([act isEqualToString:@"readText"]) {
            char* s = darwin_clipboard_read_text();
            JSValue* r = s ? [JSValue valueWithObject:[NSString stringWithUTF8String:s] inContext:currentCtx]
                           : [JSValue valueWithObject:@"" inContext:currentCtx];
            if (s) free(s);
            return r;
        }
        if ([act isEqualToString:@"writeText"]) {
            NSString* t = argsVal[@"text"] ? [argsVal[@"text"] toString] : @"";
            darwin_clipboard_write_text([t UTF8String]);
            return [JSValue valueWithUndefinedInContext:currentCtx];
        }
        if ([act isEqualToString:@"readHtml"]) {
            char* s = darwin_clipboard_read_html();
            JSValue* r = s ? [JSValue valueWithObject:[NSString stringWithUTF8String:s] inContext:currentCtx]
                           : [JSValue valueWithObject:@"" inContext:currentCtx];
            if (s) free(s);
            return r;
        }
        if ([act isEqualToString:@"writeHtml"]) {
            NSString* h = argsVal[@"html"] ? [argsVal[@"html"] toString] : @"";
            darwin_clipboard_write_html([h UTF8String]);
            return [JSValue valueWithUndefinedInContext:currentCtx];
        }
        if ([act isEqualToString:@"readFiles"]) {
            char* json = darwin_clipboard_read_files();
            // Returned as JSON-array string; parse to array on JS side.
            // Pass through as a JS string here — the runtime wrapper
            // calls JSON.parse on it.
            JSValue* r = json ? [JSValue valueWithObject:[NSString stringWithUTF8String:json] inContext:currentCtx]
                              : [JSValue valueWithObject:@"[]" inContext:currentCtx];
            if (json) free(json);
            return r;
        }
        if ([act isEqualToString:@"readImage"]) {
            char* b64 = darwin_clipboard_read_image_png_b64();
            JSValue* r = b64 ? [JSValue valueWithObject:[NSString stringWithUTF8String:b64] inContext:currentCtx]
                             : [JSValue valueWithObject:@"" inContext:currentCtx];
            if (b64) free(b64);
            return r;
        }
        if ([act isEqualToString:@"writeImage"]) {
            NSString* b64 = argsVal[@"data"] ? [argsVal[@"data"] toString] : @"";
            darwin_clipboard_write_image_png_b64([b64 UTF8String]);
            return [JSValue valueWithUndefinedInContext:currentCtx];
        }
        if ([act isEqualToString:@"has"]) {
            NSString* fmt = argsVal[@"format"] ? [argsVal[@"format"] toString] : @"";
            BOOL has = darwin_clipboard_has([fmt UTF8String]);
            return [JSValue valueWithBool:has inContext:currentCtx];
        }
        if ([act isEqualToString:@"clear"]) {
            darwin_clipboard_clear();
            return [JSValue valueWithUndefinedInContext:currentCtx];
        }
        return [JSValue valueWithUndefinedInContext:currentCtx];
    };

    // shortcuts(action, args) — register/unregister/isRegistered/unregisterAll.
    // Returns boolean for the per-accelerator actions, undefined for
    // unregisterAll. Workers can register hotkeys directly without IPC.
    bridge[@"shortcuts"] = ^JSValue*(NSString* action, JSValue* argsVal) {
        JSContext* currentCtx = [JSContext currentContext];
        extern bool darwin_shortcut_register(const char* a);
        extern bool darwin_shortcut_unregister(const char* a);
        extern bool darwin_shortcut_is_registered(const char* a);
        extern void darwin_shortcut_unregister_all(void);

        NSString* act = action ?: @"";
        if ([act isEqualToString:@"unregisterAll"]) {
            darwin_shortcut_unregister_all();
            return [JSValue valueWithUndefinedInContext:currentCtx];
        }
        NSString* acc = argsVal[@"accelerator"] ? [argsVal[@"accelerator"] toString] : @"";
        if ([act isEqualToString:@"register"]) {
            return [JSValue valueWithBool:darwin_shortcut_register([acc UTF8String])
                                inContext:currentCtx];
        }
        if ([act isEqualToString:@"unregister"]) {
            return [JSValue valueWithBool:darwin_shortcut_unregister([acc UTF8String])
                                inContext:currentCtx];
        }
        if ([act isEqualToString:@"isRegistered"]) {
            return [JSValue valueWithBool:darwin_shortcut_is_registered([acc UTF8String])
                                inContext:currentCtx];
        }
        return [JSValue valueWithUndefinedInContext:currentCtx];
    };

    // Expose the worker's own id on the bridge — mirrors bare's
    // behavior and lets user code (e.g. self-identifying in logs,
    // benchmarks, supervisor reports) read it without going through
    // a host call.
    bridge[@"workerId"] = wid;

    ctx[@"__zappBridge"] = bridge;

    // setTimeout / setInterval
    // Dispatch the callback back onto this worker's own serial queue so JS
    // runs on the worker thread. Running it on the main queue (the previous
    // behavior) made every host object that uses dispatch_sync(main) — like
    // createWindow — deadlock when called from a timer callback.
    dispatch_queue_t workerQueue = jsc_queues[wid];
    ctx[@"setTimeout"] = ^JSValue*(JSValue* callback, JSValue* delayMs) {
        double ms = [delayMs isUndefined] ? 0 : [delayMs toDouble];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
            workerQueue ?: dispatch_get_main_queue(), ^{
                [callback callWithArguments:@[]];
            });
        return [JSValue valueWithInt32:1 inContext:[JSContext currentContext]];
    };

    ctx[@"clearTimeout"] = ^(JSValue* timerId) {
        (void)timerId; // simplified — real impl would track timer IDs
    };

    // performance.now() — high-resolution monotonic timer in milliseconds.
    // JSC plain contexts don't ship the Web Performance API; WKWebView adds
    // it for main-world contexts but workers (which are bare JSContexts
    // here) need us to provide it. systemUptime is sub-microsecond on macOS.
    {
        JSValue* perf = [JSValue valueWithNewObjectInContext:ctx];
        perf[@"now"] = ^double() {
            return [NSProcessInfo processInfo].systemUptime * 1000.0;
        };
        ctx[@"performance"] = perf;
    }

    // self reference (worker global)
    ctx[@"self"] = ctx[@"globalThis"];

    // self.postMessage — standard Worker API (delegates to postToWebview)
    ctx[@"postMessage"] = ^(JSValue* data) {
        NSString* json = @"{}";
        if (data && ![data isUndefined]) {
            NSData* d = [NSJSONSerialization dataWithJSONObject:[data toObject] options:0 error:nil];
            if (d) json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }
        worker_dispatch_to_webview([wid UTF8String], [json UTF8String]);
    };

    // Worker bootstrap — generated from bootstrap/worker.ts via codegen
    // Sets up self.send/self.receive channel API and message handler dispatch
    ctx.globalObject[@"_messageHandlers"] = [JSValue valueWithNewArrayInContext:ctx];

    extern const char* zapp_worker_bootstrap_script(void);
    const char* workerBoot = zapp_worker_bootstrap_script();
    if (workerBoot && workerBoot[0] != '\0') {
        [ctx evaluateScript:[NSString stringWithUTF8String:workerBoot]];
    }
}

// --- Supervisor + crash recovery ---
//
// On uncaught JS exception in a worker:
//   1. Dispatch `worker:crashed` event with worker_id + message + stack.
//   2. Ask the supervisor (registry.zc) whether to restart, give up,
//      or ignore (no policy configured = ignore).
//   3. If restart: clear the old context (ARC handles release), re-run
//      the same script_url in a fresh JSContext on the same queue.
//      Dispatch `worker:restarted`.
//   4. If gave-up: dispatch `worker:gave-up`.
//
// All restart decisions live in registry.zc so adding a new engine
// (txiki etc.) doesn't duplicate policy. Externs declared at the top
// of this file (consolidated for cross-function reach).

// Forward decl — initialize a fresh JSContext for the given worker
// id (engine setup, bridge install, script eval). Used both at first
// create and on supervisor-approved restart.
static void jsc_worker_init_context(NSString* wid, NSString* oid, NSString* scriptUrl);

// Build a JSON payload {"id":"<wid>","message":"<m>","stack":"<s>"}
// safe for embedding in the JS broadcast call. The escape happens
// inside dispatch_event_to_all, so we just need valid JSON.
static NSString* jsc_build_crash_payload(NSString* wid, JSValue* exception) {
    NSString* msg = exception ? [exception toString] : @"unknown";
    JSValue* stackVal = exception ? exception[@"stack"] : nil;
    NSString* stack = (stackVal && ![stackVal isUndefined]) ? [stackVal toString] : @"";
    NSDictionary* d = @{
        @"id": wid ?: @"",
        @"message": msg ?: @"",
        @"stack": stack ?: @"",
        @"incarnation": @(jsc_incarnation_for(wid)),
    };
    NSData* j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    return j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : @"{}";
}

static int jsc_incarnation_for(NSString* wid) {
    for (int i = 0; i < JSC_MAX_WORKERS; i++) {
        if (jsc_workers[i].active && strcmp(jsc_workers[i].worker_id,
                                            [wid UTF8String]) == 0) {
            return jsc_workers[i].incarnation;
        }
    }
    return 0;
}

static void jsc_dispatch_restarted(NSString* wid) {
    NSDictionary* d = @{ @"id": wid ?: @"", @"incarnation": @(jsc_incarnation_for(wid)) };
    NSData* j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    NSString* payload = j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : @"{}";
    dispatch_event_to_all((char*)"worker:restarted", (char*)[payload UTF8String]);
}

static void jsc_dispatch_gave_up(NSString* wid) {
    int inc = jsc_incarnation_for(wid);
    NSDictionary* d = @{
        @"id": wid ?: @"",
        @"finalIncarnation": @(inc),
        @"retriesAttempted": @(inc > 0 ? inc - 1 : 0),
    };
    NSData* j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    NSString* payload = j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : @"{}";
    dispatch_event_to_all((char*)"worker:gave-up", (char*)[payload UTF8String]);
}

// --- C API ---

bool jsc_worker_create(const char* script_url, const char* owner_id, const char* worker_id) {
    if (!script_url || !worker_id) return false;
    jsc_ensure_init();

    NSString* wid = [NSString stringWithUTF8String:worker_id];
    NSString* oid = owner_id ? [NSString stringWithUTF8String:owner_id] : @"";
    NSString* scriptUrl = [NSString stringWithUTF8String:script_url];

    // Create serial dispatch queue for this worker
    NSString* queueName = [NSString stringWithFormat:@"com.zapp.worker.%@", wid];
    dispatch_queue_t queue = dispatch_queue_create([queueName UTF8String], DISPATCH_QUEUE_SERIAL);
    jsc_queues[wid] = queue;

    dispatch_async(queue, ^{
        jsc_worker_init_context(wid, oid, scriptUrl);
    });

    // Register in slot table (storing the script_url so restarts can
    // re-evaluate without the caller re-passing it).
    for (int i = 0; i < JSC_MAX_WORKERS; i++) {
        if (!jsc_workers[i].active) {
            strncpy(jsc_workers[i].worker_id, worker_id, 63);
            strncpy(jsc_workers[i].owner_id, owner_id ?: "", 63);
            jsc_workers[i].active = 1;
            jsc_workers[i].incarnation = 1;
            break;
        }
    }
    return true;
}

// Initialize a fresh JSContext for the given worker. Called from
// jsc_worker_create's dispatch_async, and from the supervisor's
// restart path (also on the same queue).
static void jsc_worker_init_context(NSString* wid, NSString* oid, NSString* scriptUrl) {
        JSContext* ctx = [[JSContext alloc] initWithVirtualMachine:jsc_vm];
        ctx.name = [NSString stringWithFormat:@"Zapp Worker: %@", wid];

        // Capture wid + oid + scriptUrl for the crash + restart path.
        ctx.exceptionHandler = ^(JSContext* c, JSValue* exception) {
            NSLog(@"[worker:%@ ERROR] %@", c.name, exception);

            // 1. Always fire the `worker:crashed` event so observers
            //    know something went wrong, even when no policy is set.
            NSString* crashJson = jsc_build_crash_payload(wid, exception);
            dispatch_event_to_all((char*)"worker:crashed",
                                  (char*)[crashJson UTF8String]);

            // 2. Decision: restart, give up, or ignore.
            int decision = zapp_worker_supervisor_record_failure([wid UTF8String]);
            if (decision == 2) {
                jsc_dispatch_gave_up(wid);
                return;
            }
            if (decision != 1) return;  // 0 = no policy, leave worker dead-ish

            // 3. Restart approved. Schedule the actual recreation on
            //    the same queue *after* this exceptionHandler returns —
            //    the context is still in an exception state right now,
            //    and re-evaluating from inside the handler is unsafe.
            dispatch_queue_t queue = jsc_queues[wid];
            if (!queue) return;
            dispatch_async(queue, ^{
                [jsc_contexts removeObjectForKey:wid];  // ARC releases the old ctx
                for (int i = 0; i < JSC_MAX_WORKERS; i++) {
                    if (jsc_workers[i].active && strcmp(jsc_workers[i].worker_id,
                                                       [wid UTF8String]) == 0) {
                        jsc_workers[i].incarnation++;
                        break;
                    }
                }
                jsc_worker_init_context(wid, oid, scriptUrl);
                jsc_dispatch_restarted(wid);
            });
        };

        // Make inspectable via Safari Develop menu (gated on app config)
        if (app_get_bootstrap_web_content_inspectable()) {
            if ([ctx respondsToSelector:@selector(setInspectable:)]) {
                [ctx setInspectable:YES];
            }
        }

        jsc_contexts[wid] = ctx;
        jsc_setup_bridge(ctx, wid);

        // Load worker script
        // scriptUrl is now "/_workers/worker.mjs" (rewritten by Vite plugin)
        NSString* scriptContent = nil;

        // Try embedded assets first (production builds)
        extern int zapp_build_use_embedded_assets(void);
        // These are defined in zapp_assets.zc (compiled into the Zen-C unit)
        // We access them via extern — they exist at link time when assets are embedded.
        extern int zapp_embedded_assets_count;
        extern ZappEmbeddedAsset zapp_embedded_assets[];
        if (zapp_build_use_embedded_assets() && zapp_embedded_assets_count > 0) {

            for (int ai = 0; ai < zapp_embedded_assets_count; ai++) {
                NSString* assetPath = [NSString stringWithUTF8String:zapp_embedded_assets[ai].path];
                if ([assetPath isEqualToString:scriptUrl]) {
                    if (zapp_embedded_assets[ai].is_brotli && zapp_embedded_assets[ai].uncompressed_len > 0) {
                        uint8_t* out = malloc(zapp_embedded_assets[ai].uncompressed_len + 1);
                        size_t decoded = compression_decode_buffer(
                            out, zapp_embedded_assets[ai].uncompressed_len,
                            zapp_embedded_assets[ai].data, zapp_embedded_assets[ai].len,
                            NULL, COMPRESSION_BROTLI);
                        out[decoded] = '\0';
                        scriptContent = [[NSString alloc] initWithBytesNoCopy:out length:decoded
                            encoding:NSUTF8StringEncoding freeWhenDone:YES];
                    } else {
                        scriptContent = [[NSString alloc] initWithBytes:zapp_embedded_assets[ai].data
                            length:zapp_embedded_assets[ai].len encoding:NSUTF8StringEncoding];
                    }
                    NSLog(@"[zapp] worker loaded from embedded: %@", scriptUrl);
                    break;
                }
            }
        }

        // Fallback: filesystem via dev server (Vite serves /_workers/ in dev)
        if (!scriptContent) {
            // In dev mode, fetch from Vite dev server
            extern const char* zapp_build_initial_url(void);
            const char* devUrl = zapp_build_initial_url();
            if (devUrl && devUrl[0] != '\0') {
                // Dev mode: load from http://localhost:PORT/_workers/worker.mjs
                NSString* fullUrl = [NSString stringWithFormat:@"%s%@",
                    devUrl, scriptUrl];
                NSData* data = [NSData dataWithContentsOfURL:[NSURL URLWithString:fullUrl]];
                if (data) {
                    scriptContent = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    NSLog(@"[zapp] worker loaded from dev server: %@", fullUrl);
                }
            }

            // Last resort: filesystem relative to CWD
            if (!scriptContent) {
                char cwd[1024];
                NSString* base = getcwd(cwd, sizeof(cwd)) ? [NSString stringWithUTF8String:cwd] : @".";
                NSString* fullPath = [base stringByAppendingPathComponent:
                    [@"dist" stringByAppendingPathComponent:scriptUrl]];
                NSError* err = nil;
                scriptContent = [NSString stringWithContentsOfFile:fullPath encoding:NSUTF8StringEncoding error:&err];
                if (scriptContent) NSLog(@"[zapp] worker loaded from filesystem: %@", fullPath);
            }
        }

        if (scriptContent) {
            // JavaScriptCore's public Cocoa API only supports script-mode eval,
            // which forbids top-level await. Wrap user code in an async IIFE so
            // any top-level await becomes a normal await inside an async fn.
            // Bundled workers have no live module imports/exports, so wrapping
            // is semantically safe — top-level vars become locals to the IIFE.
            NSString* wrapped = [NSString stringWithFormat:
                @"(async () => {\n%@\n})().catch(e => { console.error('[worker error]', (e && e.message) || String(e), e && e.stack ? '\\n' + e.stack : ''); });",
                scriptContent];
            [ctx evaluateScript:wrapped withSourceURL:[NSURL URLWithString:scriptUrl]];
        } else {
            NSLog(@"[zapp] worker script not found: %@", scriptUrl);
        }
}

void jsc_worker_post_message(const char* worker_id, const char* data_json) {
    if (!worker_id || !data_json) return;
    NSString* wid = [NSString stringWithUTF8String:worker_id];
    NSString* json = [NSString stringWithUTF8String:data_json];

    dispatch_queue_t queue = jsc_queues[wid];
    if (!queue) return;

    dispatch_async(queue, ^{
        JSContext* ctx = jsc_contexts[wid];
        if (!ctx) return;

        // Parse JSON into a native JSValue — no eval string building, no escaping issues
        NSData* jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil] : json;
        JSValue* dataVal = parsed ? [JSValue valueWithObject:parsed inContext:ctx]
                                  : [JSValue valueWithObject:json inContext:ctx];

        // Create MessageEvent-like object and dispatch
        JSValue* event = [JSValue valueWithObject:@{} inContext:ctx];
        [event setValue:dataVal forProperty:@"data"];

        // Call self.onmessage
        JSValue* onmessage = ctx[@"self"][@"onmessage"];
        if (onmessage && ![onmessage isUndefined]) {
            [onmessage callWithArguments:@[event]];
        }

        // Call _messageHandlers (for channel API)
        JSValue* handlers = ctx[@"self"][@"_messageHandlers"];
        if (handlers && ![handlers isUndefined]) {
            int32_t len = [handlers[@"length"] toInt32];
            for (int i = 0; i < len; i++) {
                JSValue* handler = [handlers valueAtIndex:i];
                if (handler && ![handler isUndefined]) {
                    [handler callWithArguments:@[event]];
                }
            }
        }
    });
}

// Evaluate JS in a worker's context (for sync result dispatch)
void jsc_worker_eval_js(const char* worker_id, const char* js) {
    if (!worker_id || !js) return;
    NSString* wid = [NSString stringWithUTF8String:worker_id];
    NSString* script = [NSString stringWithUTF8String:js];

    dispatch_queue_t queue = jsc_queues[wid];
    JSContext* ctx = jsc_contexts[wid];
    if (!queue || !ctx) return;

    dispatch_async(queue, ^{
        [ctx evaluateScript:script];
    });
}

void jsc_worker_terminate(const char* worker_id) {
    if (!worker_id) return;
    NSString* wid = [NSString stringWithUTF8String:worker_id];

    [jsc_contexts removeObjectForKey:wid];
    [jsc_queues removeObjectForKey:wid];

    for (int i = 0; i < JSC_MAX_WORKERS; i++) {
        if (jsc_workers[i].active && strcmp(jsc_workers[i].worker_id, worker_id) == 0) {
            jsc_workers[i].active = 0;
            break;
        }
    }
    NSLog(@"[zapp] JSC worker terminated: %@", wid);
}

void jsc_worker_terminate_owner(const char* owner_id) {
    if (!owner_id) return;

    // External registry functions for shared worker support
    extern int zapp_worker_registry_is_shared(const char* worker_id);
    extern int zapp_worker_registry_remove_owner(const char* worker_id, const char* owner_id);
    extern void zapp_worker_registry_remove(const char* worker_id);

    for (int i = 0; i < JSC_MAX_WORKERS; i++) {
        if (jsc_workers[i].active && strcmp(jsc_workers[i].owner_id, owner_id) == 0) {
            if (zapp_worker_registry_is_shared(jsc_workers[i].worker_id)) {
                // Shared worker: remove owner reference, terminate only if no owners left
                int remaining = zapp_worker_registry_remove_owner(jsc_workers[i].worker_id, owner_id);
                if (remaining <= 0) {
                    jsc_worker_terminate(jsc_workers[i].worker_id);
                    zapp_worker_registry_remove(jsc_workers[i].worker_id);
                }
            } else {
                // Dedicated worker: terminate immediately
                jsc_worker_terminate(jsc_workers[i].worker_id);
            }
        }
    }
}

// Broadcast a JS snippet to every active worker (headless + webview-owned).
// Used by native event dispatch to deliver app/window events to every worker
// that may have subscribed. Each worker evaluates on its own serial queue.
void jsc_broadcast_eval_js(const char* js) {
    if (!js) return;
    NSString* script = [NSString stringWithUTF8String:js];
    for (int i = 0; i < JSC_MAX_WORKERS; i++) {
        if (!jsc_workers[i].active) continue;
        NSString* wid = [NSString stringWithUTF8String:jsc_workers[i].worker_id];
        dispatch_queue_t queue = jsc_queues[wid];
        JSContext* ctx = jsc_contexts[wid];
        if (!queue || !ctx) continue;
        dispatch_async(queue, ^{
            [ctx evaluateScript:script];
        });
    }
}

