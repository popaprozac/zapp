// Windows display/screen queries — EnumDisplayMonitors + per-monitor
// DPI. See screen.h for the JSON contract (mirrors darwin/screen.m).

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellscalingapi.h> // GetDpiForMonitor (shcore)
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "screen.h"

// HWND lookup for forWindow — same table window.c maintains.
extern void* windows_window_get_webview(int32_t numeric_id);

// --- Per-monitor JSON ---

// Append one display dict for `mon` into the heap string builder.
// Returns bytes written, or -1 on allocation failure.
typedef struct {
    char* buf;
    size_t len;
    size_t cap;
} ScreenJsonBuf;

static int sb_ensure(ScreenJsonBuf* sb, size_t extra) {
    if (sb->len + extra < sb->cap) return 1;
    while (sb->len + extra >= sb->cap) sb->cap *= 2;
    char* grown = (char*)realloc(sb->buf, sb->cap);
    if (!grown) return 0;
    sb->buf = grown;
    return 1;
}

static int sb_appendf(ScreenJsonBuf* sb, const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int needed = vsnprintf(NULL, 0, fmt, args);
    va_end(args);
    if (needed < 0 || !sb_ensure(sb, (size_t)needed + 1)) return 0;
    va_start(args, fmt);
    vsnprintf(sb->buf + sb->len, (size_t)needed + 1, fmt, args);
    va_end(args);
    sb->len += (size_t)needed;
    return 1;
}

static double screen_scale_for(HMONITOR mon) {
    UINT dpi_x = 96, dpi_y = 96;
    if (FAILED(GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y))) {
        dpi_x = 96;
    }
    return (double)dpi_x / 96.0;
}

static int screen_rotation_for(const wchar_t* device) {
    DEVMODEW dm;
    memset(&dm, 0, sizeof(dm));
    dm.dmSize = sizeof(dm);
    if (EnumDisplaySettingsW(device, ENUM_CURRENT_SETTINGS, &dm)) {
        switch (dm.dmDisplayOrientation) {
            case DMDO_90:  return 90;
            case DMDO_180: return 180;
            case DMDO_270: return 270;
            default:       return 0;
        }
    }
    return 0;
}

static int screen_append_display(ScreenJsonBuf* sb, HMONITOR mon) {
    MONITORINFOEXW mi;
    memset(&mi, 0, sizeof(mi));
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(mon, (MONITORINFO*)&mi)) return 0;

    // Device name like "\\.\DISPLAY1" → "DISPLAY1" for both id and name.
    // (The EDID friendly name needs the DisplayConfig API; deferred.)
    const wchar_t* dev = mi.szDevice;
    const wchar_t* tail = wcsrchr(dev, L'\\');
    tail = tail ? tail + 1 : dev;
    char dev_utf8[64];
    WideCharToMultiByte(CP_UTF8, 0, tail, -1, dev_utf8, sizeof(dev_utf8), NULL, NULL);

    return sb_appendf(sb,
        "{\"id\":\"%s\",\"name\":\"%s\","
        "\"bounds\":{\"x\":%ld,\"y\":%ld,\"width\":%ld,\"height\":%ld},"
        "\"workArea\":{\"x\":%ld,\"y\":%ld,\"width\":%ld,\"height\":%ld},"
        "\"scaleFactor\":%.2f,\"isPrimary\":%s,\"rotation\":%d}",
        dev_utf8, dev_utf8,
        mi.rcMonitor.left, mi.rcMonitor.top,
        mi.rcMonitor.right - mi.rcMonitor.left,
        mi.rcMonitor.bottom - mi.rcMonitor.top,
        mi.rcWork.left, mi.rcWork.top,
        mi.rcWork.right - mi.rcWork.left,
        mi.rcWork.bottom - mi.rcWork.top,
        screen_scale_for(mon),
        (mi.dwFlags & MONITORINFOF_PRIMARY) ? "true" : "false",
        screen_rotation_for(mi.szDevice));
}

// --- Enumeration ---

typedef struct {
    ScreenJsonBuf* sb;
    int count;
    int failed;
} EnumCtx;

static BOOL CALLBACK screen_enum_proc(HMONITOR mon, HDC hdc, LPRECT rect, LPARAM lp) {
    (void)hdc; (void)rect;
    EnumCtx* ctx = (EnumCtx*)lp;
    if (ctx->count > 0 && !sb_appendf(ctx->sb, ",")) { ctx->failed = 1; return FALSE; }
    if (!screen_append_display(ctx->sb, mon)) { ctx->failed = 1; return FALSE; }
    ctx->count++;
    return TRUE;
}

char* windows_screen_list_json(void) {
    ScreenJsonBuf sb = { (char*)malloc(512), 0, 512 };
    if (!sb.buf) return NULL;
    sb.buf[0] = '\0';
    if (!sb_appendf(&sb, "[")) { free(sb.buf); return NULL; }
    EnumCtx ctx = { &sb, 0, 0 };
    EnumDisplayMonitors(NULL, NULL, screen_enum_proc, (LPARAM)&ctx);
    if (ctx.failed || !sb_appendf(&sb, "]")) { free(sb.buf); return NULL; }
    return sb.buf;
}

char* windows_screen_cursor_json(void) {
    POINT pt;
    if (!GetCursorPos(&pt)) return NULL;
    HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
    ScreenJsonBuf sb = { (char*)malloc(512), 0, 512 };
    if (!sb.buf) return NULL;
    sb.buf[0] = '\0';
    if (!sb_appendf(&sb, "{\"x\":%ld,\"y\":%ld,\"display\":", pt.x, pt.y) ||
        !screen_append_display(&sb, mon) ||
        !sb_appendf(&sb, "}")) {
        free(sb.buf);
        return NULL;
    }
    return sb.buf;
}

char* windows_screen_for_window_json(int32_t window_id) {
    HWND hwnd = (HWND)windows_window_get_webview(window_id);
    if (!hwnd) return NULL;
    HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    ScreenJsonBuf sb = { (char*)malloc(512), 0, 512 };
    if (!sb.buf) return NULL;
    sb.buf[0] = '\0';
    if (!screen_append_display(&sb, mon)) { free(sb.buf); return NULL; }
    return sb.buf;
}
