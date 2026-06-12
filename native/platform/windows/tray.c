// Windows tray — Shell_NotifyIcon wrappers. Mirrors darwin/tray.m's
// payload-driven API: slots keyed by a JS-supplied numeric id, click
// events on the __tray:* bridge channels, optional menu (right-click)
// and attached window (left-click toggle).
//
// Callbacks arrive on a hidden message-only window (tray icons need an
// HWND for their callback message); created lazily on first
// tray:create, on the main/UI thread.

#define WIN32_LEAN_AND_MEAN
#ifndef COBJMACROS
#define COBJMACROS
#endif
#include <windows.h>
#include <shellapi.h>
#include <wincodec.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tray.h"
#include "menu.h"

extern void windows_webview_eval_all(const char* js);
extern void worker_broadcast_eval_js(char* js);
extern HINSTANCE zapp_get_hinstance(void);
extern void* windows_window_get_webview(int32_t numeric_id); // returns HWND

#define ZAPP_MAX_TRAYS 16
#define ZAPP_TRAY_CALLBACK_MSG (WM_APP + 0x54) // 'T'

typedef struct {
    int active;
    int32_t id;             // JS-supplied tray id (also the NOTIFYICONDATA uID)
    HICON icon;
    HMENU menu;             // right-click menu (owned)
    int32_t attached_window;// numeric window id, -1 when none
    int toggle_on_click;
    int dismiss_on_blur;    // accepted but unused yet (needs focus tracking)
} ZappTraySlot;

static ZappTraySlot zapp_trays[ZAPP_MAX_TRAYS] = {0};
static HWND zapp_tray_hwnd = NULL;

static ZappTraySlot* tray_slot(int32_t id, int claim) {
    for (int i = 0; i < ZAPP_MAX_TRAYS; i++) {
        if (zapp_trays[i].active && zapp_trays[i].id == id) return &zapp_trays[i];
    }
    if (!claim) return NULL;
    for (int i = 0; i < ZAPP_MAX_TRAYS; i++) {
        if (!zapp_trays[i].active) {
            memset(&zapp_trays[i], 0, sizeof(ZappTraySlot));
            zapp_trays[i].active = 1;
            zapp_trays[i].id = id;
            zapp_trays[i].attached_window = -1;
            return &zapp_trays[i];
        }
    }
    return NULL;
}

// --- JSON helpers (flat keys in the payload's "a" object) ---

static int tray_json_int(const char* json, const char* key, int fallback) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char* p = json ? strstr(json, pattern) : NULL;
    if (!p) return fallback;
    p += strlen(pattern);
    while (*p == ' ') p++;
    if (*p == 't') return 1; // true
    if (*p == 'f') return 0; // false
    return atoi(p);
}

static int tray_json_str(const char* json, const char* key, char* buf, int buf_size) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", key);
    const char* p = json ? strstr(json, pattern) : NULL;
    if (!p) return 0;
    p += strlen(pattern);
    int i = 0;
    while (*p && *p != '"' && i < buf_size - 1) {
        if (*p == '\\' && *(p + 1)) { buf[i++] = *(p + 1); p += 2; }
        else { buf[i++] = *p++; }
    }
    buf[i] = '\0';
    return 1;
}

// Locate the "menu": [...] array inside the payload (NULL when absent).
static const char* tray_find_menu_array(const char* json) {
    const char* p = json ? strstr(json, "\"menu\":") : NULL;
    if (!p) return NULL;
    p += strlen("\"menu\":");
    while (*p == ' ' || *p == '\t') p++;
    return (*p == '[') ? p : NULL;
}

// --- Icon loading (PNG path or data: URL → HICON via WIC) ---

static IWICImagingFactory* tray_wic(void) {
    static IWICImagingFactory* factory = NULL;
    if (!factory) {
        CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER,
                         &IID_IWICImagingFactory, (void**)&factory);
    }
    return factory;
}

