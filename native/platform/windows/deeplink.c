// Windows single-instance + deep links.
//
// macOS gets both declaratively from Info.plist
// (LSMultipleInstancesProhibited + CFBundleURLSchemes, dispatched via
// application:openURLs:). Windows needs runtime machinery:
//
//  - Deep links: register each scheme under HKCU\Software\Classes\
//    <scheme> with a `shell\open\command` pointing at this exe. The OS
//    then launches us with the URL as argv[1] for `myapp://...`.
//  - Single instance: a named mutex gates the primary. A second launch
//    forwards its URL to the primary via WM_COPYDATA and exits, so the
//    deep link surfaces in the already-running app (the common flow)
//    rather than spawning a duplicate.
//
// Both feed the same app:open-url event (id 105, {"url":...} payload)
// macOS uses, dispatched on the UI thread.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h> // CommandLineToArgvW
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern const char* zapp_build_identifier(void);
extern const char* zapp_build_deep_link_schemes_json(void);
extern int zapp_build_single_instance(void);
extern int zapp_app_dispatch(int event_id, const char* data);
extern void windows_webview_eval_all(const char* js);
extern char* zapp_js_lit_dup(const char* utf8);  // native/shared/jslit.c — complete quoted JSON/JS literal
extern HINSTANCE zapp_get_hinstance(void);
extern void windows_window_activate_app(void);

#define ZAPP_EVENT_APP_OPEN_URL 105
#define ZAPP_SI_CLASS L"ZappSingleInstance"

static HANDLE zapp_si_mutex = NULL;
static HWND zapp_si_hwnd = NULL;
static wchar_t zapp_si_title[160] = L""; // = identifier (per-app uniqueness)

// ---------------------------------------------------------------------------
// open-url dispatch (both layers, like darwin's application:openURLs:)
// ---------------------------------------------------------------------------

void windows_dispatch_open_url(const char* url) {
    if (!url || !url[0]) return;

    // Layer 1: native app event (fires without a webview).
    size_t plen = strlen(url) + 32;
    char* payload = (char*) malloc(plen);
    if (payload) {
        snprintf(payload, plen, "{\"url\":\"%s\"}", url);
        // url is a system-supplied scheme URL; embedded quotes are
        // percent-encoded, so the naive wrap is safe here.
        zapp_app_dispatch(ZAPP_EVENT_APP_OPEN_URL, payload);
        free(payload);
    }

    // Layer 2: JS bridge (best-effort — no-ops if no webview is ready,
    // matching darwin_webview_eval_all on a cold deep-link launch).
    // Two-layer encode: url is JSON-encoded into an inline JSON object
    // (urlLit — a complete quoted JSON string), and THAT payload is
    // separately JS-encoded (payloadLit) as the _onEvent argument. The
    // event name is also encoded so nothing here relies on manual quoting.
    char* urlLit = zapp_js_lit_dup(url);                     // "<url>"  (JSON string)
    if (urlLit) {
        size_t json_len = strlen(urlLit) + 16;
        char* url_payload = (char*) malloc(json_len);
        if (url_payload) snprintf(url_payload, json_len, "{\"url\":%s}", urlLit); // {"url":"<url>"} valid JSON
        char* payloadLit = zapp_js_lit_dup(url_payload ? url_payload : "{}");     // "<payload>" (JS literal)
        char* nameLit = zapp_js_lit_dup("app:open-url");
        if (payloadLit && nameLit) {
            const char* tmpl =
                "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
                "if(b&&b._onEvent)b._onEvent(%s,%s);})();";
            int needed = snprintf(NULL, 0, tmpl, nameLit, payloadLit);
            if (needed > 0) {
                char* js = (char*) malloc((size_t) needed + 1);
                if (js) {
                    snprintf(js, (size_t) needed + 1, tmpl, nameLit, payloadLit);
                    windows_webview_eval_all(js);
                    free(js);
                }
            }
        }
        free(url_payload);
        free(payloadLit);
        free(nameLit);
    }
    free(urlLit);
}

// ---------------------------------------------------------------------------
// Scheme registration
// ---------------------------------------------------------------------------

// Pull the next "..." string out of a JSON array scan. Returns the char
// after the closing quote, or NULL when no more strings.
static const char* scheme_next(const char* p, char* out, int out_size) {
    if (!p) return NULL;
    const char* q = strchr(p, '"');
    if (!q) return NULL;
    q++;
    int i = 0;
    while (*q && *q != '"' && i < out_size - 1) out[i++] = *q++;
    out[i] = '\0';
    return (*q == '"') ? q + 1 : NULL;
}

