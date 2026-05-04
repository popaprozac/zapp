// macOS filesystem C API. Callers are Zen-C code in native/fs/fs.zc; all
// paths passed in here are already expanded ($userData, etc.) and validated
// against the allowlist by the Zen-C layer. This file does POSIX/Foundation
// syscalls and nothing else.

#ifndef ZAPP_DARWIN_FS_H
#define ZAPP_DARWIN_FS_H

#include <stdbool.h>
#include <stdint.h>

// Path variable resolution — returns an absolute filesystem path for the
// given symbolic name, or "" if unknown. Caller must copy before calling
// again (returns a reusable static buffer).
//
// Supported names: "userData", "appData", "temp", "home", "downloads",
// "documents", "cache". "userData" and "appData" are aliases.
const char* darwin_fs_path_var(const char* name);

// Reads the whole file as UTF-8 text. Returns a heap-allocated C string
// (caller must free) or NULL on any failure.
char* darwin_fs_read_file(const char* path);

// Reads the whole file as raw bytes. On success, *out_data is a heap
// allocation (caller frees) and *out_len is the byte count. Returns
// false on failure (and does not touch the out params).
bool darwin_fs_read_bytes(const char* path, uint8_t** out_data, int32_t* out_len);

// Write modes
bool darwin_fs_write_file(const char* path, const char* data);
bool darwin_fs_write_bytes(const char* path, const uint8_t* data, int32_t len);
bool darwin_fs_append_file(const char* path, const char* data);

// Metadata / traversal
bool darwin_fs_exists(const char* path);
// On success, fills out params: size (bytes), mtime_ms (Unix epoch ms),
// kind (0=file, 1=directory, 2=symlink, 3=other). Returns false if the
// path doesn't exist.
bool darwin_fs_stat(const char* path, int64_t* out_size, int64_t* out_mtime_ms, int32_t* out_kind);
// Returns a JSON array string of { name, kind } objects, or NULL on
// failure. Heap allocation (caller frees).
char* darwin_fs_read_dir(const char* path);

// Mutations
bool darwin_fs_mkdir(const char* path, bool recursive);
bool darwin_fs_remove(const char* path);           // file or empty dir
bool darwin_fs_rmdir(const char* path, bool recursive);
bool darwin_fs_rename(const char* from, const char* to);
bool darwin_fs_copy(const char* from, const char* to);

#endif
