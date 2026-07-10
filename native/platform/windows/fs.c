// fs.c — Windows filesystem service. Provides the darwin_fs_* C-ABI (bound by
// native/nim/fs.nim via the abiPrefix seam as windows_fs_*). Mirrors the darwin
// contract in native/platform/darwin/fs.m:
//   - path_var(name)  -> const char* (static buffer, NOT freed): "userData",
//     "appData", "cache", "documents", "downloads", "home", "temp".
//   - read_file(path) -> malloc'd UTF-8 text (caller frees); NULL on error.
//   - read_dir(path)  -> malloc'd JSON array [{ "name", "kind" }] (kind:
//     0=file 1=dir 2=symlink 3=other); NULL on error.
//   - write/append/exists/mkdir/remove/rmdir/rename/copy -> bool.
// Paths cross the C-ABI as UTF-8; Win32 wide APIs are used internally.

#include <windows.h>
#include <shlobj.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

// --- UTF-8 <-> UTF-16 helpers ------------------------------------------------
static WCHAR* utf8_to_wide(const char* s) {
    if (!s) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    WCHAR* w = (WCHAR*)malloc((size_t)n * sizeof(WCHAR));
    if (!w) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}

// Returns malloc'd UTF-8 (caller frees), or NULL.
static char* wide_to_utf8(const WCHAR* w) {
    if (!w) return NULL;
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char* s = (char*)malloc((size_t)n);
    if (!s) return NULL;
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
    return s;
}

// --- path_var ----------------------------------------------------------------
static char fs_path_var_buf[MAX_PATH * 4];

static bool known_folder(REFKNOWNFOLDERID id, char* out, size_t out_sz) {
    PWSTR wpath = NULL;
    if (SHGetKnownFolderPath(id, 0, NULL, &wpath) != S_OK || !wpath) {
        if (wpath) CoTaskMemFree(wpath);
        return false;
    }
    char* u8 = wide_to_utf8(wpath);
    CoTaskMemFree(wpath);
    if (!u8) return false;
    strncpy(out, u8, out_sz - 1);
    out[out_sz - 1] = '\0';
    free(u8);
    return true;
}

const char* windows_fs_path_var(const char* name) {
    fs_path_var_buf[0] = '\0';
    if (!name || !name[0]) return fs_path_var_buf;

    if (strcmp(name, "home") == 0) {
        known_folder(&FOLDERID_Profile, fs_path_var_buf, sizeof(fs_path_var_buf));
    } else if (strcmp(name, "appData") == 0 || strcmp(name, "userData") == 0) {
        // Windows roaming app data. (userData: app-specific subdir is appended
        // by the app layer, matching how darwin returns App Support/<id>.)
        known_folder(&FOLDERID_RoamingAppData, fs_path_var_buf, sizeof(fs_path_var_buf));
    } else if (strcmp(name, "cache") == 0) {
        known_folder(&FOLDERID_LocalAppData, fs_path_var_buf, sizeof(fs_path_var_buf));
    } else if (strcmp(name, "documents") == 0) {
        known_folder(&FOLDERID_Documents, fs_path_var_buf, sizeof(fs_path_var_buf));
    } else if (strcmp(name, "downloads") == 0) {
        known_folder(&FOLDERID_Downloads, fs_path_var_buf, sizeof(fs_path_var_buf));
    } else if (strcmp(name, "temp") == 0) {
        WCHAR wtmp[MAX_PATH + 1];
        DWORD n = GetTempPathW(MAX_PATH + 1, wtmp);
        if (n > 0) {
            if (n > 1 && (wtmp[n - 1] == L'\\' || wtmp[n - 1] == L'/')) wtmp[n - 1] = L'\0';
            char* u8 = wide_to_utf8(wtmp);
            if (u8) { strncpy(fs_path_var_buf, u8, sizeof(fs_path_var_buf) - 1);
                      fs_path_var_buf[sizeof(fs_path_var_buf) - 1] = '\0'; free(u8); }
        }
    }
    return fs_path_var_buf;
}

