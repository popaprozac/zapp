// Windows WebView2 integration.
// COM CINTERFACE style — manual vtable implementations for callbacks.

#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <shlwapi.h>
#include <shellapi.h>

// WebView2 SDK
#include "WebView2.h"
#include <shlobj.h>

#include "webview.h"

// ---------------------------------------------------------------------------
// Self-contained WebView2 loader
// Finds the runtime via registry and loads EmbeddedBrowserWebView.dll directly.
// No WebView2Loader.dll needed. Based on OpenWebView2Loader by jchv.
// ---------------------------------------------------------------------------

typedef HRESULT (STDMETHODCALLTYPE *CreateWebViewEnvInternalFn)(
    int unknown,
    int runtimeType,
    PCWSTR userDataDir,
    IUnknown* options,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler* handler
);
static CreateWebViewEnvInternalFn zapp_CreateEnvInternal = NULL;

static const wchar_t* ZAPP_WV2_STABLE_GUID =
    L"{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";

#if defined(__x86_64__) || defined(_M_X64) || defined(_M_AMD64)
static const wchar_t* ZAPP_WV2_EMBEDDED_DLL_SUBPATH =
    L"\\EBWebView\\x64\\EmbeddedBrowserWebView.dll";
#elif defined(__aarch64__) || defined(_M_ARM64)
static const wchar_t* ZAPP_WV2_EMBEDDED_DLL_SUBPATH =
    L"\\EBWebView\\arm64\\EmbeddedBrowserWebView.dll";
#else
static const wchar_t* ZAPP_WV2_EMBEDDED_DLL_SUBPATH =
    L"\\EBWebView\\x86\\EmbeddedBrowserWebView.dll";
#endif

static int zapp_wv2_find_in_registry(HKEY root, const wchar_t* subkey,
                                     wchar_t* outPath, DWORD outPathSize) {
    HKEY hKey = NULL;
    wchar_t runtimePath[MAX_PATH];
    DWORD cbData = sizeof(runtimePath);

    if (RegOpenKeyExW(root, subkey, 0, KEY_READ | KEY_WOW64_32KEY, &hKey) != ERROR_SUCCESS)
        return 0;
    LSTATUS status = RegQueryValueExW(hKey, L"EBWebView", NULL, NULL,
                                      (LPBYTE)runtimePath, &cbData);
    RegCloseKey(hKey);
    if (status != ERROR_SUCCESS) return 0;

    _snwprintf(outPath, outPathSize, L"%s%s", runtimePath, ZAPP_WV2_EMBEDDED_DLL_SUBPATH);
    outPath[outPathSize - 1] = 0;
    return GetFileAttributesW(outPath) != INVALID_FILE_ATTRIBUTES;
}

static int zapp_webview2_loader_init(void) {
    if (zapp_CreateEnvInternal) return 1;

    wchar_t dllPath[MAX_PATH * 2];
    wchar_t regKey[256];
    _snwprintf(regKey, 256, L"Software\\Microsoft\\EdgeUpdate\\ClientState\\%s",
               ZAPP_WV2_STABLE_GUID);
    regKey[255] = 0;

    int found = zapp_wv2_find_in_registry(HKEY_CURRENT_USER, regKey, dllPath, MAX_PATH * 2)
             || zapp_wv2_find_in_registry(HKEY_LOCAL_MACHINE, regKey, dllPath, MAX_PATH * 2);

    if (!found) {
        fprintf(stderr, "[zapp] WebView2 runtime not found. Install Microsoft Edge WebView2 Runtime.\n");
        return 0;
    }

    HMODULE hmod = LoadLibraryW(dllPath);
    if (!hmod) {
        fprintf(stderr, "[zapp] Failed to load WebView2 runtime DLL (error %lu)\n", GetLastError());
        return 0;
    }

    zapp_CreateEnvInternal = (CreateWebViewEnvInternalFn)
        GetProcAddress(hmod, "CreateWebViewEnvironmentWithOptionsInternal");
    if (!zapp_CreateEnvInternal) {
        fprintf(stderr, "[zapp] CreateWebViewEnvironmentWithOptionsInternal not found\n");
        FreeLibrary(hmod);
        return 0;
    }
    return 1;
}

