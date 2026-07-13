// Windows file drag-drop — Approach B (Wails-style JS bridge; parity with darwin's
// native NSView file drag). The bootstrap JS (bootstrap/webview.ts) handles the
// HTML5 dragenter/over/leave/drop for EXTERNAL FILE drags: it preventDefault()s
// them (which stops WebView2 navigating to the dropped file) while leaving in-page
// HTML5 DnD for non-file drags untouched — exactly what macOS does. It posts to us:
//   file-drop-enter:<count>:<x>:<y>   (postMessage)
//   file-drop-over:<x>:<y>            (postMessage)
//   file-drop-leave:<x>:<y>           (postMessage)
//   file-drop:<x>:<y>                 (postMessageWithAdditionalObjects — the File objects)
// We resolve the File objects to ABSOLUTE PATHS via ICoreWebView2File::get_Path
// (WebView2 runtime >= 1.0.1774.30) and emit the framework's file-drop-* WINDOW
// events: {"paths":[...],"x":N,"y":N} (over/leave carry just x/y). enter carries
// `paths` filled to the file COUNT (HTML5 exposes no paths mid-drag, only count).

#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include "WebView2.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

extern void windows_webview_eval_by_id(int32_t window_id, const char* js);
extern char* zapp_js_lit_dup(const char* utf8);  // native/shared/jslit.c — complete quoted JSON/JS literal

// Emit a drop event into the window's webview. Mirrors darwin's
// zapp_dispatchDropEvent (webview.m): bridge._onEvent('<event>', '<json>')
// with the RAW event name and untouched payload — NOT dispatchWindowEvent,
// which is hardcoded for resize/move and would strip `paths` + prefix "window:".
static void fd_emit(int32_t slot, const char* event, const char* data_json) {
    char* esc_name = zapp_js_lit_dup(event);
    char* esc_payload = zapp_js_lit_dup(data_json);
    if (!esc_name || !esc_payload) { free(esc_name); free(esc_payload); return; }
    const char* tmpl =
        "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&typeof b._onEvent==='function'){"
        "b._onEvent(%s,%s);}})();";
    int needed = snprintf(NULL, 0, tmpl, esc_name, esc_payload);
    if (needed > 0) {
        char* js = (char*)malloc((size_t)needed + 1);
        if (js) { snprintf(js, (size_t)needed + 1, tmpl, esc_name, esc_payload);
                  windows_webview_eval_by_id(slot, js); free(js); }
    }
    free(esc_name);
    free(esc_payload);
}

// Append `s` to *buf RAW (structural JSON — braces, keys, coords). No escaping.
static void str_app(char** buf, size_t* len, size_t* cap, const char* s) {
    size_t sl = strlen(s);
    while (*len + sl + 1 >= *cap) { *cap = (*cap ? *cap * 2 : 256); *buf = (char*)realloc(*buf, *cap); }
    memcpy(*buf + *len, s, sl); *len += sl;
}

// Append `s` to *buf, JSON-escaping " and \ — for STRING CONTENT only (paths).
static void json_esc(char** buf, size_t* len, size_t* cap, const char* s) {
    for (const char* p = s; *p; p++) {
        if (*len + 2 >= *cap) { *cap = (*cap ? *cap * 2 : 256); *buf = (char*)realloc(*buf, *cap); }
        if (*p == '"' || *p == '\\') (*buf)[(*len)++] = '\\';
        (*buf)[(*len)++] = *p;
    }
}
static char* json_finish(char* buf, size_t len, size_t cap) {
    if (buf) { if (len + 1 >= cap) buf = (char*)realloc(buf, len + 1); buf[len] = '\0'; }
    return buf;
}

