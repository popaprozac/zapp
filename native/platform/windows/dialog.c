// Windows native dialogs — IFileOpenDialog, IFileSaveDialog, MessageBox.
// Returns JSON result strings via static buffers (same pattern as macOS).

#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <commctrl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "dialog.h"

static char dialog_result[8192];
static char dialog_args_buf[4096];
static char dialog_path_buf[4096];

// --- UTF helpers ---

static wchar_t* dlg_utf8_to_wchar(const char* s) {
    if (!s || !s[0]) return NULL;
    int len = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (len <= 0) return NULL;
    wchar_t* ws = (wchar_t*)malloc(len * sizeof(wchar_t));
    MultiByteToWideChar(CP_UTF8, 0, s, -1, ws, len);
    return ws;
}

static char* dlg_wchar_to_utf8(const wchar_t* ws) {
    if (!ws) return NULL;
    int len = WideCharToMultiByte(CP_UTF8, 0, ws, -1, NULL, 0, NULL, NULL);
    if (len <= 0) return NULL;
    char* s = (char*)malloc(len);
    WideCharToMultiByte(CP_UTF8, 0, ws, -1, s, len, NULL, NULL);
    return s;
}

// --- Minimal JSON helpers (extract string/bool/array fields) ---

// Find a JSON string value: "key":"value" → returns pointer to value, writes into buf
static const char* json_get_string(const char* json, const char* key, char* buf, int buf_size) {
    if (!json || !key) return NULL;
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", key);
    const char* p = strstr(json, pattern);
    if (!p) return NULL;
    p += strlen(pattern);
    int i = 0;
    while (*p && *p != '"' && i < buf_size - 1) {
        if (*p == '\\' && *(p+1)) { buf[i++] = *(p+1); p += 2; }
        else { buf[i++] = *p++; }
    }
    buf[i] = '\0';
    return buf;
}

static int json_get_bool(const char* json, const char* key) {
    if (!json || !key) return 0;
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char* p = strstr(json, pattern);
    if (!p) return 0;
    p += strlen(pattern);
    while (*p == ' ') p++;
    return (*p == 't') ? 1 : 0;
}

// --- Extract "a" from bridge message ---

const char* windows_dialog_extract_args(const char* full_json) {
    if (!full_json || !full_json[0]) return "{}";
    // Find "a":{ and extract to matching }
    const char* p = strstr(full_json, "\"a\":{");
    if (!p) return "{}";
    p += 4; // point to '{'
    int depth = 0;
    int i = 0;
    for (; *p && i < (int)sizeof(dialog_args_buf) - 1; p++, i++) {
        dialog_args_buf[i] = *p;
        if (*p == '{') depth++;
        else if (*p == '}') { depth--; if (depth == 0) { i++; break; } }
        else if (*p == '"') { // skip strings
            dialog_args_buf[i] = *p;
            p++; i++;
            while (*p && i < (int)sizeof(dialog_args_buf) - 1) {
                dialog_args_buf[i] = *p;
                if (*p == '"' && *(p-1) != '\\') break;
                p++; i++;
            }
        }
    }
    dialog_args_buf[i] = '\0';
    return dialog_args_buf;
}

// --- JSON-escape a path for safe embedding ---

static int json_escape_path(char* dst, int dst_size, const char* src) {
    int j = 0;
    for (int i = 0; src[i] && j < dst_size - 2; i++) {
        if (src[i] == '\\') { dst[j++] = '\\'; dst[j++] = '\\'; }
        else if (src[i] == '"') { dst[j++] = '\\'; dst[j++] = '"'; }
        else { dst[j++] = src[i]; }
    }
    dst[j] = '\0';
    return j;
}

// --- Open File Dialog ---