void windows_register_url_schemes(void) {
    const char* json = zapp_build_deep_link_schemes_json();
    if (!json || !json[0]) return;

    wchar_t exe[MAX_PATH];
    if (!GetModuleFileNameW(NULL, exe, MAX_PATH)) return;

    const char* p = json;
    char scheme[64];
    while ((p = scheme_next(p, scheme, sizeof(scheme))) != NULL) {
        if (!scheme[0]) continue;
        wchar_t wscheme[64];
        MultiByteToWideChar(CP_UTF8, 0, scheme, -1, wscheme, 64);

        // HKCU\Software\Classes\<scheme>
        //   (default) = "URL:<scheme> Protocol"
        //   "URL Protocol" = ""
        //   shell\open\command\(default) = "<exe>" "%1"
        wchar_t key_path[160];
        _snwprintf(key_path, 159, L"Software\\Classes\\%s", wscheme);
        key_path[159] = L'\0';
        HKEY key;
        if (RegCreateKeyExW(HKEY_CURRENT_USER, key_path, 0, NULL, 0, KEY_WRITE,
                            NULL, &key, NULL) == ERROR_SUCCESS) {
            wchar_t desc[96];
            _snwprintf(desc, 95, L"URL:%s Protocol", wscheme);
            desc[95] = L'\0';
            RegSetValueExW(key, NULL, 0, REG_SZ, (const BYTE*) desc,
                           (DWORD) ((wcslen(desc) + 1) * sizeof(wchar_t)));
            RegSetValueExW(key, L"URL Protocol", 0, REG_SZ, (const BYTE*) L"",
                           (DWORD) sizeof(wchar_t));
            RegCloseKey(key);
        }

        wchar_t cmd_path[200];
        _snwprintf(cmd_path, 199, L"Software\\Classes\\%s\\shell\\open\\command", wscheme);
        cmd_path[199] = L'\0';
        if (RegCreateKeyExW(HKEY_CURRENT_USER, cmd_path, 0, NULL, 0, KEY_WRITE,
                            NULL, &key, NULL) == ERROR_SUCCESS) {
            wchar_t cmd[MAX_PATH + 16];
            _snwprintf(cmd, MAX_PATH + 15, L"\"%s\" \"%%1\"", exe);
            cmd[MAX_PATH + 15] = L'\0';
            RegSetValueExW(key, NULL, 0, REG_SZ, (const BYTE*) cmd,
                           (DWORD) ((wcslen(cmd) + 1) * sizeof(wchar_t)));
            RegCloseKey(key);
        }
    }
}

// ---------------------------------------------------------------------------
// Command-line URL extraction
// ---------------------------------------------------------------------------

// Returns a malloc'd UTF-8 copy of the first argv after the exe that
// looks like a scheme URL ("...://"), or NULL.
static char* deeplink_url_from_cmdline(void) {
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return NULL;
    char* result = NULL;
    for (int i = 1; i < argc; i++) {
        // A scheme URL contains "://"; skip plain flags/paths.
        if (!wcsstr(argv[i], L"://")) continue;
        int n = WideCharToMultiByte(CP_UTF8, 0, argv[i], -1, NULL, 0, NULL, NULL);
        if (n > 0) {
            result = (char*) malloc((size_t) n);
            if (result) WideCharToMultiByte(CP_UTF8, 0, argv[i], -1, result, n, NULL, NULL);
        }
        break;
    }
    LocalFree(argv);
    return result;
}

void windows_dispatch_deep_link_from_argv(void) {
    char* url = deeplink_url_from_cmdline();
    if (url) {
        windows_dispatch_open_url(url);
        free(url);
    }
}

// ---------------------------------------------------------------------------
// Single instance: mutex + WM_COPYDATA receiver
// ---------------------------------------------------------------------------

static LRESULT CALLBACK si_wndproc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_COPYDATA) {
        COPYDATASTRUCT* cds = (COPYDATASTRUCT*) lParam;
        if (cds && cds->lpData && cds->cbData > 0) {
            // Forwarded command line (UTF-8, NUL-terminated by sender).
            const char* data = (const char*) cds->lpData;
            // Bring the app forward — a deep link should surface.
            windows_window_activate_app();
            if (strstr(data, "://")) {
                windows_dispatch_open_url(data);
            }
        }
        return TRUE;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// Returns 1 when this process is the primary instance (continue
// launching), 0 when it's a secondary instance that forwarded its URL
// and the caller should exit. Always returns 1 when single-instance is
// off.
int windows_single_instance_check(void) {
    if (!zapp_build_single_instance()) return 1;

    const char* ident = zapp_build_identifier();
    if (!ident || !ident[0]) ident = "com.zapp.app";
    MultiByteToWideChar(CP_UTF8, 0, ident, -1, zapp_si_title, 160);

    wchar_t mutex_name[200];
    _snwprintf(mutex_name, 199, L"Local\\zapp-si-%s", zapp_si_title);
    mutex_name[199] = L'\0';

    zapp_si_mutex = CreateMutexW(NULL, TRUE, mutex_name);
    if (zapp_si_mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        // Secondary: hand our command line to the primary, then exit.
        HWND primary = FindWindowExW(HWND_MESSAGE, NULL, ZAPP_SI_CLASS, zapp_si_title);
        if (primary) {
            int n = WideCharToMultiByte(CP_UTF8, 0, GetCommandLineW(), -1, NULL, 0, NULL, NULL);
            char* cmd = (n > 0) ? (char*) malloc((size_t) n) : NULL;
            if (cmd) {
                WideCharToMultiByte(CP_UTF8, 0, GetCommandLineW(), -1, cmd, n, NULL, NULL);
                COPYDATASTRUCT cds;
                cds.dwData = 0;
                cds.cbData = (DWORD) n;
                cds.lpData = cmd;
                SendMessageW(primary, WM_COPYDATA, 0, (LPARAM) &cds);
                free(cmd);
            }
            // Nudge the primary forward even with no URL (relaunch =
            // "show me", matching the macOS reopen behavior).
            SetForegroundWindow(primary);
        }
        return 0;
    }

    // Primary: stand up the receiver window (titled with the identifier
    // so a second instance of THIS app finds it, not some other zapp).
    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = si_wndproc;
    wc.hInstance = zapp_get_hinstance();
    wc.lpszClassName = ZAPP_SI_CLASS;
    RegisterClassExW(&wc);
    zapp_si_hwnd = CreateWindowExW(0, ZAPP_SI_CLASS, zapp_si_title, 0, 0, 0, 0, 0,
                                   HWND_MESSAGE, NULL, zapp_get_hinstance(), NULL);
    return 1;
}
