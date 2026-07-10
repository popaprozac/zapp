// Windows embedded-webview ("panel") implementation — child WebView2.
//
// A panel is a second ICoreWebView2Controller parented to the owner
// window's HWND, sharing the host's WebView2 environment (same user-data
// store + browser process). The TS runtime drives it via windows_panel_*
// (router -> panel.zc #else branch -> here). Mirrors darwin/panel.m:
//   - sandboxed v1 (bridge/partition accepted but inert)
//   - placed by absolute CSS-px rect from <zapp-webview>'s tracker
//   - events eval'd back into the owner window as dispatchPanelEvent(...)
//
// WebView2 controllers are STA/UI-thread bound; every panel action arrives
// from the host webview's WebMessageReceived (a t:4 post), which already
// runs on the UI thread, so these run inline without marshaling. Controller
// creation is async, so ops that arrive before the controller is ready are
// buffered (bounds/show/url) and applied in the completed handler.

#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#define CINTERFACE
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "WebView2.h"

// --- Reused from the host webview/window layers ---
extern HWND zapp_get_hwnd(int32_t window_id);                       // window.c
extern ICoreWebView2Environment* zapp_get_webview_environment(void); // webview.c
extern void windows_webview_eval_by_id(int32_t window_id, const char* js); // webview.c
extern char* zapp_escape_dup(const char* src);                     // dispatch.zc (JS single-quote escape)

// --- utf8/wchar helpers (webview.c's are static; keep local copies) ---
static wchar_t* p_u2w(const char* s) {
    if (!s) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t* w = (wchar_t*)malloc((size_t)n * sizeof(wchar_t));
    if (w) MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}
static char* p_w2u(const wchar_t* w) {
    if (!w) return NULL;
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char* s = (char*)malloc((size_t)n);
    if (s) WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
    return s;
}

// JSON-string escape (backslash, double-quote, CR/LF) so a raw value can be
// embedded inside a JSON literal we build by hand. The outer panel_emit then
// JS-escapes the whole thing for its single-quoted literal — the two stages
// compose (same scheme darwin's panel.m uses for did-navigate URLs).
static char* p_json_escape(const char* s) {
    if (!s) { char* e = (char*)malloc(1); if (e) e[0] = '\0'; return e; }
    size_t n = strlen(s);
    char* dst = (char*)malloc(n * 2 + 1);
    if (!dst) return NULL;
    size_t j = 0;
    for (size_t i = 0; i < n; i++) {
        switch (s[i]) {
            case '\\': dst[j++] = '\\'; dst[j++] = '\\'; break;
            case '"':  dst[j++] = '\\'; dst[j++] = '"';  break;
            case '\n': dst[j++] = '\\'; dst[j++] = 'n';  break;
            case '\r': dst[j++] = '\\'; dst[j++] = 'r';  break;
            default:   dst[j++] = s[i]; break;
        }
    }
    dst[j] = '\0';
    return dst;
}

static int p_round(double v) { return (int)(v < 0 ? v - 0.5 : v + 0.5); }

// ============================================================
// Per-panel state + COM handler structs
// ============================================================

typedef struct ZappWinPanel ZappWinPanel;

typedef struct {
    ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl* lpVtbl;
    ZappWinPanel* panel;
} PanelCtrlHandler;
typedef struct {
    ICoreWebView2WebMessageReceivedEventHandlerVtbl* lpVtbl;
    ZappWinPanel* panel;
} PanelMsgHandler;
typedef struct {
    ICoreWebView2NavigationCompletedEventHandlerVtbl* lpVtbl;
    ZappWinPanel* panel;
} PanelNavHandler;
typedef struct {
    ICoreWebView2DocumentTitleChangedEventHandlerVtbl* lpVtbl;
    ZappWinPanel* panel;
} PanelTitleHandler;

struct ZappWinPanel {
    int      active;
    char     panel_id[64];
    int32_t  owner_window_id;
    HWND     owner_hwnd;
    HWND     host_hwnd;       // intermediate child window (z-order + clip)