const char* windows_dialog_open_file(const char* options_json) {
    char title_buf[256] = {0};
    json_get_string(options_json, "title", title_buf, sizeof(title_buf));
    int multiple = json_get_bool(options_json, "multiple");
    int directory = json_get_bool(options_json, "directory");

    IFileOpenDialog* pfd = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER,
                                  &IID_IFileOpenDialog, (void**)&pfd);
    if (FAILED(hr) || !pfd) {
        snprintf(dialog_result, sizeof(dialog_result), "{\"cancelled\":true}");
        return dialog_result;
    }

    DWORD options;
    IFileOpenDialog_GetOptions(pfd, &options);
    if (multiple) options |= FOS_ALLOWMULTISELECT;
    if (directory) options |= FOS_PICKFOLDERS;
    IFileOpenDialog_SetOptions(pfd, options);

    if (title_buf[0]) {
        wchar_t* wtitle = dlg_utf8_to_wchar(title_buf);
        if (wtitle) { IFileOpenDialog_SetTitle(pfd, wtitle); free(wtitle); }
    }

    char default_path_buf[1024] = {0};
    if (json_get_string(options_json, "defaultPath", default_path_buf, sizeof(default_path_buf))) {
        wchar_t* wpath = dlg_utf8_to_wchar(default_path_buf);
        if (wpath) {
            IShellItem* folder = NULL;
            SHCreateItemFromParsingName(wpath, NULL, &IID_IShellItem, (void**)&folder);
            if (folder) {
                IFileOpenDialog_SetFolder(pfd, folder);
                IShellItem_Release(folder);
            }
            free(wpath);
        }
    }

    hr = IFileOpenDialog_Show(pfd, NULL);
    if (FAILED(hr)) {
        IFileOpenDialog_Release(pfd);
        snprintf(dialog_result, sizeof(dialog_result), "{\"cancelled\":true}");
        return dialog_result;
    }

    // Collect results
    IShellItemArray* results = NULL;
    IFileOpenDialog_GetResults(pfd, &results);
    IFileOpenDialog_Release(pfd);

    if (!results) {
        snprintf(dialog_result, sizeof(dialog_result), "{\"cancelled\":true}");
        return dialog_result;
    }

    DWORD count = 0;
    IShellItemArray_GetCount(results, &count);

    int pos = 0;
    pos += snprintf(dialog_result + pos, sizeof(dialog_result) - pos, "{\"cancelled\":false,\"paths\":[");

    for (DWORD i = 0; i < count; i++) {
        IShellItem* item = NULL;
        IShellItemArray_GetItemAt(results, i, &item);
        if (!item) continue;

        LPWSTR wpath = NULL;
        IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &wpath);
        IShellItem_Release(item);

        if (wpath) {
            char* path = dlg_wchar_to_utf8(wpath);
            CoTaskMemFree(wpath);
            if (path) {
                if (i > 0) pos += snprintf(dialog_result + pos, sizeof(dialog_result) - pos, ",");
                char escaped[2048];
                json_escape_path(escaped, sizeof(escaped), path);
                pos += snprintf(dialog_result + pos, sizeof(dialog_result) - pos, "\"%s\"", escaped);
                free(path);
            }
        }
    }
    pos += snprintf(dialog_result + pos, sizeof(dialog_result) - pos, "]}");
    IShellItemArray_Release(results);
    return dialog_result;
}

// --- Save File Dialog ---

const char* windows_dialog_save_file(const char* options_json) {
    char title_buf[256] = {0};
    json_get_string(options_json, "title", title_buf, sizeof(title_buf));

    IFileSaveDialog* pfd = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_FileSaveDialog, NULL, CLSCTX_INPROC_SERVER,
                                  &IID_IFileSaveDialog, (void**)&pfd);
    if (FAILED(hr) || !pfd) {
        snprintf(dialog_result, sizeof(dialog_result), "{\"cancelled\":true}");
        return dialog_result;
    }

    if (title_buf[0]) {
        wchar_t* wtitle = dlg_utf8_to_wchar(title_buf);
        if (wtitle) { IFileSaveDialog_SetTitle(pfd, wtitle); free(wtitle); }
    }

    char default_name_buf[256] = {0};
    if (json_get_string(options_json, "defaultName", default_name_buf, sizeof(default_name_buf))) {
        wchar_t* wname = dlg_utf8_to_wchar(default_name_buf);
        if (wname) { IFileSaveDialog_SetFileName(pfd, wname); free(wname); }
    }

    hr = IFileSaveDialog_Show(pfd, NULL);
    if (FAILED(hr)) {
        IFileSaveDialog_Release(pfd);
        snprintf(dialog_result, sizeof(dialog_result), "{\"cancelled\":true}");
        return dialog_result;
    }

    IShellItem* result = NULL;
    IFileSaveDialog_GetResult(pfd, &result);
    IFileSaveDialog_Release(pfd);

    if (!result) {
        snprintf(dialog_result, sizeof(dialog_result), "{\"cancelled\":true}");
        return dialog_result;
    }

    LPWSTR wpath = NULL;
    IShellItem_GetDisplayName(result, SIGDN_FILESYSPATH, &wpath);
    IShellItem_Release(result);

    if (wpath) {
        char* path = dlg_wchar_to_utf8(wpath);
        CoTaskMemFree(wpath);
        if (path) {
            char escaped[2048];
            json_escape_path(escaped, sizeof(escaped), path);
            snprintf(dialog_result, sizeof(dialog_result), "{\"cancelled\":false,\"path\":\"%s\"}", escaped);
            free(path);
            return dialog_result;
        }
    }

    snprintf(dialog_result, sizeof(dialog_result), "{\"cancelled\":true}");
    return dialog_result;
}

