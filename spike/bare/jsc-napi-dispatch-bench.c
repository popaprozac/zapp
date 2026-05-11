// libjs/Bare-libjsc-style NAPI dispatch latency benchmark.
//
// Mirrors the trampoline pattern documented in the libjsc research:
//   js_create_function stashes a callback as an internal property.
//   On call, libjs's trampoline does:
//     1. JSStringCreateWithUTF8CString("__native_function")
//     2. JSObjectGetProperty (the function obj) for that key
//     3. JSObjectGetPrivate on the returned stash object
//     4. invoke the C callback
//   That's the per-call overhead Bare adds.
//
// For comparison: Zapp's worker→native is published at 2.1 µs (JSC,
// via Cocoa JSContext blocks) and 0.3 µs (txiki, via QuickJS
// JS_NewCFunction direct dispatch).

#include <JavaScriptCore/JavaScriptCore.h>
#include <stdio.h>
#include <stdint.h>
#include <time.h>

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

typedef int32_t (*HostCallback)(int32_t arg);
// Side-effecty callback so JSC's JIT can't elide the FFI boundary.
static volatile int64_t global_counter = 0;
static int32_t user_callback(int32_t arg) {
    global_counter += arg;
    return arg + 1;
}

// JSClass with finalize so JSObjectGetPrivate works correctly.
static JSClassRef stash_class = NULL;

// libjs-style NAPI trampoline: lookup __native_function on the
// function object, then JSObjectGetPrivate to get the C callback.
static JSValueRef napi_trampoline(
    JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject,
    size_t argc, const JSValueRef args[], JSValueRef* exception) {
    (void)thisObject;
    JSStringRef name = JSStringCreateWithUTF8CString("__native_function");
    JSValueRef prop = JSObjectGetProperty(ctx, function, name, exception);
    JSStringRelease(name);
    JSObjectRef stash = JSValueToObject(ctx, prop, exception);
    HostCallback cb = (HostCallback)JSObjectGetPrivate(stash);
    int32_t arg = argc > 0 ? (int32_t)JSValueToNumber(ctx, args[0], NULL) : 0;
    int32_t result = cb(arg);
    return JSValueMakeNumber(ctx, result);
}

int main(void) {
    JSGlobalContextRef ctx = JSGlobalContextCreate(NULL);

    // Stash class — minimal, with private data support.
    JSClassDefinition def = kJSClassDefinitionEmpty;
    def.className = "ZappStash";
    stash_class = JSClassCreate(&def);

    // Create the stash object holding the callback pointer.
    JSObjectRef stash = JSObjectMake(ctx, stash_class, (void*)user_callback);

    // Create the JS-callable function and attach the stash as a hidden
    // __native_function property. Using kJSPropertyAttributeDontEnum
    // matches what an embedder would do.
    JSStringRef hostName = JSStringCreateWithUTF8CString("hostNapi");
    JSObjectRef fn = JSObjectMakeFunctionWithCallback(ctx, hostName, napi_trampoline);
    JSStringRef stashKey = JSStringCreateWithUTF8CString("__native_function");
    JSObjectSetProperty(ctx, fn, stashKey, stash, kJSPropertyAttributeDontEnum, NULL);
    JSStringRelease(stashKey);

    JSObjectRef global = JSContextGetGlobalObject(ctx);
    JSObjectSetProperty(ctx, global, hostName, fn, kJSPropertyAttributeNone, NULL);
    JSStringRelease(hostName);

    // Run the loop. Wrap in an IIFE so `let s` doesn't collide across
    // repeated JSEvaluateScript calls (warmup + measure share scope).
    const int N = 1000000;
    char script[256];
    snprintf(script, sizeof(script),
        "(()=>{ let s=0; for (let i=0; i<%d; i++) { s = hostNapi(i); } return s; })()", N);
    JSStringRef loopScript = JSStringCreateWithUTF8CString(script);

    // Warm up (JIT tier-up).
    for (int w = 0; w < 3; w++) {
        JSEvaluateScript(ctx, loopScript, NULL, NULL, 0, NULL);
    }

    // Reset counter so we can verify the loop actually executed.
    global_counter = 0;

    // Time it.
    JSValueRef exc = NULL;
    int64_t t0 = now_ns();
    JSValueRef result = JSEvaluateScript(ctx, loopScript, NULL, NULL, 0, &exc);
    int64_t t1 = now_ns();
    if (exc) {
        JSStringRef excStr = JSValueToStringCopy(ctx, exc, NULL);
        size_t excLen = JSStringGetMaximumUTF8CStringSize(excStr);
        char* buf = (char*)malloc(excLen);
        JSStringGetUTF8CString(excStr, buf, excLen);
        fprintf(stderr, "exception: %s\n", buf);
        free(buf);
        JSStringRelease(excStr);
    }
    JSStringRelease(loopScript);

    int64_t final_s = (int64_t)JSValueToNumber(ctx, result, NULL);

    double ns_per_call = (double)(t1 - t0) / N;
    printf("libjs-style NAPI dispatch: %.1f ns/call (%lld ms total for %dM calls)\n",
        ns_per_call, (t1 - t0) / 1000000, N / 1000000);
    printf("                            ~%.3f µs/call\n", ns_per_call / 1000.0);
    printf("verify: counter=%lld, final s=%lld (expect counter=499999500000, s=999999)\n",
        global_counter, final_s);
    printf("\n");
    printf("Reference points (from Zapp benchmarks):\n");
    printf("  Zapp JSC worker→native:   2.1 µs/call\n");
    printf("  Zapp txiki worker→native: 0.3 µs/call\n");
    printf("  Electron worker→native:    73 µs/call\n");

    JSGlobalContextRelease(ctx);
    JSClassRelease(stash_class);
    return 0;
}
