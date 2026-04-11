// C API for macOS dock features (NSDockTile, NSApplication).
// Badge, icon visibility, bounce.

#ifndef ZAPP_DARWIN_DOCK_H
#define ZAPP_DARWIN_DOCK_H

// Show/hide the app icon in the dock.
void darwin_dock_show_icon(void);
void darwin_dock_hide_icon(void);

// Badge label on the dock icon.
void darwin_dock_set_badge(const char* label);
void darwin_dock_remove_badge(void);
const char* darwin_dock_get_badge(void);

// Bounce the dock icon to request user attention.
// type: 0 = informational (bounces once), 1 = critical (bounces until activated)
void darwin_dock_bounce(int type);

// Set a custom dock icon from a file path.
void darwin_dock_set_icon(const char* image_path);

// Reset dock icon to the app bundle default.
void darwin_dock_reset_icon(void);

#endif
