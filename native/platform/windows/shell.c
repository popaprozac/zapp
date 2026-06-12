// Windows shell integration — Explorer reveal, default-app open,
// recycle-bin delete. Mirrors darwin/fs.m's darwin_show_item_in_folder /
// darwin_open_path / darwin_trash_item trio.

#define WIN32_LEAN_AND_MEAN
#ifndef COBJMACROS
#define COBJMACROS
#endif
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>   // SHParseDisplayName, SHOpenFolderAndSelectItems
#include <stdlib.h>
#include <string.h>
#include "shell.h"

static wchar_t* shell_utf8_to_utf16(const char* s) {
    if (!s) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t* w = (wchar_t*)malloc((size_t)n * sizeof(wchar_t));
    if (!w) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}

void windows_show_item_in_folder(const char* path) {
    wchar_t* w = shell_utf8_to_utf16(path);
    if (!w) return;
    PIDLIST_ABSOLUTE pidl = NULL;
    if (SUCCEEDED(SHParseDisplayName(w, NULL, &pidl, 0, NULL))) {
        SHOpenFolderAndSelectItems(pidl, 0, NULL, 0);
        CoTaskMemFree(pidl);
    }
    free(w);
}

void windows_open_path(const char* path) {
    wchar_t* w = shell_utf8_to_utf16(path);
    if (!w) return;
    // "open" with the default association; folders open in Explorer.
    ShellExecuteW(NULL, L"open", w, NULL, NULL, SW_SHOWNORMAL);
    free(w);
}

void windows_trash_item(const char* path) {
    wchar_t* w = shell_utf8_to_utf16(path);
    if (!w) return;
    // SHFileOperation wants a double-NUL-terminated list.
    size_t len = wcslen(w);
    wchar_t* list = (wchar_t*)calloc(len + 2, sizeof(wchar_t));
    if (!list) { free(w); return; }
    memcpy(list, w, len * sizeof(wchar_t));
    free(w);

    SHFILEOPSTRUCTW op;
    memset(&op, 0, sizeof(op));
    op.wFunc = FO_DELETE;
    op.pFrom = list;
    // ALLOWUNDO = recycle bin (the whole point — this is "trash", not
    // "delete"); NO_UI suppresses confirmation/progress dialogs.
    op.fFlags = FOF_ALLOWUNDO | FOF_NO_UI;
    SHFileOperationW(&op);
    free(list);
}