// --- read/write --------------------------------------------------------------
char* windows_fs_read_file(const char* path) {
    WCHAR* wp = utf8_to_wide(path);
    if (!wp) return NULL;
    HANDLE h = CreateFileW(wp, GENERIC_READ, FILE_SHARE_READ, NULL,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    free(wp);
    if (h == INVALID_HANDLE_VALUE) return NULL;
    LARGE_INTEGER sz;
    if (!GetFileSizeEx(h, &sz) || sz.QuadPart < 0 || sz.QuadPart > (LONGLONG)(SIZE_MAX - 1)) {
        CloseHandle(h); return NULL;
    }
    size_t len = (size_t)sz.QuadPart;
    char* buf = (char*)malloc(len + 1);
    if (!buf) { CloseHandle(h); return NULL; }
    size_t off = 0;
    while (off < len) {
        DWORD chunk = (len - off > 0x10000000u) ? 0x10000000u : (DWORD)(len - off);
        DWORD got = 0;
        if (!ReadFile(h, buf + off, chunk, &got, NULL) || got == 0) { free(buf); CloseHandle(h); return NULL; }
        off += got;
    }
    buf[len] = '\0';
    CloseHandle(h);
    return buf;
}

static bool write_impl(const char* path, const char* data, bool append) {
    WCHAR* wp = utf8_to_wide(path);
    if (!wp) return false;
    HANDLE h = CreateFileW(wp, append ? FILE_APPEND_DATA : GENERIC_WRITE, FILE_SHARE_READ, NULL,
                           append ? OPEN_ALWAYS : CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    free(wp);
    if (h == INVALID_HANDLE_VALUE) return false;
    if (append) SetFilePointer(h, 0, NULL, FILE_END);
    bool ok = true;
    size_t len = data ? strlen(data) : 0, off = 0;
    while (off < len) {
        DWORD chunk = (len - off > 0x10000000u) ? 0x10000000u : (DWORD)(len - off);
        DWORD put = 0;
        if (!WriteFile(h, data + off, chunk, &put, NULL) || put == 0) { ok = false; break; }
        off += put;
    }
    CloseHandle(h);
    return ok;
}

bool windows_fs_write_file(const char* path, const char* data)  { return write_impl(path, data, false); }
bool windows_fs_append_file(const char* path, const char* data) { return write_impl(path, data, true); }

bool windows_fs_exists(const char* path) {
    WCHAR* wp = utf8_to_wide(path);
    if (!wp) return false;
    DWORD attr = GetFileAttributesW(wp);
    free(wp);
    return attr != INVALID_FILE_ATTRIBUTES;
}

// --- read_dir (JSON) ---------------------------------------------------------
// Append s to *buf (grow as needed). *cap/*len track the buffer.
static bool json_append(char** buf, size_t* len, size_t* cap, const char* s) {
    size_t n = strlen(s);
    if (*len + n + 1 > *cap) {
        size_t nc = (*cap ? *cap : 256);
        while (*len + n + 1 > nc) nc *= 2;
        char* nb = (char*)realloc(*buf, nc);
        if (!nb) return false;
        *buf = nb; *cap = nc;
    }
    memcpy(*buf + *len, s, n);
    *len += n;
    (*buf)[*len] = '\0';
    return true;
}

// Append a JSON-escaped string (no surrounding quotes).
static bool json_append_escaped(char** buf, size_t* len, size_t* cap, const char* s) {
    char esc[8];
    for (; *s; ++s) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { esc[0] = '\\'; esc[1] = (char)c; esc[2] = '\0'; }
        else if (c == '\n') { strcpy(esc, "\\n"); }
        else if (c == '\r') { strcpy(esc, "\\r"); }
        else if (c == '\t') { strcpy(esc, "\\t"); }
        else if (c < 0x20) { sprintf(esc, "\\u%04x", c); }
        else { esc[0] = (char)c; esc[1] = '\0'; }
        if (!json_append(buf, len, cap, esc)) return false;
    }
    return true;
}

char* windows_fs_read_dir(const char* path) {
    if (!path) return NULL;
    // Build "<path>\*" pattern.
    size_t plen = strlen(path);
    char* pat = (char*)malloc(plen + 3);
    if (!pat) return NULL;
    memcpy(pat, path, plen);
    size_t pi = plen;
    if (pi > 0 && path[pi - 1] != '\\' && path[pi - 1] != '/') pat[pi++] = '\\';
    pat[pi++] = '*'; pat[pi] = '\0';

    WCHAR* wpat = utf8_to_wide(pat);
    free(pat);
    if (!wpat) return NULL;

    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(wpat, &fd);
    free(wpat);
    if (h == INVALID_HANDLE_VALUE) return NULL;

    char* out = NULL; size_t len = 0, cap = 0;
    if (!json_append(&out, &len, &cap, "[")) { FindClose(h); return NULL; }
    bool first = true;
    do {
        if (fd.cFileName[0] == L'.' &&
            (fd.cFileName[1] == L'\0' || (fd.cFileName[1] == L'.' && fd.cFileName[2] == L'\0')))
            continue;  // skip . and ..
        char* name = wide_to_utf8(fd.cFileName);
        if (!name) continue;
        int kind = 0;  // file
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) kind = 2;      // symlink
        else if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) kind = 1;     // dir
        char tail[24];
        sprintf(tail, "\",\"kind\":%d}", kind);
        bool ok = json_append(&out, &len, &cap, first ? "{\"name\":\"" : ",{\"name\":\"")
               && json_append_escaped(&out, &len, &cap, name)
               && json_append(&out, &len, &cap, tail);
        free(name);
        if (!ok) { free(out); FindClose(h); return NULL; }
        first = false;
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    if (!json_append(&out, &len, &cap, "]")) { free(out); return NULL; }
    return out;
}

