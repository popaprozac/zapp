// Windows "dock" — taskbar analogues for the macOS dock API.
// Badge → ITaskbarList3::SetOverlayIcon with a GDI-drawn red badge
// (the wails v3 dock_windows.go approach); bounce → FlashWindowEx;
// custom window icon → WM_SETICON from the shared WIC loader.
// show_icon/hide_icon have no taskbar-button analogue and no-op.

#define WIN32_LEAN_AND_MEAN
#ifndef COBJMACROS
#define COBJMACROS
#endif
#include <windows.h>
#include <shobjidl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "dock.h"

extern void* windows_window_get_webview(int32_t numeric_id); // returns HWND
extern HICON windows_load_icon_spec(const char* spec, int cx, int cy);

#define ZAPP_DOCK_MAX_WINDOWS 64

static char zapp_dock_badge[64] = "";

static ITaskbarList3* dock_taskbar(void) {
    static ITaskbarList3* tbl = NULL;
    if (!tbl) {
        if (SUCCEEDED(CoCreateInstance(&CLSID_TaskbarList, NULL, CLSCTX_INPROC_SERVER,
                                       &IID_ITaskbarList3, (void**)&tbl))) {
            if (FAILED(ITaskbarList3_HrInit(tbl))) {
                ITaskbarList3_Release(tbl);
                tbl = NULL;
            }
        }
    }
    return tbl;
}

