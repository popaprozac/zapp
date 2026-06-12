// Windows shell integration. Mirrors the darwin trio: reveal in
// Explorer, open with the default app, move to the recycle bin.

#ifndef ZAPP_WINDOWS_SHELL_H
#define ZAPP_WINDOWS_SHELL_H

void windows_show_item_in_folder(const char* path);
void windows_open_path(const char* path);
void windows_trash_item(const char* path);

#endif
