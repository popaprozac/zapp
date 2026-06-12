// Windows shell integration. Mirrors the darwin trio: reveal in
// Explorer, open with the default app, move to the recycle bin.

#ifndef ZAPP_WINDOWS_SHELL_H
#define ZAPP_WINDOWS_SHELL_H

// _WIN32 body guard: zc emits @cfg(windows) imports' #includes into EVERY
// platform's generated TU (@cfg gates functions, not import emission —
// vendor-ledger item). Without this, type definitions here collide with
// the darwin headers in macOS/iOS builds (ZappMenuItem broke the macOS
// build). On Windows _WIN32 is always defined, so this is inert there.
#ifdef _WIN32

void windows_show_item_in_folder(const char* path);
void windows_open_path(const char* path);
void windows_trash_item(const char* path);

#endif // _WIN32
#endif