// Draw the badge: red filled circle, white centered text, transparent
// elsewhere. GDI text doesn't write alpha, so after drawing we force
// alpha=255 on every non-black pixel (the badge has no black content).
static HICON dock_draw_badge(const char* label) {
    const int size = 16;
    BITMAPV5HEADER bi;
    memset(&bi, 0, sizeof(bi));
    bi.bV5Size = sizeof(bi);
    bi.bV5Width = size;
    bi.bV5Height = -size;
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;

    void* bits = NULL;
    HDC screen = GetDC(NULL);
    HDC hdc = CreateCompatibleDC(screen);
    HBITMAP bmp = CreateDIBSection(screen, (BITMAPINFO*)&bi, DIB_RGB_COLORS, &bits, NULL, 0);
    ReleaseDC(NULL, screen);
    if (!bmp || !bits) { if (bmp) DeleteObject(bmp); DeleteDC(hdc); return NULL; }
    HGDIOBJ old_bmp = SelectObject(hdc, bmp);

    // Red circle
    HBRUSH brush = CreateSolidBrush(RGB(0xE8, 0x11, 0x23)); // Windows badge red
    HPEN pen = CreatePen(PS_SOLID, 1, RGB(0xE8, 0x11, 0x23));
    HGDIOBJ old_brush = SelectObject(hdc, brush);
    HGDIOBJ old_pen = SelectObject(hdc, pen);
    Ellipse(hdc, 0, 0, size, size);

    // Label — at 16px only 1-2 chars are legible; longer counts render
    // as the count cap, matching the taskbar convention.
    char text[4];
    size_t llen = strlen(label);
    if (llen > 2) { strcpy(text, "9+"); }
    else { memcpy(text, label, llen + 1); }

    HFONT font = CreateFontW(llen > 1 ? -8 : -10, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    HGDIOBJ old_font = SelectObject(hdc, font);
    SetBkMode(hdc, TRANSPARENT);
    SetTextColor(hdc, RGB(255, 255, 255));
    wchar_t wtext[4];
    MultiByteToWideChar(CP_UTF8, 0, text, -1, wtext, 4);
    RECT r = { 0, 0, size, size };
    DrawTextW(hdc, wtext, -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE);

    SelectObject(hdc, old_font);
    SelectObject(hdc, old_pen);
    SelectObject(hdc, old_brush);
    SelectObject(hdc, old_bmp);
    DeleteObject(font);
    DeleteObject(pen);
    DeleteObject(brush);
    DeleteDC(hdc);

    // Fix alpha: GDI drew RGB with alpha 0 — promote every non-black
    // pixel to opaque. (Pure-black pixels stay transparent; the badge
    // palette is red/white only.)
    DWORD* px = (DWORD*)bits;
    for (int i = 0; i < size * size; i++) {
        if (px[i] & 0x00FFFFFF) px[i] |= 0xFF000000;
    }

    HBITMAP mask = CreateBitmap(size, size, 1, 1, NULL);
    ICONINFO ii = { TRUE, 0, 0, mask, bmp };
    HICON icon = CreateIconIndirect(&ii);
    DeleteObject(mask);
    DeleteObject(bmp);
    return icon;
}

static void dock_apply_overlay(HICON icon, const wchar_t* description) {
    ITaskbarList3* tbl = dock_taskbar();
    if (!tbl) return;
    for (int i = 0; i < ZAPP_DOCK_MAX_WINDOWS; i++) {
        HWND hwnd = (HWND)windows_window_get_webview(i);
        if (hwnd && IsWindow(hwnd)) {
            ITaskbarList3_SetOverlayIcon(tbl, hwnd, icon, description);
        }
    }
}

void windows_dock_set_badge(const char* label) {
    if (!label || !label[0]) {
        windows_dock_remove_badge();
        return;
    }
    strncpy(zapp_dock_badge, label, sizeof(zapp_dock_badge) - 1);
    zapp_dock_badge[sizeof(zapp_dock_badge) - 1] = '\0';
    HICON icon = dock_draw_badge(label);
    if (!icon) return;
    wchar_t wdesc[64];
    MultiByteToWideChar(CP_UTF8, 0, label, -1, wdesc, 64);
    dock_apply_overlay(icon, wdesc);
    DestroyIcon(icon); // SetOverlayIcon copies
}

void windows_dock_remove_badge(void) {
    zapp_dock_badge[0] = '\0';
    dock_apply_overlay(NULL, NULL);
}

const char* windows_dock_get_badge(void) {
    return zapp_dock_badge;
}

void windows_dock_bounce(int bounce_type) {
    // 0 = informational (flash a few times), 1 = critical (until focus).
    FLASHWINFO fi;
    memset(&fi, 0, sizeof(fi));
    fi.cbSize = sizeof(fi);
    for (int i = 0; i < ZAPP_DOCK_MAX_WINDOWS; i++) {
        HWND hwnd = (HWND)windows_window_get_webview(i);
        if (!hwnd || !IsWindow(hwnd)) continue;
        fi.hwnd = hwnd;
        if (bounce_type == 1) {
            fi.dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG;
            fi.uCount = 0;
        } else {
            fi.dwFlags = FLASHW_TRAY;
            fi.uCount = 3;
        }
        FlashWindowEx(&fi);
        break; // first window's taskbar button is the app's
    }
}

// Taskbar progress bar (no macOS dock analogue beyond a custom tile view —
// darwin no-ops for now). permille is 0..1000; <0 clears. mode: 0 normal,
// 1 indeterminate, 2 error, 3 paused, 4 none. Applied to the first/primary
// window's taskbar button (like bounce) — the app's progress is conceptually
// global, and Windows progress is per-taskbar-button.
void windows_dock_set_progress(int permille, int mode) {
    ITaskbarList3* tbl = dock_taskbar();
    if (!tbl) return;

    TBPFLAG flag;
    switch (mode) {
        case 1:  flag = TBPF_INDETERMINATE; break;
        case 2:  flag = TBPF_ERROR;         break;
        case 3:  flag = TBPF_PAUSED;        break;
        case 4:  flag = TBPF_NOPROGRESS;    break;
        default: flag = TBPF_NORMAL;        break;
    }
    if (permille < 0) flag = TBPF_NOPROGRESS;

    for (int i = 0; i < ZAPP_DOCK_MAX_WINDOWS; i++) {
        HWND hwnd = (HWND)windows_window_get_webview(i);
        if (!hwnd || !IsWindow(hwnd)) continue;
        ITaskbarList3_SetProgressState(tbl, hwnd, flag);
        // A determinate state also needs a value; indeterminate/none don't.
        if (flag == TBPF_NORMAL || flag == TBPF_ERROR || flag == TBPF_PAUSED) {
            ULONGLONG v = (ULONGLONG)(permille < 0 ? 0 : (permille > 1000 ? 1000 : permille));
            ITaskbarList3_SetProgressValue(tbl, hwnd, v, 1000);
        }
        break; // first window's taskbar button is the app's
    }
}

void windows_dock_set_icon(const char* path) {
    // ("small" is a macro in the Windows headers — hence the names.)
    HICON icon_big = windows_load_icon_spec(path, GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON));
    HICON icon_sm = windows_load_icon_spec(path, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON));
    if (!icon_big && !icon_sm) return;
    for (int i = 0; i < ZAPP_DOCK_MAX_WINDOWS; i++) {
        HWND hwnd = (HWND)windows_window_get_webview(i);
        if (!hwnd || !IsWindow(hwnd)) continue;
        if (icon_big) SendMessageW(hwnd, WM_SETICON, ICON_BIG, (LPARAM)icon_big);
        if (icon_sm) SendMessageW(hwnd, WM_SETICON, ICON_SMALL, (LPARAM)icon_sm);
    }
    // Note: icons stay live while set on windows; Windows doesn't copy.
    // We intentionally leak the previous pair on replacement — bounded
    // by how often apps swap icons (rare), and destroying an icon
    // still referenced by a window draws garbage.
}

void windows_dock_reset_icon(void) {
    // Restore the executable's own icon (resource id 1 by convention,
    // else the generic application icon).
    extern HINSTANCE zapp_get_hinstance(void);
    HICON icon = LoadIconW(zapp_get_hinstance(), MAKEINTRESOURCEW(1));
    if (!icon) icon = LoadIconW(NULL, IDI_APPLICATION);
    for (int i = 0; i < ZAPP_DOCK_MAX_WINDOWS; i++) {
        HWND hwnd = (HWND)windows_window_get_webview(i);
        if (!hwnd || !IsWindow(hwnd)) continue;
        SendMessageW(hwnd, WM_SETICON, ICON_BIG, (LPARAM)icon);
        SendMessageW(hwnd, WM_SETICON, ICON_SMALL, (LPARAM)icon);
    }
}

void windows_dock_show_icon(void) {} // no taskbar-button analogue
void windows_dock_hide_icon(void) {}
