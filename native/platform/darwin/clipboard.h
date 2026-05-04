// macOS clipboard primitives — NSPasteboard wrappers. Called by both the
// Zen-C `Clipboard` namespace (for services / native code) and the JS
// runtime via the bridge router and worker host objects. All functions
// operate on `[NSPasteboard generalPasteboard]`.

#ifndef ZAPP_DARWIN_CLIPBOARD_H
#define ZAPP_DARWIN_CLIPBOARD_H

#include <stdbool.h>
#include <stdint.h>

// --- Text ---
// Read the clipboard's plain-text representation. Returns a malloc'd
// UTF-8 C string (caller frees) or NULL when the pasteboard contains no
// text. An empty-but-present string returns an allocated `""`.
char* darwin_clipboard_read_text(void);

// Replace clipboard contents with `text`. Clears existing types as a
// side effect (matching NSPasteboard semantics — write is a "you own
// the clipboard now" operation).
bool darwin_clipboard_write_text(const char* text);

// --- HTML ---
char* darwin_clipboard_read_html(void);
bool  darwin_clipboard_write_html(const char* html);

// --- Image (PNG) ---
// Read the clipboard image as PNG bytes. On success, *out_data is a
// heap allocation (caller frees) and *out_len is the byte count.
// Returns false if no image is present.
bool darwin_clipboard_read_image_png(uint8_t** out_data, int32_t* out_len);

// Write an image to the clipboard from PNG bytes.
bool darwin_clipboard_write_image_png(const uint8_t* data, int32_t len);

// --- Files ---
// Returns a JSON array of file:// path strings, e.g.
// `["/Users/me/a.txt","/Users/me/b.png"]`. Heap allocation (caller
// frees). Returns "[]" when the clipboard has no file URLs.
char* darwin_clipboard_read_files(void);

// --- Format presence + clear ---
// fmt: "text" | "html" | "image" | "files".
bool darwin_clipboard_has(const char* fmt);
void darwin_clipboard_clear(void);

// --- Bridge wire helpers (PNG ↔ base64) ---
// The bridge is JSON-only; binary blobs cross via base64. These are
// thin wrappers over read/write_image_png that handle the encoding so
// the router doesn't need Foundation imports.
//
// read: returns a malloc'd base64 NUL-terminated string (caller frees),
// or NULL when no image is on the clipboard.
char* darwin_clipboard_read_image_png_b64(void);
// write: decodes base64 and writes; returns true on success.
bool darwin_clipboard_write_image_png_b64(const char* b64);

#endif
