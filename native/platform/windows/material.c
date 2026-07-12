// Windows 11 window material + theme-synced chrome (DWM attributes).
//
// Tier-1 native polish, driven by the SAME window options as macOS so a
// cross-platform app gets the right look from one config:
//   - vibrancy: "<material>"  → a system backdrop (Mica / Acrylic). On macOS
//     this mounts an NSVisualEffectView; here it sets DWMWA_SYSTEMBACKDROP_TYPE.
//     The web content must be transparent for it to show through — webview.c
//     sets the controller's DefaultBackgroundColor to transparent in tandem
//     (same opt-in model as macOS vibrancy).
//   - app theme → DWMWA_USE_IMMERSIVE_DARK_MODE so the standard title bar is
//     dark/light to match (re-applied on theme flips via platform.c).
//
// Everything degrades gracefully: the DWM calls just fail (HRESULT ignored)
// on Windows 10 / pre-22H2, leaving a normal opaque window.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>
#include <string.h>
#include <stdio.h>

extern const char* windows_get_theme(void);

// Newer DWM attributes aren't in every MinGW header — define locally.
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
// Builds 18985..19041 used 19 for the dark-mode attribute before it settled
// on 20; try it as a fallback.
#define ZAPP_DWMWA_DARK_MODE_PRE20 19
#ifndef DWMWA_SYSTEMBACKDROP_TYPE
#define DWMWA_SYSTEMBACKDROP_TYPE 38
#endif

// DWM_SYSTEMBACKDROP_TYPE values.
#define ZAPP_DWMSBT_NONE            1
#define ZAPP_DWMSBT_MAINWINDOW      2  // Mica
#define ZAPP_DWMSBT_TRANSIENTWINDOW 3  // Acrylic
#define ZAPP_DWMSBT_TABBEDWINDOW    4  // Mica Alt

// Custom title-bar / border colors (Windows 11 22000+). Value is a COLORREF
// (0x00BBGGRR). Not always in MinGW's dwmapi.h — define locally.
#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR  34
#endif
#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif
#ifndef DWMWA_TEXT_COLOR
#define DWMWA_TEXT_COLOR    36
#endif

static int theme_is_dark(void) {
    const char* t = windows_get_theme();
    return t && strcmp(t, "dark") == 0;
}

// Set the immersive dark/light caption to match the app theme. Safe to call
// repeatedly (window create + every theme flip).
void windows_material_apply_theme(HWND hwnd) {
    if (!hwnd) return;
    BOOL dark = theme_is_dark() ? TRUE : FALSE;
    if (FAILED(DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark)))) {
        DwmSetWindowAttribute(hwnd, ZAPP_DWMWA_DARK_MODE_PRE20, &dark, sizeof(dark));
    }
    // Force a non-client repaint so the caption recolors immediately.
    SetWindowPos(hwnd, NULL, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

// Map a vibrancy material name to a DWM backdrop. Accepts Windows-native
// opt-ins (mica/mica-alt/acrylic/none) plus the macOS NSVisualEffectMaterial
// names: transient/floating surfaces → Acrylic, window backgrounds → Mica.
// Returns 0 when no backdrop should be applied.
static int backdrop_for_vibrancy(const char* v) {
    if (!v || !v[0]) return 0;
    if (strcmp(v, "none") == 0)                                return ZAPP_DWMSBT_NONE;
    if (strcmp(v, "mica") == 0)                                return ZAPP_DWMSBT_MAINWINDOW;
    if (strcmp(v, "mica-alt") == 0 || strcmp(v, "tabbed") == 0) return ZAPP_DWMSBT_TABBEDWINDOW;
    if (strcmp(v, "acrylic") == 0)                             return ZAPP_DWMSBT_TRANSIENTWINDOW;
    if (strstr(v, "popover") || strstr(v, "menu") || strstr(v, "hud") ||
        strstr(v, "sheet")   || strstr(v, "tooltip"))
        return ZAPP_DWMSBT_TRANSIENTWINDOW;
    return ZAPP_DWMSBT_MAINWINDOW;
}

// True when this vibrancy setting wants a see-through web surface (so the
// backdrop shows). webview.c uses this to set a transparent DefaultBackgroundColor.
int windows_material_wants_transparent(const char* vibrancy) {
    return backdrop_for_vibrancy(vibrancy) > ZAPP_DWMSBT_NONE ? 1 : 0;
}

// Parse "#rrggbb" (or "#rrggbbaa", alpha ignored) → COLORREF. Returns 1 if valid;
// other formats (CSS names) aren't resolved here.
static int parse_hex_colorref(const char* s, COLORREF* out) {
    if (!s || s[0] != '#') return 0;
    unsigned r, g, b;
    if (sscanf(s + 1, "%2x%2x%2x", &r, &g, &b) != 3) return 0;
    *out = RGB(r, g, b);
    return 1;
}

// Custom title-bar colors (windows:{customTheme}) → DWMWA_CAPTION/TEXT/BORDER_COLOR.
// Each arg is a "#rrggbb" string or "" (skip that attribute). Win11 22000+; the
// DWM calls no-op (HRESULT ignored) on older builds.
void windows_material_apply_custom_theme(HWND hwnd, const char* caption,
                                         const char* text, const char* border) {
    if (!hwnd) return;
    COLORREF c;
    if (parse_hex_colorref(caption, &c)) DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, &c, sizeof(c));
    if (parse_hex_colorref(text, &c))    DwmSetWindowAttribute(hwnd, DWMWA_TEXT_COLOR, &c, sizeof(c));
    if (parse_hex_colorref(border, &c))  DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, &c, sizeof(c));
}

// Apply theme caption + system backdrop at window create.
void windows_material_apply(HWND hwnd, const char* vibrancy) {
    if (!hwnd) return;
    windows_material_apply_theme(hwnd);
    int sbt = backdrop_for_vibrancy(vibrancy);
    if (sbt > 0) {
        int val = sbt;
        DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, &val, sizeof(val));
        // Full glass: the client must be ALPHA-composited for the backdrop to show
        // through the panes' alpha-0 webviews — windowed WebView2 renders alpha-0
        // as WHITE on a non-glass client ({1,1,1,1} proved this). Full glass on a
        // WS_SYSMENU window makes DWM paint dead caption buttons ("ghost
        // controls"); custom-titlebar windows therefore drop WS_SYSMENU
        // (window.c), which removes DWM's caption chrome entirely.
        MARGINS m = { 32767, 32767, 32767, 32767 };
        DwmExtendFrameIntoClientArea(hwnd, &m);
    }
}
