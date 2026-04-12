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

    ctx[@"__zappBridge"] = bridge;

    // setTimeout / setInterval
    ctx[@"setTimeout"] = ^JSValue*(JSValue* callback, JSValue* delayMs) {
        double ms = [delayMs isUndefined] ? 0 : [delayMs toDouble];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
            dispatch_get_main_queue(), ^{
                [callback callWithArguments:@[]];
            });
        return [JSValue valueWithInt32:1 inContext:[JSContext currentContext]];
    };

    ctx[@"clearTimeout"] = ^(JSValue* timerId) {
        (void)timerId; // simplified — real impl would track timer IDs
    };

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

    // Create JSContext on the worker queue
    dispatch_async(queue, ^{
        JSContext* ctx = [[JSContext alloc] initWithVirtualMachine:jsc_vm];
        ctx.name = [NSString stringWithFormat:@"Zapp Worker: %@", wid];
        ctx.exceptionHandler = ^(JSContext* c, JSValue* exception) {
            NSLog(@"[worker:%@ ERROR] %@", c.name, exception);
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
                @"(async () => {\n%@\n})().catch(e => { console.error('[worker error]', e && e.stack ? e.stack : e); });",
                scriptContent];
            [ctx evaluateScript:wrapped withSourceURL:[NSURL URLWithString:scriptUrl]];
        } else {
            NSLog(@"[zapp] worker script not found: %@", scriptUrl);
        }
    });

    // Register in slot table
    for (int i = 0; i < JSC_MAX_WORKERS; i++) {
        if (!jsc_workers[i].active) {
            strncpy(jsc_workers[i].worker_id, worker_id, 63);
            strncpy(jsc_workers[i].owner_id, owner_id ?: "", 63);
            jsc_workers[i].active = 1;
            break;
        }
    }

    return true;
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

// --- Backend worker (privileged, app-level JS context) ---
// JSC first. txiki.js opt-in later for web APIs (fetch, WebSocket, timers).

static JSContext* jsc_backend_ctx = nil;
static dispatch_queue_t jsc_backend_queue = nil;
static BOOL jsc_backend_running = NO;