// --- Message Dialog (modern TaskDialog) ---
//
// TaskDialogIndirect renders the current Win11 dialog (vs. MessageBox's legacy
// box) AND shows the real custom button labels MessageBox can't. It needs the
// comctl32 v6 activation context to be themed — we have no app manifest, so we
// borrow shell32's embedded manifest (resource 124) as an activation context
// for the duration of the call. Falls back to MessageBoxW if TaskDialog fails.

// comctl6 activation context, created once from a temp manifest file declaring
// the Common-Controls 6.0.0.0 dependency. (A temp file is deterministic; the
// "borrow shell32's manifest resource" trick depends on an undocumented
// resource ID.) Without this, TaskDialog loads comctl32 v5 (unthemed / no
// TaskDialogIndirect export).
static HANDLE g_comctl6_ctx = NULL;
static int    g_comctl6_init = 0;
static void dlg_ensure_comctl6(void) {
    if (g_comctl6_init) return;
    g_comctl6_init = 1;

    static const char* manifest =
        "<?xml version='1.0' encoding='UTF-8' standalone='yes'?>\r\n"
        "<assembly xmlns='urn:schemas-microsoft-com:asm.v1' manifestVersion='1.0'>\r\n"
        "  <dependency><dependentAssembly><assemblyIdentity\r\n"
        "    type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0'\r\n"
        "    processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'/>\r\n"
        "  </dependentAssembly></dependency>\r\n"
        "</assembly>\r\n";

    wchar_t path[MAX_PATH];
    DWORD n = GetTempPathW(MAX_PATH, path);
    if (n == 0 || n > MAX_PATH) return;
    wcsncat_s(path, MAX_PATH, L"zapp_comctl6.manifest", _TRUNCATE);

    HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(f, manifest, (DWORD)strlen(manifest), &written, NULL);
    CloseHandle(f);

    ACTCTXW ac = { sizeof(ac) };
    ac.lpSource = path;
    g_comctl6_ctx = CreateActCtxW(&ac);
}

// Resolve TaskDialogIndirect DYNAMICALLY — never via the import lib. A static
// import binds at EXE-load to comctl32 v5.82 (the unmanifested default), which
// doesn't export TaskDialogIndirect, so the whole app fails to start. Loading
// comctl32 under the active v6 context instead maps v6 (which exports it).
typedef HRESULT (WINAPI *TaskDialogIndirect_t)(const TASKDIALOGCONFIG*, int*, int*, BOOL*);
static TaskDialogIndirect_t g_pTaskDialog = NULL;
static int g_taskdialog_init = 0;
static TaskDialogIndirect_t dlg_resolve_taskdialog(void) {
    if (g_taskdialog_init) return g_pTaskDialog;
    g_taskdialog_init = 1;
    dlg_ensure_comctl6();
    ULONG_PTR cookie = 0;
    BOOL act = (g_comctl6_ctx && g_comctl6_ctx != INVALID_HANDLE_VALUE)
        ? ActivateActCtx(g_comctl6_ctx, &cookie) : FALSE;
    HMODULE comctl = LoadLibraryW(L"comctl32.dll"); // v6 under the active context
    if (comctl) g_pTaskDialog = (TaskDialogIndirect_t)(void*)GetProcAddress(comctl, "TaskDialogIndirect");
    if (act) DeactivateActCtx(0, cookie);
    return g_pTaskDialog; // comctl intentionally kept loaded (process lifetime)
}

// Extract string elements of a JSON "buttons":[...] array into labels[][256].
// Crude (matches this file's other JSON helpers) — labels are simple strings.
static int dlg_parse_buttons(const char* json, char labels[][256], int max) {
    const char* p = strstr(json, "\"buttons\"");
    if (!p) return 0;
    p = strchr(p, '[');
    if (!p) return 0;
    p++;
    int count = 0;
    while (*p && *p != ']' && count < max) {
        const char* q = strchr(p, '"');
        const char* close = strchr(p, ']');
        if (!q || (close && close < q)) break; // no more strings before ]
        q++;
        int i = 0;
        while (*q && *q != '"' && i < 255) {
            if (*q == '\\' && q[1]) q++; // minimal unescape
            labels[count][i++] = *q++;
        }
        labels[count][i] = '\0';
        count++;
        p = (*q == '"') ? q + 1 : q;
    }
    return count;
}