static HRESULT zapp_create_environment(
    PCWSTR userDataDir,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler* handler) {
    if (!zapp_webview2_loader_init()) return E_FAIL;
    return zapp_CreateEnvInternal(0, 0, userDataDir, NULL, handler);
}

// --- Forward declarations ---

extern void zapp_handle_message_from_window(void* app_ptr, char* msg, int window_id);
extern void* app_get_active(void);
extern const char* zapp_get_app_name(void);
extern HWND zapp_get_hwnd(int32_t window_id);
extern int zapp_is_in_drag_region(int32_t window_id);

// Bootstrap and config accessors
extern char* zapp_webview_bootstrap_script(void);
extern char* service_get_manifest_json(void);
extern char* app_get_bootstrap_name(void);
extern bool app_get_bootstrap_web_content_inspectable(void);
extern bool app_get_bootstrap_application_should_terminate_after_last_window_closed(void);
extern int app_get_bootstrap_max_workers(void);
extern char* zapp_build_initial_url(void);
extern char* zapp_build_asset_root(void);
extern int zapp_build_is_dev(void);
extern int zapp_build_use_embedded_assets(void);
extern char* zapp_build_csp(void);

// --- UTF helpers ---

static wchar_t* utf8_to_wchar_wv(const char* s) {
    if (!s) return NULL;
    int len = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (len <= 0) return NULL;
    wchar_t* ws = (wchar_t*)malloc(len * sizeof(wchar_t));
    MultiByteToWideChar(CP_UTF8, 0, s, -1, ws, len);
    return ws;
}

static char* wchar_to_utf8_wv(const wchar_t* ws) {
    if (!ws) return NULL;
    int len = WideCharToMultiByte(CP_UTF8, 0, ws, -1, NULL, 0, NULL, NULL);
    if (len <= 0) return NULL;
    char* s = (char*)malloc(len);
    WideCharToMultiByte(CP_UTF8, 0, ws, -1, s, len, NULL, NULL);
    return s;
}

// --- Per-window WebView2 state ---

#define ZAPP_MAX_WINDOWS 64

static ICoreWebView2Controller* zapp_controllers[ZAPP_MAX_WINDOWS] = {0};
static ICoreWebView2* zapp_webviews_wv[ZAPP_MAX_WINDOWS] = {0};

// Pending JS eval buffer (before WebView2 is ready)
#define ZAPP_MAX_PENDING_JS 32
static char* zapp_pending_js[ZAPP_MAX_WINDOWS][ZAPP_MAX_PENDING_JS] = {{0}};
static int zapp_pending_js_count[ZAPP_MAX_WINDOWS] = {0};

// --- Eval JS on a window ---
//
// Main-thread funnel (WINDOWS_PORTING.md lesson 6): WebView2 is
// STA/UI-thread-bound — ICoreWebView2_ExecuteScript from a worker
// thread is a cross-apartment COM call that fails silently, which made
// every worker→webview surface (postToWebview ping/pong, Events.emit
// broadcasts, sync results) reach native and then vanish. Off-thread
// callers heap-package the eval and PostMessage it to a message-only
// window owned by the main thread; same-thread calls short-circuit.
// Marshaling BEFORE the pending-JS buffering also makes those arrays
// main-thread-only (they were racy when workers buffered directly).

#define ZAPP_WM_EVAL (WM_APP + 0x45) // 'E'
#define ZAPP_WM_TASK (WM_APP + 0x54) // 'T' — generic fn+arg marshal

typedef struct {
    int32_t window_id;
    char* js;
} ZappEvalTask;

typedef struct {
    void (*fn)(void* arg);
    void* arg;
} ZappUiTask;

static DWORD zapp_ui_thread_id = 0;
static HWND zapp_eval_hwnd = NULL;

