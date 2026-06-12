// Windows global shortcuts — RegisterHotKey wrappers. Mirrors
// darwin/shortcuts.m: same accelerator grammar, same slot table, same
// app:shortcut-triggered bridge event on fire.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include "shortcuts.h"

extern void windows_webview_eval_all(const char* js);
extern void worker_broadcast_eval_js(char* js);

// --- Accelerator parsing ---

// Modifier token → MOD_* flag; 0 on unknown. "CmdOrCtrl" maps to Ctrl
// (one accelerator string working on both platforms is the point);
// explicit Cmd/Meta/Super pick the Windows key.
static UINT mod_from_token(const char* tok) {
    if (_stricmp(tok, "cmdorctrl") == 0 || _stricmp(tok, "commandorcontrol") == 0) return MOD_CONTROL;
    if (_stricmp(tok, "ctrl") == 0 || _stricmp(tok, "control") == 0) return MOD_CONTROL;
    if (_stricmp(tok, "cmd") == 0 || _stricmp(tok, "command") == 0 ||
        _stricmp(tok, "meta") == 0 || _stricmp(tok, "super") == 0) return MOD_WIN;
    if (_stricmp(tok, "alt") == 0 || _stricmp(tok, "option") == 0) return MOD_ALT;
    if (_stricmp(tok, "shift") == 0) return MOD_SHIFT;
    return 0;
}

// Key token → virtual-key code; 0 on unknown.
static UINT vk_from_token(const char* tok) {
    size_t len = strlen(tok);
    if (len == 0) return 0;
    if (len == 1) {
        char c = (char)toupper((unsigned char)tok[0]);
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return (UINT)c;
        return 0;
    }
    if (_stricmp(tok, "space") == 0) return VK_SPACE;
    if (_stricmp(tok, "tab") == 0) return VK_TAB;
    if (_stricmp(tok, "return") == 0 || _stricmp(tok, "enter") == 0) return VK_RETURN;
    if (_stricmp(tok, "escape") == 0 || _stricmp(tok, "esc") == 0) return VK_ESCAPE;
    // darwin maps delete/backspace to the mac Delete key (= backspace);
    // forwarddelete is the del-below-insert key. Mirror that.
    if (_stricmp(tok, "delete") == 0 || _stricmp(tok, "backspace") == 0) return VK_BACK;
    if (_stricmp(tok, "forwarddelete") == 0) return VK_DELETE;
    if (_stricmp(tok, "left") == 0) return VK_LEFT;
    if (_stricmp(tok, "right") == 0) return VK_RIGHT;
    if (_stricmp(tok, "up") == 0) return VK_UP;
    if (_stricmp(tok, "down") == 0) return VK_DOWN;
    if (_stricmp(tok, "home") == 0) return VK_HOME;
    if (_stricmp(tok, "end") == 0) return VK_END;
    if (_stricmp(tok, "pageup") == 0) return VK_PRIOR;
    if (_stricmp(tok, "pagedown") == 0) return VK_NEXT;
    if ((tok[0] == 'f' || tok[0] == 'F') && len <= 3) {
        int n = atoi(tok + 1);
        if (n >= 1 && n <= 24) return VK_F1 + (UINT)(n - 1);
    }
    return 0;
}