// --- mkdir / remove / rmdir / rename / copy ----------------------------------
static bool mkdir_recursive(WCHAR* wp) {
    if (CreateDirectoryW(wp, NULL)) return true;
    DWORD e = GetLastError();
    if (e == ERROR_ALREADY_EXISTS) return true;
    if (e != ERROR_PATH_NOT_FOUND) return false;
    // Create parent, then retry.
    for (int i = (int)wcslen(wp) - 1; i > 0; --i) {
        if (wp[i] == L'\\' || wp[i] == L'/') {
            WCHAR save = wp[i]; wp[i] = L'\0';
            bool parent = mkdir_recursive(wp);
            wp[i] = save;
            if (!parent) return false;
            break;
        }
    }
    return CreateDirectoryW(wp, NULL) || GetLastError() == ERROR_ALREADY_EXISTS;
}

bool windows_fs_mkdir(const char* path, bool recursive) {
    WCHAR* wp = utf8_to_wide(path);
    if (!wp) return false;
    bool ok = recursive ? mkdir_recursive(wp)
                        : (CreateDirectoryW(wp, NULL) || GetLastError() == ERROR_ALREADY_EXISTS);
    free(wp);
    return ok;
}

bool windows_fs_remove(const char* path) {
    WCHAR* wp = utf8_to_wide(path);
    if (!wp) return false;
    bool ok = DeleteFileW(wp);
    free(wp);
    return ok;
}

static bool rmdir_recursive(const WCHAR* dir) {
    size_t dl = wcslen(dir);
    WCHAR* pat = (WCHAR*)malloc((dl + 3) * sizeof(WCHAR));
    if (!pat) return false;
    wcscpy(pat, dir); wcscat(pat, L"\\*");
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pat, &fd);
    free(pat);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (fd.cFileName[0] == L'.' &&
                (fd.cFileName[1] == L'\0' || (fd.cFileName[1] == L'.' && fd.cFileName[2] == L'\0')))
                continue;
            size_t cl = dl + 1 + wcslen(fd.cFileName) + 1;
            WCHAR* child = (WCHAR*)malloc(cl * sizeof(WCHAR));
            if (!child) continue;
            wcscpy(child, dir); wcscat(child, L"\\"); wcscat(child, fd.cFileName);
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY &&
                !(fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
                rmdir_recursive(child);
            else
                DeleteFileW(child);
            free(child);
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    return RemoveDirectoryW(dir);
}

bool windows_fs_rmdir(const char* path, bool recursive) {
    WCHAR* wp = utf8_to_wide(path);
    if (!wp) return false;
    bool ok = recursive ? rmdir_recursive(wp) : (bool)RemoveDirectoryW(wp);
    free(wp);
    return ok;
}

bool windows_fs_rename(const char* from, const char* to) {
    WCHAR* wf = utf8_to_wide(from); WCHAR* wt = utf8_to_wide(to);
    bool ok = wf && wt && MoveFileExW(wf, wt, MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED);
    free(wf); free(wt);
    return ok;
}

bool windows_fs_copy(const char* from, const char* to) {
    WCHAR* wf = utf8_to_wide(from); WCHAR* wt = utf8_to_wide(to);
    bool ok = wf && wt && CopyFileW(wf, wt, FALSE);
    free(wf); free(wt);
    return ok;
}