static HICON tray_icon_from_bgra(const BYTE* pixels, UINT width, UINT height) {
    BITMAPV5HEADER bi;
    memset(&bi, 0, sizeof(bi));
    bi.bV5Size = sizeof(bi);
    bi.bV5Width = (LONG)width;
    bi.bV5Height = -(LONG)height; // top-down
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;

    void* bits = NULL;
    HDC hdc = GetDC(NULL);
    HBITMAP color = CreateDIBSection(hdc, (BITMAPINFO*)&bi, DIB_RGB_COLORS, &bits, NULL, 0);
    ReleaseDC(NULL, hdc);
    if (!color || !bits) { if (color) DeleteObject(color); return NULL; }
    memcpy(bits, pixels, (size_t)width * height * 4);

    HBITMAP mask = CreateBitmap((int)width, (int)height, 1, 1, NULL);
    ICONINFO ii = { TRUE, 0, 0, mask, color };
    HICON icon = CreateIconIndirect(&ii);
    DeleteObject(color);
    DeleteObject(mask);
    return icon;
}

// Exported: dock.c (window icons) reuses this loader. Decodes a file
// path or data: URL via WIC, scaled to (cx, cy), alpha preserved.
HICON windows_load_icon_spec(const char* spec, int cx, int cy);

static HICON tray_load_icon(const char* spec) {
    return windows_load_icon_spec(spec,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON));
}

HICON windows_load_icon_spec(const char* spec, int cx_in, int cy_in) {
    if (!spec || !spec[0]) return NULL;
    IWICImagingFactory* wic = tray_wic();
    if (!wic) return NULL;

    IWICBitmapDecoder* decoder = NULL;
    IWICStream* stream = NULL;
    BYTE* data_buf = NULL;

    if (strncmp(spec, "data:", 5) == 0) {
        // data:<mime>;base64,<payload>
        const char* comma = strchr(spec, ',');
        if (!comma) return NULL;
        extern BOOL CryptStringToBinaryA(LPCSTR, DWORD, DWORD, BYTE*, DWORD*, DWORD*, DWORD*);
        DWORD bin_len = 0;
        if (!CryptStringToBinaryA(comma + 1, 0, 0x1 /*CRYPT_STRING_BASE64*/, NULL, &bin_len, NULL, NULL)) return NULL;
        data_buf = (BYTE*)malloc(bin_len);
        if (!data_buf) return NULL;
        if (!CryptStringToBinaryA(comma + 1, 0, 0x1, data_buf, &bin_len, NULL, NULL)) { free(data_buf); return NULL; }
        if (FAILED(IWICImagingFactory_CreateStream(wic, &stream)) ||
            FAILED(IWICStream_InitializeFromMemory(stream, data_buf, bin_len)) ||
            FAILED(IWICImagingFactory_CreateDecoderFromStream(wic, (IStream*)stream, NULL,
                       WICDecodeMetadataCacheOnDemand, &decoder))) {
            decoder = NULL;
        }
    } else {
        // File path — relative resolves against the process cwd.
        wchar_t wpath[MAX_PATH];
        MultiByteToWideChar(CP_UTF8, 0, spec, -1, wpath, MAX_PATH);
        if (FAILED(IWICImagingFactory_CreateDecoderFromFilename(wic, wpath, NULL,
                       GENERIC_READ, WICDecodeMetadataCacheOnDemand, &decoder))) {
            decoder = NULL;
        }
    }

    HICON icon = NULL;
    if (decoder) {
        IWICBitmapFrameDecode* frame = NULL;
        IWICFormatConverter* conv = NULL;
        IWICBitmapScaler* scaler = NULL;
        UINT cx = (UINT)cx_in;
        UINT cy = (UINT)cy_in;
        if (SUCCEEDED(IWICBitmapDecoder_GetFrame(decoder, 0, &frame)) &&
            SUCCEEDED(IWICImagingFactory_CreateBitmapScaler(wic, &scaler)) &&
            SUCCEEDED(IWICBitmapScaler_Initialize(scaler, (IWICBitmapSource*)frame,
                          cx, cy, WICBitmapInterpolationModeFant)) &&
            SUCCEEDED(IWICImagingFactory_CreateFormatConverter(wic, &conv)) &&
            SUCCEEDED(IWICFormatConverter_Initialize(conv, (IWICBitmapSource*)scaler,
                          &GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone,
                          NULL, 0.0, WICBitmapPaletteTypeCustom))) {
            UINT stride = cx * 4;
            BYTE* pixels = (BYTE*)malloc((size_t)stride * cy);
            if (pixels && SUCCEEDED(IWICFormatConverter_CopyPixels(
                    conv, NULL, stride, stride * cy, pixels))) {
                icon = tray_icon_from_bgra(pixels, cx, cy);
            }
            free(pixels);
        }
        if (conv) IWICFormatConverter_Release(conv);
        if (scaler) IWICBitmapScaler_Release(scaler);
        if (frame) IWICBitmapFrameDecode_Release(frame);
        IWICBitmapDecoder_Release(decoder);
    }
    if (stream) IWICStream_Release(stream);
    free(data_buf);
    return icon;
}