static void zapp_eval_on_main(int32_t window_id, const char* js) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOWS) return;
    ICoreWebView2* webview = zapp_webviews_wv[window_id];
    if (!webview) {
        // Buffer for later
        if (zapp_pending_js_count[window_id] < ZAPP_MAX_PENDING_JS) {
            zapp_pending_js[window_id][zapp_pending_js_count[window_id]++] = _strdup(js);
        }
        return;
    }
    wchar_t* wjs = utf8_to_wchar_wv(js);
    if (wjs) {
        ICoreWebView2_ExecuteScript(webview, wjs, NULL);
        free(wjs);
    }
}

static LRESULT CALLBACK zapp_eval_wndproc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == ZAPP_WM_EVAL) {
        ZappEvalTask* task = (ZappEvalTask*) lParam;
        if (task) {
            zapp_eval_on_main(task->window_id, task->js);
            free(task->js);
            free(task);
        }
        return 0;
    }
    if (msg == ZAPP_WM_TASK) {
        ZappUiTask* task = (ZappUiTask*) lParam;
        if (task) {
            task->fn(task->arg);
            free(task);
        }
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// Run fn(arg) on the UI thread (immediately when already there).
// `arg` ownership passes to `fn`. Returns false when the post failed —
// the caller still owns `arg` in that case.
bool zapp_post_to_ui_thread(void (*fn)(void* arg), void* arg) {
    if (!fn) return false;
    if (zapp_ui_thread_id != 0 && GetCurrentThreadId() == zapp_ui_thread_id) {
        fn(arg);
        return true;
    }
    ZappUiTask* task = (ZappUiTask*) malloc(sizeof(ZappUiTask));
    if (!task) return false;
    task->fn = fn;
    task->arg = arg;
    if (!zapp_eval_hwnd || !PostMessageW(zapp_eval_hwnd, ZAPP_WM_TASK, 0, (LPARAM) task)) {
        free(task);
        return false;
    }
    return true;
}

// Called from windows_platform_init (main/UI thread, before any worker
// exists) — records the UI thread and creates the funnel target.
void zapp_webview_init_eval_funnel(void) {
    if (zapp_eval_hwnd) return;
    zapp_ui_thread_id = GetCurrentThreadId();
    static const wchar_t* cls = L"ZappEvalFunnel";
    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = zapp_eval_wndproc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = cls;
    RegisterClassExW(&wc);
    zapp_eval_hwnd = CreateWindowExW(0, cls, L"", 0, 0, 0, 0, 0,
                                     HWND_MESSAGE, NULL, GetModuleHandleW(NULL), NULL);
}

void windows_webview_eval_by_id(int32_t window_id, const char* js) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOWS || !js) return;
    if (zapp_ui_thread_id == 0 || GetCurrentThreadId() == zapp_ui_thread_id) {
        zapp_eval_on_main(window_id, js);
        return;
    }
    ZappEvalTask* task = (ZappEvalTask*) malloc(sizeof(ZappEvalTask));
    if (!task) return;
    task->window_id = window_id;
    task->js = _strdup(js);
    if (!task->js) { free(task); return; }
    if (!zapp_eval_hwnd || !PostMessageW(zapp_eval_hwnd, ZAPP_WM_EVAL, 0, (LPARAM) task)) {
        free(task->js);
        free(task);
    }
}

static void flush_pending_js(int32_t window_id) {
    ICoreWebView2* webview = zapp_webviews_wv[window_id];
    if (!webview) return;
    for (int i = 0; i < zapp_pending_js_count[window_id]; i++) {
        if (zapp_pending_js[window_id][i]) {
            wchar_t* wjs = utf8_to_wchar_wv(zapp_pending_js[window_id][i]);
            if (wjs) {
                ICoreWebView2_ExecuteScript(webview, wjs, NULL);
                free(wjs);
            }
            free(zapp_pending_js[window_id][i]);
            zapp_pending_js[window_id][i] = NULL;
        }
    }
    zapp_pending_js_count[window_id] = 0;
}