    ICoreWebView2Controller* controller;
    ICoreWebView2*           webview;

    PanelCtrlHandler  ctrl_handler;
    PanelMsgHandler   msg_handler;
    PanelNavHandler   nav_handler;
    PanelTitleHandler title_handler;

    int   ready;              // controller created + wired
    RECT  pending_bounds;     // CSS-px rect buffered until ready
    int   has_pending_bounds;
    int   want_show;          // panelShow seen before ready
    int   visible;
    int   first_nav_done;     // compositing-nudge guard (see PNav_Invoke)
    char* pending_url;        // initial URL, navigated on ready
};

#define ZAPP_MAX_PANELS 64
static ZappWinPanel zapp_panels[ZAPP_MAX_PANELS];

static ZappWinPanel* panel_find(const char* panel_id) {
    if (!panel_id) return NULL;
    for (int i = 0; i < ZAPP_MAX_PANELS; i++) {
        if (zapp_panels[i].active && strcmp(zapp_panels[i].panel_id, panel_id) == 0)
            return &zapp_panels[i];
    }
    return NULL;
}
static ZappWinPanel* panel_alloc(void) {
    for (int i = 0; i < ZAPP_MAX_PANELS; i++) {
        if (!zapp_panels[i].active) {
            memset(&zapp_panels[i], 0, sizeof(ZappWinPanel));
            return &zapp_panels[i];
        }
    }
    return NULL;
}

// Eval bridge.dispatchPanelEvent(panelId, event, data) into the owner window.
// data_json is already-JSON (or NULL → undefined); JS-escaped for the literal.
static void panel_emit(ZappWinPanel* p, const char* event, const char* data_json) {
    if (!p) return;
    char* data_arg = NULL;       // "undefined" or "'<escaped json>'"
    char* esc = NULL;
    if (data_json) {
        esc = zapp_escape_dup(data_json);
        if (esc) {
            size_t len = strlen(esc) + 3;
            data_arg = (char*)malloc(len);
            if (data_arg) snprintf(data_arg, len, "'%s'", esc);
        }
    }
    const char* tmpl =
        "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&typeof b.dispatchPanelEvent==='function'){b.dispatchPanelEvent('%s','%s',%s);}})();";
    const char* arg = data_arg ? data_arg : "undefined";
    int needed = snprintf(NULL, 0, tmpl, p->panel_id, event, arg);
    if (needed > 0) {
        char* js = (char*)malloc((size_t)needed + 1);
        if (js) {
            snprintf(js, (size_t)needed + 1, tmpl, p->panel_id, event, arg);
            windows_webview_eval_by_id(p->owner_window_id, js);
            free(js);
        }
    }
    free(esc);
    free(data_arg);
}

// ============================================================
// Event handlers: WebMessageReceived (embed -> host)
// ============================================================