// Show a modern TaskDialog. labels[0..count-1] are button captions (count 0 →
// a single OK). Returns the 0-based index of the clicked button (labels[0] is
// the default, matching macOS NSAlert). X/ESC maps to a "Cancel"-labelled
// button if present, else 0. style: 0 info, 1 warning, 2 critical.
static int dlg_task_dialog(const char* title, const char* message, int style,
                           char labels[][256], int count) {
    wchar_t* wtitle = (title && title[0]) ? dlg_utf8_to_wchar(title) : NULL;
    wchar_t* wmsg   = dlg_utf8_to_wchar(message && message[0] ? message : "");

    if (count > 8) count = 8;
    TASKDIALOG_BUTTON tbuttons[8];
    wchar_t* wlabels[8] = {0};
    int cancel_idx = -1;
    for (int i = 0; i < count; i++) {
        wlabels[i] = dlg_utf8_to_wchar(labels[i]);
        tbuttons[i].nButtonID = 100 + i;
        tbuttons[i].pszButtonText = wlabels[i] ? wlabels[i] : L"";
        if (cancel_idx < 0 && _stricmp(labels[i], "cancel") == 0) cancel_idx = i;
    }

    TASKDIALOGCONFIG cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.cbSize = sizeof(cfg);
    cfg.hwndParent = GetActiveWindow();
    cfg.dwFlags = TDF_POSITION_RELATIVE_TO_WINDOW;
    // Allow X/ESC only when there's a cancel target (or the OK-only case);
    // otherwise the user must choose a button (matches NSAlert with no Cancel).
    if (cancel_idx >= 0 || count == 0) cfg.dwFlags |= TDF_ALLOW_DIALOG_CANCELLATION;
    cfg.pszWindowTitle = wtitle; // NULL → exe name in the caption
    cfg.pszMainInstruction = wmsg ? wmsg : L"";
    cfg.pszMainIcon = (style == 1) ? TD_WARNING_ICON
                    : (style == 2) ? TD_ERROR_ICON
                    : TD_INFORMATION_ICON;
    if (count > 0) {
        cfg.cButtons = (UINT)count;
        cfg.pButtons = tbuttons;
        cfg.nDefaultButton = 100; // labels[0]
    } else {
        cfg.dwCommonButtons = TDCBF_OK_BUTTON;
    }

    int idx = 0, clicked = 0;
    TaskDialogIndirect_t pTaskDialog = dlg_resolve_taskdialog();
    HRESULT hr = E_NOTIMPL;
    if (pTaskDialog) {
        // Activate the v6 context around the call so the dialog is themed.
        ULONG_PTR cookie = 0;
        BOOL activated = (g_comctl6_ctx && g_comctl6_ctx != INVALID_HANDLE_VALUE)
            ? ActivateActCtx(g_comctl6_ctx, &cookie) : FALSE;
        hr = pTaskDialog(&cfg, &clicked, NULL, NULL);
        if (activated) DeactivateActCtx(0, cookie);
    }

    if (SUCCEEDED(hr)) {
        if (clicked >= 100 && clicked < 100 + count) idx = clicked - 100;
        else if (clicked == IDCANCEL) idx = (cancel_idx >= 0) ? cancel_idx : 0;
        else idx = 0; // IDOK (no-buttons case)
    } else {
        // Fallback: classic MessageBox.
        UINT mt = (style == 1) ? MB_ICONWARNING : (style == 2) ? MB_ICONERROR : MB_ICONINFORMATION;
        if (count >= 3) mt |= MB_YESNOCANCEL; else if (count == 2) mt |= MB_YESNO; else mt |= MB_OK;
        int r = MessageBoxW(NULL, wmsg ? wmsg : L"", wtitle ? wtitle : L"", mt);
        switch (r) {
            case IDOK: case IDYES: idx = 0; break;
            case IDNO: idx = 1; break;
            case IDCANCEL: idx = (cancel_idx >= 0) ? cancel_idx : 2; break;
            default: idx = 0;
        }
    }

    for (int i = 0; i < count; i++) free(wlabels[i]);
    free(wtitle);
    free(wmsg);
    return idx;
}

// --- Message Dialog ---

const char* windows_dialog_message(const char* options_json) {
    char message_buf[1024] = {0};
    char title_buf[256] = {0};
    json_get_string(options_json, "message", message_buf, sizeof(message_buf));
    json_get_string(options_json, "title", title_buf, sizeof(title_buf));

    char kind_buf[32] = {0};
    json_get_string(options_json, "kind", kind_buf, sizeof(kind_buf));
    int style = (strcmp(kind_buf, "warning") == 0) ? 1
              : (strcmp(kind_buf, "critical") == 0) ? 2 : 0;

    // Real custom button labels (TaskDialog shows them verbatim).
    char labels[8][256];
    int count = dlg_parse_buttons(options_json, labels, 8);

    int button = dlg_task_dialog(title_buf, message_buf[0] ? message_buf : "Message",
                                 style, labels, count);

    snprintf(dialog_result, sizeof(dialog_result), "{\"button\":%d}", button);
    return dialog_result;
}