// Parse "CmdOrCtrl+Shift+Space" → (modifiers, vk). False on any
// unknown component.
static bool parse_accelerator(const char* accelerator, UINT* out_mods, UINT* out_vk) {
    if (!accelerator || !accelerator[0]) return false;
    char buf[128];
    strncpy(buf, accelerator, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';

    UINT mods = 0;
    UINT vk = 0;
    char* tok = buf;
    while (tok) {
        char* sep = strchr(tok, '+');
        if (sep) *sep = '\0';
        // Trim surrounding whitespace.
        while (*tok == ' ' || *tok == '\t') tok++;
        char* end = tok + strlen(tok);
        while (end > tok && (end[-1] == ' ' || end[-1] == '\t')) *--end = '\0';

        if (sep) {
            UINT m = mod_from_token(tok);
            if (m == 0) return false;
            mods |= m;
            tok = sep + 1;
        } else {
            vk = vk_from_token(tok);
            tok = NULL;
        }
    }
    if (vk == 0) return false;
    *out_mods = mods;
    *out_vk = vk;
    return true;
}

// --- Registration table (mirrors darwin's ShortcutSlot) ---

#ifndef ZAPP_MAX_SHORTCUTS
#define ZAPP_MAX_SHORTCUTS 64
#endif

typedef struct {
    int active;
    int id; // RegisterHotKey id
    char accelerator[128];
} ShortcutSlot;

static ShortcutSlot slots[ZAPP_MAX_SHORTCUTS] = {0};
static int next_id = 1;

static ShortcutSlot* find_slot_by_accelerator(const char* accelerator) {
    if (!accelerator) return NULL;
    for (int i = 0; i < ZAPP_MAX_SHORTCUTS; i++) {
        if (slots[i].active && strcmp(slots[i].accelerator, accelerator) == 0) {
            return &slots[i];
        }
    }
    return NULL;
}

static ShortcutSlot* find_slot_by_id(int id) {
    for (int i = 0; i < ZAPP_MAX_SHORTCUTS; i++) {
        if (slots[i].active && slots[i].id == id) return &slots[i];
    }
    return NULL;
}

// --- Public API ---

bool windows_shortcut_register(const char* accelerator) {
    if (!accelerator || !accelerator[0]) return false;
    if (find_slot_by_accelerator(accelerator)) return false; // already registered
    UINT mods = 0, vk = 0;
    if (!parse_accelerator(accelerator, &mods, &vk)) return false;

    ShortcutSlot* slot = NULL;
    for (int i = 0; i < ZAPP_MAX_SHORTCUTS; i++) {
        if (!slots[i].active) { slot = &slots[i]; break; }
    }
    if (!slot) return false;

    int id = next_id++;
    // NULL hwnd → WM_HOTKEY lands on this thread's message queue;
    // platform.c's loop routes it to windows_shortcut_handle_wm_hotkey.
    // MOD_NOREPEAT: fire once per press, not on key-repeat (matches
    // Carbon's kEventHotKeyPressed semantics).
    if (!RegisterHotKey(NULL, id, mods | MOD_NOREPEAT, vk)) {
        return false; // usually: another app owns the combination
    }
    slot->active = 1;
    slot->id = id;
    strncpy(slot->accelerator, accelerator, sizeof(slot->accelerator) - 1);
    slot->accelerator[sizeof(slot->accelerator) - 1] = '\0';
    return true;
}

bool windows_shortcut_unregister(const char* accelerator) {
    ShortcutSlot* slot = find_slot_by_accelerator(accelerator);
    if (!slot) return false;
    UnregisterHotKey(NULL, slot->id);
    slot->active = 0;
    return true;
}

bool windows_shortcut_is_registered(const char* accelerator) {
    return find_slot_by_accelerator(accelerator) != NULL;
}

void windows_shortcut_unregister_all(void) {
    for (int i = 0; i < ZAPP_MAX_SHORTCUTS; i++) {
        if (slots[i].active) {
            UnregisterHotKey(NULL, slots[i].id);
            slots[i].active = 0;
        }
    }
}

// --- Fire dispatch ---

void windows_shortcut_handle_wm_hotkey(int hotkey_id) {
    ShortcutSlot* slot = find_slot_by_id(hotkey_id);
    if (!slot) return;

    // Same wire shape as darwin: app:shortcut-triggered with an
    // {"accelerator": "..."} payload, single-quote-escaped for the JS
    // string literal.
    char escaped[256];
    {
        const char* src = slot->accelerator;
        size_t j = 0;
        for (size_t i = 0; src[i] && j + 2 < sizeof(escaped); i++) {
            char c = src[i];
            if (c == '\\' || c == '"' || c == '\'') escaped[j++] = '\\';
            escaped[j++] = c;
        }
        escaped[j] = '\0';
    }
    char payload[320];
    snprintf(payload, sizeof(payload), "{\"accelerator\":\"%s\"}", escaped);

    char js[640];
    snprintf(js, sizeof(js),
        "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&b._onEvent)b._onEvent('app:shortcut-triggered','%s');})();",
        payload);
    windows_webview_eval_all(js);
    worker_broadcast_eval_js(js);
}
