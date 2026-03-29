// C API for macOS native dialogs.
// Implementation in dialog.m (Objective-C).

#ifndef ZAPP_DARWIN_DIALOG_H
#define ZAPP_DARWIN_DIALOG_H

// Extract "a" (args) from a full bridge message JSON. Returns JSON string.
const char* darwin_dialog_extract_args(const char* full_json);

// All functions take JSON options and return JSON result strings.
// Caller must NOT free the returned string (static buffer).

// Open file dialog. Returns: {"paths":["..."],"cancelled":false}
const char* darwin_dialog_open_file(const char* options_json);

// Save file dialog. Returns: {"path":"...","cancelled":false}
const char* darwin_dialog_save_file(const char* options_json);

// Message dialog. Returns: {"button":0}
const char* darwin_dialog_message(const char* options_json);

// --- Native API (typed params, zero JSON overhead) ---

// Open file dialog. Returns first selected path (static buffer), or "" if cancelled.
const char* darwin_dialog_open_file_typed(const char* title, bool multiple, bool directory);

// Save file dialog. Returns path (static buffer), or "" if cancelled.
const char* darwin_dialog_save_file_typed(const char* title, const char* default_name);

// Message dialog. style: 0=info, 1=warning, 2=critical. Returns button index (0-based).
int darwin_dialog_message_typed(const char* message, const char* title, int style);

// Message dialog with custom buttons. NULL buttons are ignored. Returns button index.
int darwin_dialog_message_buttons_typed(const char* message, const char* title, int style,
                                        const char* btn1, const char* btn2, const char* btn3);

#endif