static HRESULT STDMETHODCALLTYPE PMsg_QI(ICoreWebView2WebMessageReceivedEventHandler* This, REFIID riid, void** ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_ICoreWebView2WebMessageReceivedEventHandler)) {
        *ppv = This; return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE PMsg_AddRef(ICoreWebView2WebMessageReceivedEventHandler* This) { (void)This; return 1; }
static ULONG STDMETHODCALLTYPE PMsg_Release(ICoreWebView2WebMessageReceivedEventHandler* This) { (void)This; return 1; }
static HRESULT STDMETHODCALLTYPE PMsg_Invoke(ICoreWebView2WebMessageReceivedEventHandler* This,
        ICoreWebView2* sender, ICoreWebView2WebMessageReceivedEventArgs* args) {
    (void)sender;
    ZappWinPanel* p = ((PanelMsgHandler*)This)->panel;
    if (!p || !p->active) return S_OK;
    LPWSTR wjson = NULL;
    // get_WebMessageAsJson returns the posted value as JSON (objects included);
    // TryGetWebMessageAsString would only cover bare strings.
    if (SUCCEEDED(ICoreWebView2WebMessageReceivedEventArgs_get_WebMessageAsJson(args, &wjson)) && wjson) {
        char* json = p_w2u(wjson);
        CoTaskMemFree(wjson);
        if (json) { panel_emit(p, "message", json); free(json); }
    }
    return S_OK;
}
static ICoreWebView2WebMessageReceivedEventHandlerVtbl PMsg_Vtbl = {
    PMsg_QI, PMsg_AddRef, PMsg_Release, PMsg_Invoke,
};

// --- NavigationCompleted (did-navigate / load-finished / load-failed) ---
static HRESULT STDMETHODCALLTYPE PNav_QI(ICoreWebView2NavigationCompletedEventHandler* This, REFIID riid, void** ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_ICoreWebView2NavigationCompletedEventHandler)) {
        *ppv = This; return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE PNav_AddRef(ICoreWebView2NavigationCompletedEventHandler* This) { (void)This; return 1; }
static ULONG STDMETHODCALLTYPE PNav_Release(ICoreWebView2NavigationCompletedEventHandler* This) { (void)This; return 1; }
static HRESULT STDMETHODCALLTYPE PNav_Invoke(ICoreWebView2NavigationCompletedEventHandler* This,
        ICoreWebView2* sender, ICoreWebView2NavigationCompletedEventArgs* args) {
    (void)sender;
    ZappWinPanel* p = ((PanelNavHandler*)This)->panel;
    if (!p || !p->active || !p->webview) return S_OK;
    BOOL ok = FALSE;
    ICoreWebView2NavigationCompletedEventArgs_get_IsSuccess(args, &ok);
    if (ok) {
        // Compositing nudge: WebView2 can paint blank until the controller's
        // visibility is toggled once (same workaround the host webview uses on
        // its first navigation). Only when already shown — otherwise it would
        // override a panel still waiting on its first panelShow.
        if (!p->first_nav_done && p->visible && p->controller) {
            ICoreWebView2Controller_put_IsVisible(p->controller, FALSE);
            ICoreWebView2Controller_put_IsVisible(p->controller, TRUE);
        }
        p->first_nav_done = 1;
        LPWSTR wuri = NULL;
        ICoreWebView2_get_Source(p->webview, &wuri);
        char* uri = wuri ? p_w2u(wuri) : NULL;
        if (wuri) CoTaskMemFree(wuri);
        char* esc = p_json_escape(uri ? uri : "");
        if (esc) {
            size_t len = strlen(esc) + 16;
            char* json = (char*)malloc(len);
            if (json) {
                snprintf(json, len, "{\"url\":\"%s\"}", esc);
                panel_emit(p, "did-navigate", json);
                free(json);
            }
            free(esc);
        }
        free(uri);
        panel_emit(p, "load-finished", NULL);
    } else {
        COREWEBVIEW2_WEB_ERROR_STATUS st = 0;
        ICoreWebView2NavigationCompletedEventArgs_get_WebErrorStatus(args, &st);
        char json[96];
        snprintf(json, sizeof(json),
            "{\"code\":%d,\"description\":\"navigation failed\"}", (int)st);
        panel_emit(p, "load-failed", json);
    }
    return S_OK;
}
static ICoreWebView2NavigationCompletedEventHandlerVtbl PNav_Vtbl = {
    PNav_QI, PNav_AddRef, PNav_Release, PNav_Invoke,
};

// --- DocumentTitleChanged (title-change) ---
static HRESULT STDMETHODCALLTYPE PTitle_QI(ICoreWebView2DocumentTitleChangedEventHandler* This, REFIID riid, void** ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_ICoreWebView2DocumentTitleChangedEventHandler)) {
        *ppv = This; return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE PTitle_AddRef(ICoreWebView2DocumentTitleChangedEventHandler* This) { (void)This; return 1; }
static ULONG STDMETHODCALLTYPE PTitle_Release(ICoreWebView2DocumentTitleChangedEventHandler* This) { (void)This; return 1; }
static HRESULT STDMETHODCALLTYPE PTitle_Invoke(ICoreWebView2DocumentTitleChangedEventHandler* This,
        ICoreWebView2* sender, IUnknown* args) {
    (void)sender; (void)args;
    ZappWinPanel* p = ((PanelTitleHandler*)This)->panel;
    if (!p || !p->active || !p->webview) return S_OK;
    LPWSTR wt = NULL;
    ICoreWebView2_get_DocumentTitle(p->webview, &wt);
    char* t = wt ? p_w2u(wt) : NULL;
    if (wt) CoTaskMemFree(wt);
    char* esc = p_json_escape(t ? t : "");
    if (esc) {
        size_t len = strlen(esc) + 16;
        char* json = (char*)malloc(len);
        if (json) {
            snprintf(json, len, "{\"title\":\"%s\"}", esc);
            panel_emit(p, "title-change", json);
            free(json);
        }
        free(esc);
    }
    free(t);
    return S_OK;
}
static ICoreWebView2DocumentTitleChangedEventHandlerVtbl PTitle_Vtbl = {
    PTitle_QI, PTitle_AddRef, PTitle_Release, PTitle_Invoke,
};

// ============================================================
// Bounds (CSS px -> physical px via the controller's RasterizationScale)
// ============================================================

// CSS px -> physical px factor. Use the window's DPI, NOT the controller's
// RasterizationScale: right after CreateCoreWebView2Controller the controller
// still reports the default scale 1.0 (it hasn't detected the monitor scale
// yet), so first-mount bounds came out as css*1.0 and the panel landed up-left
// on a >100% display, snapping correct only once a later event refreshed the
// scale. GetDpiForWindow is right immediately. Loaded dynamically so the build
// doesn't depend on a specific MinGW header WINVER; falls back to 1.0 pre-Win10
// (where WebView2 isn't supported anyway).
static double panel_scale(ZappWinPanel* p) {
    typedef UINT (WINAPI *GetDpiForWindow_t)(HWND);
    static GetDpiForWindow_t fn = NULL;
    static int looked = 0;
    if (!looked) {
        looked = 1;
        HMODULE u = GetModuleHandleW(L"user32.dll");
        if (u) fn = (GetDpiForWindow_t)(void*)GetProcAddress(u, "GetDpiForWindow");
    }
    if (fn && p->owner_hwnd) {
        UINT dpi = fn(p->owner_hwnd);
        if (dpi > 0) return (double)dpi / 96.0;
    }
    return 1.0;
}

// Position the panel's child HWND in the owner's client area and fill it with
// the controller. The child window is the layering primitive: parenting the
// controller to the main HWND (like the host webview) gives no z-order
// guarantee, so the panel rendered behind the opaque host surface. A dedicated
// child raised with HWND_TOP composites above it and clips cleanly.
//
// css is the <zapp-webview> rect in CSS px (host viewport, top-left). The host
// webview fills the client area, so CSS origin == client origin; multiplying by
// the controller RasterizationScale (= DPI/96) converts to physical px.
static void panel_apply_bounds(ZappWinPanel* p, RECT css) {
    if (!p->controller || !p->host_hwnd) return;
    double scale = panel_scale(p);
    int x = p_round(css.left * scale);
    int y = p_round(css.top  * scale);
    int w = p_round((css.right - css.left) * scale);
    int h = p_round((css.bottom - css.top) * scale);
    UINT flags = SWP_NOACTIVATE;
    if (!p->visible) flags |= SWP_NOREDRAW; // stays hidden until panelShow
    SetWindowPos(p->host_hwnd, HWND_TOP, x, y, w, h, flags);
    RECT b = { 0, 0, w, h }; // controller fills its child window
    ICoreWebView2Controller_put_Bounds(p->controller, b);
    // WebView2 caches the parent window's screen position for compositing.
    // Moving the child HWND via SetWindowPos doesn't notify it, so content
    // composites at the stale position until an unrelated event nudges it
    // (the "renders center-ish, snaps into place on scroll" bug). Tell the
    // controller its parent moved — same call the host webview makes on
    // window move (windows_webview_notify_position).
    ICoreWebView2Controller_NotifyParentWindowPositionChanged(p->controller);
}

// Lazily register the child window class (DefWindowProc; NULL background so
// WebView2's surface paints with no flash).
static const wchar_t* PANEL_HOST_CLASS = L"ZappPanelHost";
static void panel_register_class(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = NULL;
    wc.lpszClassName = PANEL_HOST_CLASS;
    RegisterClassExW(&wc);
}

// ============================================================
// Controller-completed: wire settings, handlers, shim, initial nav
// ============================================================

static HRESULT STDMETHODCALLTYPE PCtrl_QI(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler* This, REFIID riid, void** ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler)) {
        *ppv = This; return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE PCtrl_AddRef(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler* This) { (void)This; return 1; }
static ULONG STDMETHODCALLTYPE PCtrl_Release(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler* This) { (void)This; return 1; }
static HRESULT STDMETHODCALLTYPE PCtrl_Invoke(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler* This,
        HRESULT errorCode, ICoreWebView2Controller* controller) {
    ZappWinPanel* p = ((PanelCtrlHandler*)This)->panel;
    if (!p || !p->active) return S_OK;
    if (FAILED(errorCode) || !controller) {
        fprintf(stderr, "[zapp] panel controller creation failed: 0x%08lx\n", (unsigned long)errorCode);
        return S_OK;
    }
    p->controller = controller;
    ICoreWebView2Controller_AddRef(controller);
    ICoreWebView2Controller_put_IsVisible(controller, FALSE); // shown on first panelShow

    // Pin the controller's RasterizationScale to the window DPI now, so content
    // renders crisp on the first frame instead of at the default 1.0 until
    // WebView2 detects the monitor (matches the bounds scale in panel_scale).
    {
        ICoreWebView2Controller3* c3 = NULL;
        if (SUCCEEDED(ICoreWebView2Controller_QueryInterface(controller,
                &IID_ICoreWebView2Controller3, (void**)&c3)) && c3) {
            ICoreWebView2Controller3_put_RasterizationScale(c3, panel_scale(p));
            ICoreWebView2Controller3_Release(c3);
        }
    }

    ICoreWebView2* webview = NULL;
    ICoreWebView2Controller_get_CoreWebView2(controller, &webview);
    if (!webview) return S_OK;
    p->webview = webview;

    ICoreWebView2Settings* settings = NULL;
    ICoreWebView2_get_Settings(webview, &settings);
    if (settings) {
        ICoreWebView2Settings_put_IsScriptEnabled(settings, TRUE);
        ICoreWebView2Settings_put_IsWebMessageEnabled(settings, TRUE);
        ICoreWebView2Settings_put_IsStatusBarEnabled(settings, FALSE);
        ICoreWebView2Settings_put_AreDefaultContextMenusEnabled(settings, TRUE);
    }

    // embed -> host shim (sandboxed v1: no __zappBridge), parity with
    // panel.m's window.zappHost. Routes to chrome.webview.postMessage.
    const wchar_t* shim =
        L"window.zappHost={postMessage:function(d){"
        L"try{window.chrome.webview.postMessage(d);}catch(e){}}};";
    ICoreWebView2_AddScriptToExecuteOnDocumentCreated(webview, shim, NULL);

    EventRegistrationToken tok;
    p->msg_handler.lpVtbl = &PMsg_Vtbl;   p->msg_handler.panel = p;
    ICoreWebView2_add_WebMessageReceived(webview,
        (ICoreWebView2WebMessageReceivedEventHandler*)&p->msg_handler, &tok);
    p->nav_handler.lpVtbl = &PNav_Vtbl;   p->nav_handler.panel = p;
    ICoreWebView2_add_NavigationCompleted(webview,
        (ICoreWebView2NavigationCompletedEventHandler*)&p->nav_handler, &tok);
    p->title_handler.lpVtbl = &PTitle_Vtbl; p->title_handler.panel = p;
    ICoreWebView2_add_DocumentTitleChanged(webview,
        (ICoreWebView2DocumentTitleChangedEventHandler*)&p->title_handler, &tok);

    p->ready = 1;

    // Apply buffered ops that arrived before the controller existed. Set
    // visibility from want_show first so panel_apply_bounds reveals the child
    // window (SWP_SHOWWINDOW) rather than leaving it hidden.
    if (p->want_show) p->visible = 1;
    if (p->has_pending_bounds) panel_apply_bounds(p, p->pending_bounds);
    if (p->visible) {
        ICoreWebView2Controller_put_IsVisible(controller, TRUE);
        if (p->host_hwnd) SetWindowPos(p->host_hwnd, HWND_TOP, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }
    if (p->pending_url && p->pending_url[0]) {
        wchar_t* wurl = p_u2w(p->pending_url);
        if (wurl) { ICoreWebView2_Navigate(webview, wurl); free(wurl); }
    }
    free(p->pending_url);
    p->pending_url = NULL;
    return S_OK;
}
static ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl PCtrl_Vtbl = {
    PCtrl_QI, PCtrl_AddRef, PCtrl_Release, PCtrl_Invoke,
};

// ============================================================
// Public API (called from panel.zc #else branch)
// ============================================================

void windows_panel_create(int32_t window_id, const char* panel_id,
                          const char* url, bool bridge, const char* partition) {
    (void)bridge; (void)partition; // v1: sandboxed, shared store
    if (!panel_id) return;
    if (panel_find(panel_id)) return; // already exists

    ICoreWebView2Environment* env = zapp_get_webview_environment();
    HWND owner = zapp_get_hwnd(window_id);
    if (!env || !owner) return; // host webview not up yet — panel won't create
    // The panel's CSS bounds are relative to the host webview's content, which
    // in paned windows lives in a child HWND offset from the top-level host.
    // Parent the panel to that webview window so its bounds map directly and it
    // clips to the content pane; parenting to the host offsets it by the pane
    // (e.g. sidebar) width — the "embedded webview mis-positions" bug.
    extern void* windows_webview_parent_hwnd(int32_t);
    HWND panel_parent = (HWND)windows_webview_parent_hwnd(window_id);
    if (!panel_parent) panel_parent = owner;

    ZappWinPanel* p = panel_alloc();
    if (!p) return;
    p->active = 1;
    snprintf(p->panel_id, sizeof(p->panel_id), "%s", panel_id);
    p->owner_window_id = window_id;
    p->owner_hwnd = owner;
    p->pending_url = (url && url[0]) ? _strdup(url) : NULL;

    // Intermediate child window: created hidden (no WS_VISIBLE) at 0-size;
    // panelSetBounds positions it, panelShow reveals it. WS_CLIPSIBLINGS so it
    // doesn't paint over / get painted by the host webview surface.
    panel_register_class();
    p->host_hwnd = CreateWindowExW(0, PANEL_HOST_CLASS, L"",
        WS_CHILD | WS_CLIPSIBLINGS, 0, 0, 0, 0,
        panel_parent, NULL, GetModuleHandleW(NULL), NULL);
    if (!p->host_hwnd) { free(p->pending_url); p->active = 0; return; }

    p->ctrl_handler.lpVtbl = &PCtrl_Vtbl;
    p->ctrl_handler.panel = p;
    ICoreWebView2Environment_CreateCoreWebView2Controller(env, p->host_hwnd,
        (ICoreWebView2CreateCoreWebView2ControllerCompletedHandler*)&p->ctrl_handler);
}

void windows_panel_set_bounds(const char* panel_id, int32_t x, int32_t y, int32_t w, int32_t h) {
    ZappWinPanel* p = panel_find(panel_id);
    if (!p) return;
    RECT css = { x, y, x + w, y + h };
    if (!p->ready) { p->pending_bounds = css; p->has_pending_bounds = 1; return; }
    panel_apply_bounds(p, css);
}

void windows_panel_load_url(const char* panel_id, const char* url) {
    ZappWinPanel* p = panel_find(panel_id);
    if (!p || !url) return;
    if (!p->ready) {
        free(p->pending_url);
        p->pending_url = url[0] ? _strdup(url) : NULL;
        return;
    }
    wchar_t* wurl = p_u2w(url);
    if (wurl) { ICoreWebView2_Navigate(p->webview, wurl); free(wurl); }
}

void windows_panel_eval_js(const char* panel_id, const char* js) {
    ZappWinPanel* p = panel_find(panel_id);
    if (!p || !p->ready || !js) return;
    wchar_t* wjs = p_u2w(js);
    if (wjs) { ICoreWebView2_ExecuteScript(p->webview, wjs, NULL); free(wjs); }
}

void windows_panel_post_message(const char* panel_id, const char* data_json) {
    ZappWinPanel* p = panel_find(panel_id);
    if (!p || !p->ready || !data_json) return;
    // data_json is already-JSON (a valid JS literal). Dispatch a MessageEvent
    // on the embed's window, same shape as darwin_panel_post_message.
    const char* tmpl = "window.dispatchEvent(new MessageEvent('message',{data:%s}));";
    int needed = snprintf(NULL, 0, tmpl, data_json);
    if (needed <= 0) return;
    char* js = (char*)malloc((size_t)needed + 1);
    if (!js) return;
    snprintf(js, (size_t)needed + 1, tmpl, data_json);
    wchar_t* wjs = p_u2w(js);
    if (wjs) { ICoreWebView2_ExecuteScript(p->webview, wjs, NULL); free(wjs); }
    free(js);
}

void windows_panel_show(const char* panel_id) {
    ZappWinPanel* p = panel_find(panel_id);
    if (!p) return;
    p->visible = 1;
    if (!p->ready) { p->want_show = 1; return; }
    ICoreWebView2Controller_put_IsVisible(p->controller, TRUE);
    if (p->host_hwnd) SetWindowPos(p->host_hwnd, HWND_TOP, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

void windows_panel_hide(const char* panel_id) {
    ZappWinPanel* p = panel_find(panel_id);
    if (!p) return;
    p->want_show = 0;
    p->visible = 0;
    if (!p->ready) return;
    ICoreWebView2Controller_put_IsVisible(p->controller, FALSE);
    if (p->host_hwnd) ShowWindow(p->host_hwnd, SW_HIDE);
}

void windows_panel_reload(const char* panel_id) {
    ZappWinPanel* p = panel_find(panel_id);
    if (p && p->ready) ICoreWebView2_Reload(p->webview);
}

void windows_panel_go_back(const char* panel_id) {
    ZappWinPanel* p = panel_find(panel_id);
    if (p && p->ready) ICoreWebView2_GoBack(p->webview);
}

void windows_panel_go_forward(const char* panel_id) {
    ZappWinPanel* p = panel_find(panel_id);
    if (p && p->ready) ICoreWebView2_GoForward(p->webview);
}

void windows_panel_destroy(const char* panel_id) {
    ZappWinPanel* p = panel_find(panel_id);
    if (!p) return;
    if (p->controller) {
        // Close() detaches from the parent HWND and stops all event handlers
        // (our handler structs live in the panel slot, freed below).
        ICoreWebView2Controller_Close(p->controller);
        ICoreWebView2Controller_Release(p->controller);
    }
    if (p->host_hwnd) DestroyWindow(p->host_hwnd);
    free(p->pending_url);
    p->controller = NULL;
    p->webview = NULL;
    p->host_hwnd = NULL;
    p->pending_url = NULL;
    p->active = 0;
}