// Resolve the drop's File additional-objects → {"paths":[...],"x":X,"y":Y}.
static char* build_drop_paths_json(ICoreWebView2WebMessageReceivedEventArgs* args, int x, int y) {
    char* buf = NULL; size_t len = 0, cap = 0;
    str_app(&buf, &len, &cap, "{\"paths\":[");
    ICoreWebView2WebMessageReceivedEventArgs2* a2 = NULL;
    if (SUCCEEDED(ICoreWebView2WebMessageReceivedEventArgs_QueryInterface(
            args, &IID_ICoreWebView2WebMessageReceivedEventArgs2, (void**)&a2)) && a2) {
        ICoreWebView2ObjectCollectionView* objs = NULL;
        if (SUCCEEDED(ICoreWebView2WebMessageReceivedEventArgs2_get_AdditionalObjects(a2, &objs)) && objs) {
            UINT n = 0; ICoreWebView2ObjectCollectionView_get_Count(objs, &n);
            for (UINT i = 0; i < n; i++) {
                IUnknown* item = NULL;
                if (FAILED(ICoreWebView2ObjectCollectionView_GetValueAtIndex(objs, i, &item)) || !item) continue;
                ICoreWebView2File* file = NULL;
                if (SUCCEEDED(IUnknown_QueryInterface(item, &IID_ICoreWebView2File, (void**)&file)) && file) {
                    LPWSTR wpath = NULL;
                    if (SUCCEEDED(ICoreWebView2File_get_Path(file, &wpath)) && wpath) {
                        int u8 = WideCharToMultiByte(CP_UTF8, 0, wpath, -1, NULL, 0, NULL, NULL);
                        char* p = (char*)malloc(u8 > 0 ? u8 : 1);
                        if (p && u8 > 0) {
                            WideCharToMultiByte(CP_UTF8, 0, wpath, -1, p, u8, NULL, NULL);
                            if (i) str_app(&buf, &len, &cap, ",");
                            str_app(&buf, &len, &cap, "\""); json_esc(&buf, &len, &cap, p); str_app(&buf, &len, &cap, "\"");
                        }
                        free(p); CoTaskMemFree(wpath);
                    }
                    ICoreWebView2File_Release(file);
                }
                IUnknown_Release(item);
            }
            ICoreWebView2ObjectCollectionView_Release(objs);
        }
        ICoreWebView2WebMessageReceivedEventArgs2_Release(a2);
    }
    char coords[64]; snprintf(coords, sizeof(coords), "],\"x\":%d,\"y\":%d}", x, y);
    str_app(&buf, &len, &cap, coords);
    return json_finish(buf, len, cap);
}

// Handle a "file-drop*" web message from the bootstrap. Returns 1 if consumed.
int windows_filedrop_handle_message(void* args_ptr, const char* msg, int32_t wid) {
    if (!msg || strncmp(msg, "file-drop", 9) != 0) return 0;
    ICoreWebView2WebMessageReceivedEventArgs* args = (ICoreWebView2WebMessageReceivedEventArgs*)args_ptr;
    int x = 0, y = 0, count = 0;
    if (strncmp(msg, "file-drop-enter:", 16) == 0) {
        sscanf(msg + 16, "%d:%d:%d", &count, &x, &y);
        char* buf = NULL; size_t len = 0, cap = 0;      // {"paths":["",…count],"x":x,"y":y}
        str_app(&buf, &len, &cap, "{\"paths\":[");
        for (int i = 0; i < count; i++) { if (i) str_app(&buf, &len, &cap, ","); str_app(&buf, &len, &cap, "\"\""); }
        char c[64]; snprintf(c, sizeof(c), "],\"x\":%d,\"y\":%d}", x, y); str_app(&buf, &len, &cap, c);
        buf = json_finish(buf, len, cap);
        if (buf) { fd_emit(wid, "file-drop-enter", buf); free(buf); }
    } else if (strncmp(msg, "file-drop-over:", 15) == 0) {
        sscanf(msg + 15, "%d:%d", &x, &y);
        char c[64]; snprintf(c, sizeof(c), "{\"x\":%d,\"y\":%d}", x, y); fd_emit(wid, "file-drop-over", c);
    } else if (strncmp(msg, "file-drop-leave:", 16) == 0) {
        sscanf(msg + 16, "%d:%d", &x, &y);
        char c[64]; snprintf(c, sizeof(c), "{\"x\":%d,\"y\":%d}", x, y); fd_emit(wid, "file-drop-leave", c);
    } else if (strncmp(msg, "file-drop:", 10) == 0) {
        sscanf(msg + 10, "%d:%d", &x, &y);
        char* json = build_drop_paths_json(args, x, y);
        if (json) { fd_emit(wid, "file-drop", json); free(json); }
    }
    return 1;
}
