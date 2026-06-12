// Windows clipboard primitives — Win32 clipboard wrappers. Called by
// the Zen-C `Clipboard` namespace, the bridge router (via the darwin_*
// forwarding shims in bare.c until the zapp_* platform layer lands),
// and worker host objects. Contract mirrors darwin/clipboard.h:
// malloc'd returns (caller frees), NULL/false on absence.

#ifndef ZAPP_WINDOWS_CLIPBOARD_H
#define ZAPP_WINDOWS_CLIPBOARD_H

// _WIN32 body guard: zc emits @cfg(windows) imports' #includes into EVERY
// platform's generated TU (@cfg gates functions, not import emission —
// vendor-ledger item). Without this, type definitions here collide with
// the darwin headers in macOS/iOS builds (ZappMenuItem broke the macOS
// build). On Windows _WIN32 is always defined, so this is inert there.
#ifdef _WIN32

#include <stdbool.h>
#include <stdint.h>

// --- Text ---
char* windows_clipboard_read_text(void);
bool  windows_clipboard_write_text(const char* text);

// --- HTML (CF "HTML Format": UTF-8 with offset header; read returns
// the fragment, write wraps the fragment in the required header) ---
char* windows_clipboard_read_html(void);
bool  windows_clipboard_write_html(const char* html);

// --- Files (CF_HDROP) ---
// JSON array of absolute paths, heap-allocated; "[]" when none.
char* windows_clipboard_read_files(void);

// --- Image (PNG via WIC; bridge wire format is base64) ---
char* windows_clipboard_read_image_png_b64(void);
bool  windows_clipboard_write_image_png_b64(const char* b64);

// --- Format presence + clear ---
// fmt: "text" | "html" | "image" | "files".
bool windows_clipboard_has(const char* fmt);
void windows_clipboard_clear(void);

#endif // _WIN32
#endif