void windows_webview_eval(void* hwnd_ptr, const char* js) {
    // Find window_id for this HWND
    HWND hwnd = (HWND)hwnd_ptr;
    for (int i = 0; i < ZAPP_MAX_WINDOWS; i++) {
        if (zapp_get_hwnd(i) == hwnd) {
            windows_webview_eval_by_id(i, js);
            return;
        }
    }
}

void windows_webview_eval_all(const char* js) {
    for (int i = 0; i < ZAPP_MAX_WINDOWS; i++) {
        if (zapp_webviews_wv[i]) {
            windows_webview_eval_by_id(i, js);
        }
    }
}

void windows_webview_navigate(int32_t window_id, const char* url) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOWS) return;
    ICoreWebView2* webview = zapp_webviews_wv[window_id];
    if (!webview) return;
    wchar_t* wurl = utf8_to_wchar_wv(url);
    if (wurl) {
        ICoreWebView2_Navigate(webview, wurl);
        free(wurl);
    }
}

// --- JS string escape (same logic as darwin) ---

static char zapp_escape_buf[4096];

const char* windows_escape_js_string(const char* raw) {
    if (!raw) return "";
    int j = 0;
    for (int i = 0; raw[i] && j < (int)sizeof(zapp_escape_buf) - 2; i++) {
        switch (raw[i]) {
            case '\\': zapp_escape_buf[j++] = '\\'; zapp_escape_buf[j++] = '\\'; break;
            case '\'': zapp_escape_buf[j++] = '\\'; zapp_escape_buf[j++] = '\''; break;
            case '\n': zapp_escape_buf[j++] = '\\'; zapp_escape_buf[j++] = 'n'; break;
            case '\r': zapp_escape_buf[j++] = '\\'; zapp_escape_buf[j++] = 'r'; break;
            default:   zapp_escape_buf[j++] = raw[i]; break;
        }
    }
    zapp_escape_buf[j] = '\0';
    return zapp_escape_buf;
}

void windows_open_external(const char* url) {
    wchar_t* wurl = utf8_to_wchar_wv(url);
    if (wurl) {
        ShellExecuteW(NULL, L"open", wurl, NULL, NULL, SW_SHOWNORMAL);
        free(wurl);
    }
}

// --- Resize WebView2 controller ---

void windows_webview_resize(int32_t window_id, int w, int h) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOWS) return;
    ICoreWebView2Controller* controller = zapp_controllers[window_id];
    if (!controller) return;
    RECT bounds = { 0, 0, w, h };
    ICoreWebView2Controller_put_Bounds(controller, bounds);
}

void windows_webview_notify_position(int32_t window_id) {
    if (window_id < 0 || window_id >= ZAPP_MAX_WINDOWS) return;
    ICoreWebView2Controller* controller = zapp_controllers[window_id];
    if (!controller) return;
    ICoreWebView2Controller_NotifyParentWindowPositionChanged(controller);
}

// ============================================================
// COM callback handlers
// Each needs: QueryInterface, AddRef, Release, Invoke
// ============================================================

// --- Shared IUnknown implementation macro ---

#define DEFINE_IUNKNOWN(TypeName, iid_ref) \
    static HRESULT STDMETHODCALLTYPE TypeName##_QueryInterface( \
        TypeName* This, REFIID riid, void** ppv) { \
        if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &iid_ref)) { \
            *ppv = This; This->lpVtbl->AddRef(This); return S_OK; \
        } \
        *ppv = NULL; return E_NOINTERFACE; \
    } \
    static ULONG STDMETHODCALLTYPE TypeName##_AddRef(TypeName* This) { \
        (void)This; return 1; /* Static instances */ \
    } \
    static ULONG STDMETHODCALLTYPE TypeName##_Release(TypeName* This) { \
        (void)This; return 1; \
    }

// ============================================================
// 3. WebMessageReceived handler (receives bridge messages from JS)
// ============================================================

typedef struct {
    ICoreWebView2WebMessageReceivedEventHandlerVtbl* lpVtbl;
    int32_t window_id;
} ZappMsgHandler;