// --- Native API (typed params, zero JSON) ---

const char* windows_dialog_open_file_typed(const char* title, bool multiple, bool directory) {
    IFileOpenDialog* pfd = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER,
                                  &IID_IFileOpenDialog, (void**)&pfd);
    if (FAILED(hr) || !pfd) { dialog_path_buf[0] = '\0'; return dialog_path_buf; }

    DWORD options;
    IFileOpenDialog_GetOptions(pfd, &options);
    if (multiple) options |= FOS_ALLOWMULTISELECT;
    if (directory) options |= FOS_PICKFOLDERS;
    IFileOpenDialog_SetOptions(pfd, options);

    if (title && title[0]) {
        wchar_t* wtitle = dlg_utf8_to_wchar(title);
        if (wtitle) { IFileOpenDialog_SetTitle(pfd, wtitle); free(wtitle); }
    }

    hr = IFileOpenDialog_Show(pfd, NULL);
    if (FAILED(hr)) {
        IFileOpenDialog_Release(pfd);
        dialog_path_buf[0] = '\0';
        return dialog_path_buf;
    }

    IShellItem* item = NULL;
    IFileOpenDialog_GetResult(pfd, &item);
    IFileOpenDialog_Release(pfd);

    if (item) {
        LPWSTR wpath = NULL;
        IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &wpath);
        IShellItem_Release(item);
        if (wpath) {
            char* path = dlg_wchar_to_utf8(wpath);
            CoTaskMemFree(wpath);
            if (path) {
                strncpy(dialog_path_buf, path, sizeof(dialog_path_buf) - 1);
                free(path);
                return dialog_path_buf;
            }
        }
    }

    dialog_path_buf[0] = '\0';
    return dialog_path_buf;
}

const char* windows_dialog_save_file_typed(const char* title, const char* default_name) {
    IFileSaveDialog* pfd = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_FileSaveDialog, NULL, CLSCTX_INPROC_SERVER,
                                  &IID_IFileSaveDialog, (void**)&pfd);
    if (FAILED(hr) || !pfd) { dialog_path_buf[0] = '\0'; return dialog_path_buf; }

    if (title && title[0]) {
        wchar_t* wtitle = dlg_utf8_to_wchar(title);
        if (wtitle) { IFileSaveDialog_SetTitle(pfd, wtitle); free(wtitle); }
    }
    if (default_name && default_name[0]) {
        wchar_t* wname = dlg_utf8_to_wchar(default_name);
        if (wname) { IFileSaveDialog_SetFileName(pfd, wname); free(wname); }
    }

    hr = IFileSaveDialog_Show(pfd, NULL);
    if (FAILED(hr)) {
        IFileSaveDialog_Release(pfd);
        dialog_path_buf[0] = '\0';
        return dialog_path_buf;
    }

    IShellItem* result = NULL;
    IFileSaveDialog_GetResult(pfd, &result);
    IFileSaveDialog_Release(pfd);

    if (result) {
        LPWSTR wpath = NULL;
        IShellItem_GetDisplayName(result, SIGDN_FILESYSPATH, &wpath);
        IShellItem_Release(result);
        if (wpath) {
            char* path = dlg_wchar_to_utf8(wpath);
            CoTaskMemFree(wpath);
            if (path) {
                strncpy(dialog_path_buf, path, sizeof(dialog_path_buf) - 1);
                free(path);
                return dialog_path_buf;
            }
        }
    }

    dialog_path_buf[0] = '\0';
    return dialog_path_buf;
}

int windows_dialog_message_typed(const char* message, const char* title, int style) {
    return dlg_task_dialog(title, message, style, NULL, 0);
}

int windows_dialog_message_buttons_typed(const char* message, const char* title, int style,
                                         const char* btn1, const char* btn2, const char* btn3) {
    // Real custom button labels, unlike MessageBox's fixed Yes/No/Cancel.
    char labels[8][256];
    int count = 0;
    if (btn1 && btn1[0]) { snprintf(labels[count++], 256, "%s", btn1); }
    if (btn2 && btn2[0]) { snprintf(labels[count++], 256, "%s", btn2); }
    if (btn3 && btn3[0]) { snprintf(labels[count++], 256, "%s", btn3); }
    return dlg_task_dialog(title, message, style, labels, count);
}