// --- Event dispatch (same wire shape as darwin) ---

static void tray_dispatch_event(int32_t tray_id, const char* event_name) {
    char js[256];
    snprintf(js, sizeof(js),
        "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&b._onEvent)b._onEvent('%s','{\"id\":%d}');})();",
        event_name, (int)tray_id);
    windows_webview_eval_all(js);
    worker_broadcast_eval_js(js);
}

// --- Click handling ---

// Windows where dismiss-on-blur is armed — checked from the activation
// hook below. (The flyout-anchored-to-tray pattern is native to Windows
// — volume/wifi flyouts — so this mirrors the macOS UX.)
static HWND zapp_tray_blur_windows[ZAPP_MAX_TRAYS] = {0};

// Called by zapp_wndproc on WA_INACTIVE for any app window — hides it
// when a tray attach armed dismissOnBlur for it.
void windows_tray_notify_window_blur(void* hwnd_ptr) {
    HWND hwnd = (HWND)hwnd_ptr;
    for (int i = 0; i < ZAPP_MAX_TRAYS; i++) {
        if (zapp_tray_blur_windows[i] == hwnd && IsWindowVisible(hwnd)) {
            ShowWindow(hwnd, SW_HIDE);
            return;
        }
    }
}

static void tray_arm_blur_dismiss(ZappTraySlot* slot, HWND hwnd) {
    for (int i = 0; i < ZAPP_MAX_TRAYS; i++) {
        if (&zapp_trays[i] == slot) {
            zapp_tray_blur_windows[i] = slot->dismiss_on_blur ? hwnd : NULL;
            return;
        }
    }
}

static void tray_toggle_attached(ZappTraySlot* slot) {
    HWND hwnd = (HWND)windows_window_get_webview(slot->attached_window);
    if (!hwnd) return;
    if (IsWindowVisible(hwnd)) {
        ShowWindow(hwnd, SW_HIDE);
    } else {
        // Anchor to the actual icon rect when the shell can tell us;
        // fall back to the work-area corner.
        RECT wr;
        GetWindowRect(hwnd, &wr);
        int w = wr.right - wr.left;
        int h = wr.bottom - wr.top;

        RECT wa;
        SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
        int x = wa.right - w - 8;
        int y = wa.bottom - h - 8;

        NOTIFYICONIDENTIFIER nii;
        memset(&nii, 0, sizeof(nii));
        nii.cbSize = sizeof(nii);
        nii.hWnd = zapp_tray_hwnd;
        nii.uID = (UINT)slot->id;
        RECT ir;
        if (SUCCEEDED(Shell_NotifyIconGetRect(&nii, &ir))) {
            // Centered above (taskbar at bottom) or below (top) the icon,
            // clamped into the work area.
            int icon_cx = (ir.left + ir.right) / 2;
            x = icon_cx - w / 2;
            if (ir.top >= wa.bottom) y = wa.bottom - h - 8;          // bottom taskbar
            else if (ir.bottom <= wa.top) y = wa.top + 8;            // top taskbar
            else y = (ir.top > (wa.top + wa.bottom) / 2) ? ir.top - h - 8 : ir.bottom + 8;
            if (x < wa.left + 8) x = wa.left + 8;
            if (x + w > wa.right - 8) x = wa.right - w - 8;
        }

        SetWindowPos(hwnd, HWND_TOP, x, y, 0, 0, SWP_NOSIZE | SWP_SHOWWINDOW);
        SetForegroundWindow(hwnd);
        tray_arm_blur_dismiss(slot, hwnd);
    }
}