static HRESULT STDMETHODCALLTYPE ZappMsgHandler_QueryInterface(
    ICoreWebView2WebMessageReceivedEventHandler* This, REFIID riid, void** ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_ICoreWebView2WebMessageReceivedEventHandler)) {
        *ppv = This; return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE ZappMsgHandler_AddRef(ICoreWebView2WebMessageReceivedEventHandler* This) { (void)This; return 1; }
static ULONG STDMETHODCALLTYPE ZappMsgHandler_Release(ICoreWebView2WebMessageReceivedEventHandler* This) { (void)This; return 1; }

static HRESULT STDMETHODCALLTYPE ZappMsgHandler_Invoke(
    ICoreWebView2WebMessageReceivedEventHandler* This,
    ICoreWebView2* sender, ICoreWebView2WebMessageReceivedEventArgs* args) {
    (void)sender;
    ZappMsgHandler* self = (ZappMsgHandler*)This;

    LPWSTR wmsg = NULL;
    ICoreWebView2WebMessageReceivedEventArgs_TryGetWebMessageAsString(args, &wmsg);
    if (wmsg) {
        char* msg = wchar_to_utf8_wv(wmsg);
        CoTaskMemFree(wmsg);
        if (msg) {
            void* app = app_get_active();
            if (app) {
                zapp_handle_message_from_window(app, msg, self->window_id);
            }
            free(msg);
        }
    }
    return S_OK;
}

static ICoreWebView2WebMessageReceivedEventHandlerVtbl ZappMsgHandler_Vtbl = {
    ZappMsgHandler_QueryInterface,
    ZappMsgHandler_AddRef,
    ZappMsgHandler_Release,
    ZappMsgHandler_Invoke,
};

// One handler per window
static ZappMsgHandler zapp_msg_handlers[ZAPP_MAX_WINDOWS];

// ============================================================
// NavigationCompleted handler (visibility toggle workaround)
// https://github.com/MicrosoftEdge/WebView2Feedback/issues/1077
// ============================================================

typedef struct {
    ICoreWebView2NavigationCompletedEventHandlerVtbl* lpVtbl;
    ULONG refCount;
    ICoreWebView2Controller* controller;
    BOOL firstNavDone;
} ZappNavHandler;

static HRESULT STDMETHODCALLTYPE ZappNav_QueryInterface(
    ICoreWebView2NavigationCompletedEventHandler* This, REFIID riid, void** ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_ICoreWebView2NavigationCompletedEventHandler)) {
        *ppv = This; This->lpVtbl->AddRef(This); return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE ZappNav_AddRef(ICoreWebView2NavigationCompletedEventHandler* This) {
    return ++((ZappNavHandler*)This)->refCount;
}
static ULONG STDMETHODCALLTYPE ZappNav_Release(ICoreWebView2NavigationCompletedEventHandler* This) {
    ZappNavHandler* self = (ZappNavHandler*)This;
    if (--self->refCount == 0) { free(self); return 0; }
    return self->refCount;
}
static HRESULT STDMETHODCALLTYPE ZappNav_Invoke(
    ICoreWebView2NavigationCompletedEventHandler* This,
    ICoreWebView2* sender, ICoreWebView2NavigationCompletedEventArgs* args) {
    (void)sender; (void)args;
    ZappNavHandler* self = (ZappNavHandler*)This;
    if (!self->firstNavDone) {
        self->firstNavDone = TRUE;
        // Workaround: toggle visibility to force WebView2 to composite
        ICoreWebView2Controller_put_IsVisible(self->controller, FALSE);
        ICoreWebView2Controller_put_IsVisible(self->controller, TRUE);
        ICoreWebView2Controller_MoveFocus(self->controller, COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
    }
    return S_OK;
}

static ICoreWebView2NavigationCompletedEventHandlerVtbl ZappNav_Vtbl = {
    ZappNav_QueryInterface, ZappNav_AddRef, ZappNav_Release, ZappNav_Invoke
};

// ============================================================
// 2. Controller completed handler
// ============================================================

typedef struct {
    ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl* lpVtbl;
    HWND hwnd;
    int32_t window_id;
    bool inspectable;
    char* url_override;
} ZappControllerHandler;

static HRESULT STDMETHODCALLTYPE ZappCtrl_QueryInterface(
    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler* This, REFIID riid, void** ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler)) {
        *ppv = This; return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE ZappCtrl_AddRef(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler* This) { (void)This; return 1; }
static ULONG STDMETHODCALLTYPE ZappCtrl_Release(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler* This) { (void)This; return 1; }

static HRESULT STDMETHODCALLTYPE ZappCtrl_Invoke(
    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler* This,
    HRESULT errorCode, ICoreWebView2Controller* controller) {

    ZappControllerHandler* self = (ZappControllerHandler*)This;

    if (FAILED(errorCode) || !controller) {
        fprintf(stderr, "[zapp] WebView2 controller creation failed: 0x%08lx\n", errorCode);
        return S_OK;
    }

    int32_t wid = self->window_id;
    zapp_controllers[wid] = controller;
    ICoreWebView2Controller_AddRef(controller);

    // Make controller visible
    ICoreWebView2Controller_put_IsVisible(controller, TRUE);

    // Get WebView2 core
    ICoreWebView2* webview = NULL;
    ICoreWebView2Controller_get_CoreWebView2(controller, &webview);
    if (!webview) return S_OK;
    zapp_webviews_wv[wid] = webview;

    // Configure settings
    ICoreWebView2Settings* settings = NULL;
    ICoreWebView2_get_Settings(webview, &settings);
    if (settings) {
        ICoreWebView2Settings_put_IsScriptEnabled(settings, TRUE);
        ICoreWebView2Settings_put_IsWebMessageEnabled(settings, TRUE);
        ICoreWebView2Settings_put_AreDevToolsEnabled(settings, self->inspectable ? TRUE : FALSE);
        ICoreWebView2Settings_put_IsStatusBarEnabled(settings, FALSE);
        ICoreWebView2Settings_put_IsZoomControlEnabled(settings, FALSE);
    }

    // Set up message handler
    zapp_msg_handlers[wid].lpVtbl = &ZappMsgHandler_Vtbl;
    zapp_msg_handlers[wid].window_id = wid;
    EventRegistrationToken token;
    ICoreWebView2_add_WebMessageReceived(webview,
        (ICoreWebView2WebMessageReceivedEventHandler*)&zapp_msg_handlers[wid], &token);

    // Register NavigationCompleted handler (visibility toggle workaround)
    ZappNavHandler* navHandler = (ZappNavHandler*)calloc(1, sizeof(ZappNavHandler));
    navHandler->lpVtbl = &ZappNav_Vtbl;
    navHandler->refCount = 1;
    navHandler->controller = controller;
    navHandler->firstNavDone = FALSE;
    EventRegistrationToken navToken;
    ICoreWebView2_add_NavigationCompleted(webview,
        (ICoreWebView2NavigationCompletedEventHandler*)navHandler, &navToken);

    // Build bootstrap injection script
    // 1. Config object
    const char* app_name = app_get_bootstrap_name();
    bool inspectable_cfg = app_get_bootstrap_web_content_inspectable();
    bool terminate_cfg = app_get_bootstrap_application_should_terminate_after_last_window_closed();
    int max_workers = app_get_bootstrap_max_workers();
    const char* csp = zapp_build_csp();

    // 2. Service manifest
    const char* manifest = service_get_manifest_json();

    // 3. Window/owner IDs
    char window_id_str[32];
    snprintf(window_id_str, sizeof(window_id_str), "win-%d", wid);

    // theme: seed the current light/dark value so App.getTheme() is
    // correct synchronously on first call — without it, a dark-mode
    // first render would briefly assume "light" (same flash darwin's
    // webview.m seeds against).
    extern const char* windows_get_theme(void);
    const char* theme = windows_get_theme();

    // Build config JS
    static char config_js[4096];
    snprintf(config_js, sizeof(config_js),
        "globalThis.__zappConfig={"
        "name:'%s',"
        "webContentInspectable:%s,"
        "applicationShouldTerminateAfterLastWindowClosed:%s,"
        "maxWorkers:%d,"
        "csp:'%s',"
        "theme:'%s'"
        "};"
        "globalThis.__zappServiceManifest=%s;"
        "globalThis[Symbol.for('zapp.owner')]='%s';"
        "globalThis[Symbol.for('zapp.windowId')]='%s';",
        app_name ? app_name : "Zapp",
        inspectable_cfg ? "true" : "false",
        terminate_cfg ? "true" : "false",
        max_workers,
        csp ? csp : "",
        theme ? theme : "light",
        manifest ? manifest : "[]",
        window_id_str,
        window_id_str);

    // Inject config as user script
    wchar_t* wconfig = utf8_to_wchar_wv(config_js);
    if (wconfig) {
        ICoreWebView2_AddScriptToExecuteOnDocumentCreated(webview, wconfig, NULL);
        free(wconfig);
    }

    // Inject bootstrap (bridge + event system)
    // The bootstrap auto-detects platform: webkit.messageHandlers (macOS) vs chrome.webview (Windows)
    const char* bootstrap = zapp_webview_bootstrap_script();
    if (bootstrap && bootstrap[0]) {
        wchar_t* wbootstrap = utf8_to_wchar_wv(bootstrap);
        if (wbootstrap) {
            ICoreWebView2_AddScriptToExecuteOnDocumentCreated(webview, wbootstrap, NULL);
            free(wbootstrap);
        }
    }

    // Set virtual host mapping for assets (zapp.local → local folder)
    // Need ICoreWebView2_3 for SetVirtualHostNameToFolderMapping
    ICoreWebView2_3* webview3 = NULL;
    HRESULT hr = ICoreWebView2_QueryInterface(webview, &IID_ICoreWebView2_3, (void**)&webview3);
    if (SUCCEEDED(hr) && webview3) {
        const char* asset_root = zapp_build_asset_root();
        int is_dev = zapp_build_is_dev();

        if (is_dev && (!asset_root || !asset_root[0])) {
            // Dev mode: no virtual host mapping needed — we load from localhost
        } else if (asset_root && asset_root[0]) {
            wchar_t* wasset = utf8_to_wchar_wv(asset_root);
            if (wasset) {
                ICoreWebView2_3_SetVirtualHostNameToFolderMapping(
                    webview3, L"zapp.local", wasset,
                    COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW);
                free(wasset);
            }
        }
        ICoreWebView2_3_Release(webview3);
    }

    // Resize to fill window client area
    RECT bounds;
    GetClientRect(self->hwnd, &bounds);
    ICoreWebView2Controller_put_Bounds(controller, bounds);

    // Navigate to initial URL
    const char* initial_url = zapp_build_initial_url();
    const char* nav_url = NULL;
    if (self->url_override && self->url_override[0]) {
        nav_url = self->url_override;
    } else if (initial_url && initial_url[0]) {
        nav_url = initial_url;
    } else {
        nav_url = "https://zapp.local/index.html";
    }
    wchar_t* wnav = utf8_to_wchar_wv(nav_url);
    if (wnav) {
        ICoreWebView2_Navigate(webview, wnav);
        free(wnav);
    }

    // Flush any pending JS evals
    flush_pending_js(wid);

    // Clean up url_override
    if (self->url_override) {
        free(self->url_override);
        self->url_override = NULL;
    }

    return S_OK;
}

static ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl ZappCtrl_Vtbl = {
    ZappCtrl_QueryInterface,
    ZappCtrl_AddRef,
    ZappCtrl_Release,
    ZappCtrl_Invoke,
};

static ZappControllerHandler zapp_ctrl_handlers[ZAPP_MAX_WINDOWS];

// ============================================================
// 1. Environment completed handler
// ============================================================

typedef struct {
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl* lpVtbl;
    HWND hwnd;
    int32_t window_id;
    bool inspectable;
    char* url_override;
} ZappEnvHandler;

static HRESULT STDMETHODCALLTYPE ZappEnv_QueryInterface(
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler* This, REFIID riid, void** ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler)) {
        *ppv = This; return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE ZappEnv_AddRef(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler* This) { (void)This; return 1; }
static ULONG STDMETHODCALLTYPE ZappEnv_Release(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler* This) { (void)This; return 1; }

static HRESULT STDMETHODCALLTYPE ZappEnv_Invoke(
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler* This,
    HRESULT errorCode, ICoreWebView2Environment* env) {

    ZappEnvHandler* self = (ZappEnvHandler*)This;

    if (FAILED(errorCode) || !env) {
        fprintf(stderr, "[zapp] WebView2 environment creation failed: 0x%08lx\n", errorCode);
        fprintf(stderr, "[zapp] Make sure WebView2 runtime is installed.\n");
        return S_OK;
    }

    int32_t wid = self->window_id;

    // Set up controller handler
    zapp_ctrl_handlers[wid].lpVtbl = &ZappCtrl_Vtbl;
    zapp_ctrl_handlers[wid].hwnd = self->hwnd;
    zapp_ctrl_handlers[wid].window_id = wid;
    zapp_ctrl_handlers[wid].inspectable = self->inspectable;
    zapp_ctrl_handlers[wid].url_override = self->url_override;
    self->url_override = NULL; // Transfer ownership

    ICoreWebView2Environment_CreateCoreWebView2Controller(
        env, self->hwnd,
        (ICoreWebView2CreateCoreWebView2ControllerCompletedHandler*)&zapp_ctrl_handlers[wid]);

    return S_OK;
}

static ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl ZappEnv_Vtbl = {
    ZappEnv_QueryInterface,
    ZappEnv_AddRef,
    ZappEnv_Release,
    ZappEnv_Invoke,
};

static ZappEnvHandler zapp_env_handlers[ZAPP_MAX_WINDOWS];

// ============================================================
// Main entry: create WebView2 in a window
// ============================================================

void windows_webview_create(void* hwnd_ptr, bool inspectable, const char* url_override) {
    HWND hwnd = (HWND)hwnd_ptr;

    // Find the window ID for this HWND
    int32_t wid = -1;
    for (int i = 0; i < ZAPP_MAX_WINDOWS; i++) {
        if (zapp_get_hwnd(i) == hwnd) {
            wid = i;
            break;
        }
    }
    if (wid < 0) {
        // Not registered yet — will be registered after window_create returns
        // Use the next available slot
        for (int i = 0; i < ZAPP_MAX_WINDOWS; i++) {
            if (zapp_get_hwnd(i) == NULL) {
                wid = i;
                break;
            }
        }
    }
    if (wid < 0) return;

    // Set up environment handler
    zapp_env_handlers[wid].lpVtbl = &ZappEnv_Vtbl;
    zapp_env_handlers[wid].hwnd = hwnd;
    zapp_env_handlers[wid].window_id = wid;
    zapp_env_handlers[wid].inspectable = inspectable;
    zapp_env_handlers[wid].url_override = url_override ? _strdup(url_override) : NULL;

    // User data directory for WebView2 — use app-specific path
    wchar_t udf[MAX_PATH];
    // Use LocalAppData for persistent user data dir
    if (SUCCEEDED(SHGetFolderPathW(NULL, CSIDL_LOCAL_APPDATA, NULL, 0, udf))) {
        wcscat_s(udf, MAX_PATH, L"\\zapp\\webview2");
    } else {
        GetTempPathW(MAX_PATH, udf);
        wcscat_s(udf, MAX_PATH, L"zapp_webview2");
    }
    // Ensure directory exists
    CreateDirectoryW(udf, NULL);

    // Use self-contained loader (no WebView2Loader.dll needed)
    zapp_create_environment(udf,
        (ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*)&zapp_env_handlers[wid]);
}