bool jsc_backend_create(const char* script_path) {
    if (jsc_backend_running) return false;
    if (!script_path) return false;
    jsc_ensure_init();

    NSString* scriptPath = [NSString stringWithUTF8String:script_path];
    jsc_backend_queue = dispatch_queue_create("com.zapp.backend", DISPATCH_QUEUE_SERIAL);

    dispatch_async(jsc_backend_queue, ^{
        JSContext* ctx = [[JSContext alloc] initWithVirtualMachine:jsc_vm];
        ctx.name = @"Zapp Backend";
        ctx.exceptionHandler = ^(JSContext* c, JSValue* exception) {
            (void)c;
            NSLog(@"[backend ERROR] %@", exception);
        };

        // Make inspectable
        if (app_get_bootstrap_web_content_inspectable()) {
            if ([ctx respondsToSelector:@selector(setInspectable:)]) {
                [ctx setInspectable:YES];
            }
        }

        // Set up standard bridge (console, invokeService, syncWait/Notify)
        jsc_setup_bridge(ctx, @"__backend__");

        // Backend-specific host objects
        JSValue* bridge = ctx[@"__zappBridge"];

        // quit — terminate the app
        bridge[@"quit"] = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                exit(0);
            });
        };

        // subscribeWindowEvent — register backend for window events
        bridge[@"subscribeWindowEvent"] = ^(JSValue* windowIdVal, JSValue* eventIdVal) {
            int wid = [windowIdVal toInt32];
            int eid = [eventIdVal toInt32];
            dispatch_async(dispatch_get_main_queue(), ^{
                extern void zapp_window_set_backend_listener(int id, int event_id, int has_listener);
                if (wid < 0) {
                    // Subscribe all windows (wid == -1)
                    for (int i = 0; i < 64; i++) {
                        zapp_window_set_backend_listener(i, eid, 1);
                    }
                } else {
                    zapp_window_set_backend_listener(wid, eid, 1);
                }
            });
        };

        // showNotification — fire-and-forget
        bridge[@"showNotification"] = ^(NSString* title, NSString* body) {
            const char* t = title ? [title UTF8String] : "";
            const char* b = body ? [body UTF8String] : "";
            // Copy strings for async block
            char* tc = strdup(t);
            char* bc = strdup(b);
            dispatch_async(dispatch_get_main_queue(), ^{
                extern void darwin_notification_show_typed(const char*, const char*, const char*, const char*);
                darwin_notification_show_typed(tc, "", bc, "default");
                free(tc);
                free(bc);
            });
        };

        jsc_backend_ctx = ctx;

        // Load backend bootstrap
        extern const char* zapp_backend_bootstrap_script(void);
        const char* bootstrap = zapp_backend_bootstrap_script();
        if (bootstrap && bootstrap[0] != '\0') {
            [ctx evaluateScript:[NSString stringWithUTF8String:bootstrap]];
        }

        // Load user backend script — try embedded first, then filesystem.
        // scriptPath is the canonical URL form ("/_workers/backend.mjs").
        NSString* script = nil;

        extern int zapp_build_use_embedded_assets(void);
        extern int zapp_embedded_assets_count;
        extern ZappEmbeddedAsset zapp_embedded_assets[];
        if (zapp_build_use_embedded_assets() && zapp_embedded_assets_count > 0) {
            for (int ai = 0; ai < zapp_embedded_assets_count; ai++) {
                NSString* assetPath = [NSString stringWithUTF8String:zapp_embedded_assets[ai].path];
                if ([assetPath isEqualToString:scriptPath]) {
                    if (zapp_embedded_assets[ai].is_brotli && zapp_embedded_assets[ai].uncompressed_len > 0) {
                        uint8_t* out = malloc(zapp_embedded_assets[ai].uncompressed_len + 1);
                        size_t decoded = compression_decode_buffer(
                            out, zapp_embedded_assets[ai].uncompressed_len,
                            zapp_embedded_assets[ai].data, zapp_embedded_assets[ai].len,
                            NULL, COMPRESSION_BROTLI);
                        out[decoded] = '\0';
                        script = [[NSString alloc] initWithBytesNoCopy:out length:decoded
                            encoding:NSUTF8StringEncoding freeWhenDone:YES];
                    } else {
                        script = [[NSString alloc] initWithBytes:zapp_embedded_assets[ai].data
                            length:zapp_embedded_assets[ai].len encoding:NSUTF8StringEncoding];
                    }
                    NSLog(@"[zapp] backend loaded from embedded: %@", scriptPath);
                    break;
                }
            }
        }

        if (!script) {
            // Dev: Vite plugin writes workers to .zapp/workers/<basename>
            char cwd[1024];
            NSString* base = getcwd(cwd, sizeof(cwd)) ? [NSString stringWithUTF8String:cwd] : @".";
            NSString* basename = [scriptPath lastPathComponent];
            NSString* fullPath = [[base stringByAppendingPathComponent:@".zapp/workers"]
                stringByAppendingPathComponent:basename];
            NSError* err = nil;
            script = [NSString stringWithContentsOfFile:fullPath encoding:NSUTF8StringEncoding error:&err];
            if (script) NSLog(@"[zapp] backend worker started: %@", fullPath);
            else NSLog(@"[zapp] backend script not found: %@", fullPath);
        }

        if (script) {
            // Async IIFE wrapper enables top-level await — see jsc_worker_create
            // for rationale.
            NSString* wrapped = [NSString stringWithFormat:
                @"(async () => {\n%@\n})().catch(e => { console.error('[backend error]', e && e.stack ? e.stack : e); });",
                script];
            [ctx evaluateScript:wrapped withSourceURL:[NSURL URLWithString:@"backend.mjs"]];
        }
    });

    jsc_backend_running = YES;
    return true;
}

void jsc_backend_terminate(void) {
    if (!jsc_backend_running) return;
    jsc_backend_ctx = nil;
    jsc_backend_queue = nil;
    jsc_backend_running = NO;
    NSLog(@"[zapp] backend worker terminated");
}

void jsc_backend_eval_js(const char* js) {
    if (!jsc_backend_running || !jsc_backend_ctx || !jsc_backend_queue || !js) return;
    NSString* script = [NSString stringWithUTF8String:js];
    dispatch_async(jsc_backend_queue, ^{
        if (jsc_backend_ctx) {
            [jsc_backend_ctx evaluateScript:script];
        }
    });
}

bool jsc_backend_is_running(void) {
    return jsc_backend_running;
}