static LRESULT CALLBACK tray_wndproc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == ZAPP_TRAY_CALLBACK_MSG) {
        int32_t id = (int32_t)wParam;
        ZappTraySlot* slot = tray_slot(id, 0);
        if (!slot) return 0;
        switch (LOWORD(lParam)) {
            case WM_LBUTTONUP:
                if (slot->attached_window >= 0 && slot->toggle_on_click) {
                    tray_toggle_attached(slot);
                } else {
                    tray_dispatch_event(id, "__tray:click");
                }
                break;
            case WM_RBUTTONUP:
                if (slot->menu) {
                    POINT pt;
                    GetCursorPos(&pt);
                    // Required dance for tray menus: foreground first,
                    // and post a no-op after, or the menu won't dismiss
                    // on outside clicks (Q135788).
                    SetForegroundWindow(hwnd);
                    TrackPopupMenu(slot->menu, TPM_RIGHTALIGN | TPM_BOTTOMALIGN,
                                   pt.x, pt.y, 0, hwnd, NULL);
                    PostMessageW(hwnd, WM_NULL, 0, 0);
                } else {
                    tray_dispatch_event(id, "__tray:right-click");
                }
                break;
        }
        return 0;
    }
    if (msg == WM_COMMAND) {
        extern void zapp_handle_menu_command(unsigned int cmd_id);
        WORD cmd = LOWORD(wParam);
        if (HIWORD(wParam) == 0 && cmd >= 0x1000) zapp_handle_menu_command(cmd);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

static HWND tray_ensure_hwnd(void) {
    if (zapp_tray_hwnd) return zapp_tray_hwnd;
    static const wchar_t* cls = L"ZappTrayWindow";
    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = tray_wndproc;
    wc.hInstance = zapp_get_hinstance();
    wc.lpszClassName = cls;
    RegisterClassExW(&wc);
    zapp_tray_hwnd = CreateWindowExW(0, cls, L"", 0, 0, 0, 0, 0,
                                     HWND_MESSAGE, NULL, zapp_get_hinstance(), NULL);
    return zapp_tray_hwnd;
}

// --- Shared payload application (create + the set* variants) ---

static void tray_apply_payload(ZappTraySlot* slot, const char* payload, int is_create) {
    char buf[1024];

    if (tray_json_str(payload, "icon", buf, sizeof(buf)) || is_create) {
        HICON icon = tray_load_icon(buf[0] ? buf : NULL);
        if (!icon && is_create) {
            // Fallback: the app's own icon, else the generic one.
            icon = LoadIconW(zapp_get_hinstance(), MAKEINTRESOURCEW(1));
            if (!icon) icon = LoadIconW(NULL, IDI_APPLICATION);
        }
        if (icon) {
            if (slot->icon) DestroyIcon(slot->icon);
            slot->icon = icon;
        }
    }

    NOTIFYICONDATAW nid;
    memset(&nid, 0, sizeof(nid));
    nid.cbSize = sizeof(nid);
    nid.hWnd = tray_ensure_hwnd();
    nid.uID = (UINT)slot->id;
    nid.uFlags = NIF_MESSAGE | NIF_ICON;
    nid.uCallbackMessage = ZAPP_TRAY_CALLBACK_MSG;
    nid.hIcon = slot->icon;

    // tooltip — also fed by "title" (no menu-bar text on Windows; the
    // closest analogue is hover text).
    char tip[128] = "";
    if (!tray_json_str(payload, "tooltip", tip, sizeof(tip))) {
        tray_json_str(payload, "title", tip, sizeof(tip));
    }
    if (tip[0]) {
        nid.uFlags |= NIF_TIP;
        MultiByteToWideChar(CP_UTF8, 0, tip, -1, nid.szTip, 128);
    }

    const char* menu_json = tray_find_menu_array(payload);
    if (menu_json) {
        HMENU menu = (HMENU)windows_menu_build_from_items_json(menu_json);
        if (menu) {
            if (slot->menu) DestroyMenu(slot->menu);
            slot->menu = menu;
        }
    }

    Shell_NotifyIconW(is_create ? NIM_ADD : NIM_MODIFY, &nid);
}

// --- Public payload API (mirrors darwin_tray_*_from_payload) ---

void windows_tray_create_from_payload(const char* payload_json) {
    int32_t id = (int32_t)tray_json_int(payload_json, "id", -1);
    if (id < 0) return;
    ZappTraySlot* slot = tray_slot(id, 1);
    if (!slot) return;
    tray_apply_payload(slot, payload_json, 1);
}

void windows_tray_set_icon_from_payload(const char* payload_json) {
    int32_t id = (int32_t)tray_json_int(payload_json, "id", -1);
    ZappTraySlot* slot = tray_slot(id, 0);
    if (slot) tray_apply_payload(slot, payload_json, 0);
}

void windows_tray_set_title_from_payload(const char* payload_json) {
    int32_t id = (int32_t)tray_json_int(payload_json, "id", -1);
    ZappTraySlot* slot = tray_slot(id, 0);
    if (slot) tray_apply_payload(slot, payload_json, 0);
}

void windows_tray_set_tooltip_from_payload(const char* payload_json) {
    int32_t id = (int32_t)tray_json_int(payload_json, "id", -1);
    ZappTraySlot* slot = tray_slot(id, 0);
    if (slot) tray_apply_payload(slot, payload_json, 0);
}

void windows_tray_set_menu_from_payload(const char* payload_json) {
    int32_t id = (int32_t)tray_json_int(payload_json, "id", -1);
    ZappTraySlot* slot = tray_slot(id, 0);
    if (slot) tray_apply_payload(slot, payload_json, 0);
}

void windows_tray_destroy_from_payload(const char* payload_json) {
    int32_t id = (int32_t)tray_json_int(payload_json, "id", -1);
    ZappTraySlot* slot = tray_slot(id, 0);
    if (!slot) return;
    NOTIFYICONDATAW nid;
    memset(&nid, 0, sizeof(nid));
    nid.cbSize = sizeof(nid);
    nid.hWnd = zapp_tray_hwnd;
    nid.uID = (UINT)slot->id;
    Shell_NotifyIconW(NIM_DELETE, &nid);
    if (slot->icon) DestroyIcon(slot->icon);
    if (slot->menu) DestroyMenu(slot->menu);
    slot->active = 0;
}

void windows_tray_attach_window_from_payload(const char* payload_json) {
    int32_t id = (int32_t)tray_json_int(payload_json, "id", -1);
    ZappTraySlot* slot = tray_slot(id, 0);
    if (!slot) return;
    slot->attached_window = (int32_t)tray_json_int(payload_json, "windowId", -1);
    slot->toggle_on_click = tray_json_int(payload_json, "toggleOnClick", 1);
    slot->dismiss_on_blur = tray_json_int(payload_json, "dismissOnBlur", 1);
}

void windows_tray_detach_window_from_payload(const char* payload_json) {
    int32_t id = (int32_t)tray_json_int(payload_json, "id", -1);
    ZappTraySlot* slot = tray_slot(id, 0);
    if (!slot) return;
    slot->attached_window = -1;
}
