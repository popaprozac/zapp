// Windows native dialogs — IFileOpenDialog, IFileSaveDialog, MessageBox.
// Returns JSON result strings via static buffers (same pattern as macOS).

#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <shobjidl.h>
#include <shlwapi.h>
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

// --- Message Dialog ---

const char* windows_dialog_message(const char* options_json) {
    char message_buf[1024] = {0};
    char title_buf[256] = {0};
    json_get_string(options_json, "message", message_buf, sizeof(message_buf));
    json_get_string(options_json, "title", title_buf, sizeof(title_buf));

    char kind_buf[32] = {0};
    json_get_string(options_json, "kind", kind_buf, sizeof(kind_buf));

    UINT type = MB_OK;
    if (strcmp(kind_buf, "warning") == 0) type |= MB_ICONWARNING;
    else if (strcmp(kind_buf, "critical") == 0) type |= MB_ICONERROR;
    else type |= MB_ICONINFORMATION;

    // Check for custom buttons — if present, use Yes/No/Cancel style
    // (MessageBox is limited, but good enough for most cases)
    const char* btns = strstr(options_json, "\"buttons\":");
    if (btns) {
        // Count buttons
        int count = 0;
        const char* p = btns;
        while (*p) { if (*p == '"') count++; p++; }
        count = (count - 2) / 2; // rough estimate: "buttons":["a","b"]
        if (count >= 3) type = (type & 0xF0) | MB_YESNOCANCEL;
        else if (count == 2) type = (type & 0xF0) | MB_YESNO;
    }

    wchar_t* wmsg = dlg_utf8_to_wchar(message_buf[0] ? message_buf : "Message");
    wchar_t* wtitle = dlg_utf8_to_wchar(title_buf[0] ? title_buf : "");

    int result = MessageBoxW(NULL, wmsg ? wmsg : L"", wtitle ? wtitle : L"", type);
    if (wmsg) free(wmsg);
    if (wtitle) free(wtitle);

    // Map MessageBox return to 0-based button index
    int button = 0;
    switch (result) {
        case IDOK: case IDYES: button = 0; break;
        case IDNO: button = 1; break;
        case IDCANCEL: button = 2; break;
    }

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
    UINT type = MB_OK;
    if (style == 1) type |= MB_ICONWARNING;
    else if (style == 2) type |= MB_ICONERROR;
    else type |= MB_ICONINFORMATION;

    wchar_t* wmsg = dlg_utf8_to_wchar(message);
    wchar_t* wtitle = dlg_utf8_to_wchar(title);
    int result = MessageBoxW(NULL, wmsg ? wmsg : L"", wtitle ? wtitle : L"", type);
    if (wmsg) free(wmsg);
    if (wtitle) free(wtitle);
    return (result == IDOK) ? 0 : result;
}

int windows_dialog_message_buttons_typed(const char* message, const char* title, int style,
                                         const char* btn1, const char* btn2, const char* btn3) {
    // MessageBox doesn't support custom button labels — use standard mapping
    UINT type = 0;
    if (style == 1) type |= MB_ICONWARNING;
    else if (style == 2) type |= MB_ICONERROR;
    else type |= MB_ICONINFORMATION;

    if (btn3 && btn3[0]) type |= MB_YESNOCANCEL;
    else if (btn2 && btn2[0]) type |= MB_YESNO;
    else type |= MB_OK;

    wchar_t* wmsg = dlg_utf8_to_wchar(message);
    wchar_t* wtitle = dlg_utf8_to_wchar(title);
    int result = MessageBoxW(NULL, wmsg ? wmsg : L"", wtitle ? wtitle : L"", type);
    if (wmsg) free(wmsg);
    if (wtitle) free(wtitle);

    switch (result) {
        case IDOK: case IDYES: return 0;
        case IDNO: return 1;
        case IDCANCEL: return 2;
        default: return 0;
    }
}
