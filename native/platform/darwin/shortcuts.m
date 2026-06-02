// Global shortcuts via Carbon RegisterEventHotKey. We pay the small
// cost of a Carbon dependency to get the right semantics — these
// hotkeys fire system-wide, no accessibility prompt, work even when
// the app is hidden. NSEvent.addGlobalMonitorForEvents would also
// work but only delivers events while the app is unfocused, which
// breaks the typical "summon window" hotkey use case.

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import "shortcuts.h"

// Forward declaration — defined in app/app_events.zc, dispatches an
// app event to native callbacks + webviews + workers.
extern int zapp_app_dispatch(int event_id, const char* data);

// We use a regular string event name rather than a numbered AppEvent —
// shortcuts aren't a system-defined lifecycle event, and the runtime
// subscribes via Events.on("app:shortcut-triggered", ...) anyway. This
// avoids a synchronized constant across events.zc / events.ts / bootstrap.
extern void darwin_webview_eval_all(const char* js);
extern void worker_broadcast_eval_js(char* js);

// --- Accelerator → Carbon constants ---

static UInt32 carbon_modifiers_from_token(NSString* token) {
    NSString* lower = [token lowercaseString];
    if ([lower isEqualToString:@"cmd"] || [lower isEqualToString:@"command"] ||
        [lower isEqualToString:@"cmdorctrl"] || [lower isEqualToString:@"meta"]) {
        return cmdKey;
    }
    if ([lower isEqualToString:@"ctrl"] || [lower isEqualToString:@"control"]) return controlKey;
    if ([lower isEqualToString:@"alt"]  || [lower isEqualToString:@"option"])  return optionKey;
    if ([lower isEqualToString:@"shift"]) return shiftKey;
    return 0;
}

// Map a key token (the part after the last "+") to a Carbon virtual
// key code. Returns UINT32_MAX on unknown.
static UInt32 carbon_keycode_for_token(NSString* token) {
    NSString* k = [token lowercaseString];
    if (k.length == 0) return UINT32_MAX;

    // Letters
    if (k.length == 1) {
        unichar c = [k characterAtIndex:0];
        switch (c) {
            case 'a': return kVK_ANSI_A; case 'b': return kVK_ANSI_B;
            case 'c': return kVK_ANSI_C; case 'd': return kVK_ANSI_D;
            case 'e': return kVK_ANSI_E; case 'f': return kVK_ANSI_F;
            case 'g': return kVK_ANSI_G; case 'h': return kVK_ANSI_H;
            case 'i': return kVK_ANSI_I; case 'j': return kVK_ANSI_J;
            case 'k': return kVK_ANSI_K; case 'l': return kVK_ANSI_L;
            case 'm': return kVK_ANSI_M; case 'n': return kVK_ANSI_N;
            case 'o': return kVK_ANSI_O; case 'p': return kVK_ANSI_P;
            case 'q': return kVK_ANSI_Q; case 'r': return kVK_ANSI_R;
            case 's': return kVK_ANSI_S; case 't': return kVK_ANSI_T;
            case 'u': return kVK_ANSI_U; case 'v': return kVK_ANSI_V;
            case 'w': return kVK_ANSI_W; case 'x': return kVK_ANSI_X;
            case 'y': return kVK_ANSI_Y; case 'z': return kVK_ANSI_Z;
            case '0': return kVK_ANSI_0; case '1': return kVK_ANSI_1;
            case '2': return kVK_ANSI_2; case '3': return kVK_ANSI_3;
            case '4': return kVK_ANSI_4; case '5': return kVK_ANSI_5;
            case '6': return kVK_ANSI_6; case '7': return kVK_ANSI_7;
            case '8': return kVK_ANSI_8; case '9': return kVK_ANSI_9;
        }
    }

    // Named keys
    if ([k isEqualToString:@"space"])       return kVK_Space;
    if ([k isEqualToString:@"tab"])         return kVK_Tab;
    if ([k isEqualToString:@"return"]
        || [k isEqualToString:@"enter"])    return kVK_Return;
    if ([k isEqualToString:@"escape"]
        || [k isEqualToString:@"esc"])      return kVK_Escape;
    if ([k isEqualToString:@"delete"]
        || [k isEqualToString:@"backspace"]) return kVK_Delete;
    if ([k isEqualToString:@"forwarddelete"]) return kVK_ForwardDelete;
    if ([k isEqualToString:@"left"])        return kVK_LeftArrow;
    if ([k isEqualToString:@"right"])       return kVK_RightArrow;
    if ([k isEqualToString:@"up"])          return kVK_UpArrow;
    if ([k isEqualToString:@"down"])        return kVK_DownArrow;
    if ([k isEqualToString:@"home"])        return kVK_Home;
    if ([k isEqualToString:@"end"])         return kVK_End;
    if ([k isEqualToString:@"pageup"])      return kVK_PageUp;
    if ([k isEqualToString:@"pagedown"])    return kVK_PageDown;
    if ([k isEqualToString:@"f1"])  return kVK_F1;  if ([k isEqualToString:@"f2"])  return kVK_F2;
    if ([k isEqualToString:@"f3"])  return kVK_F3;  if ([k isEqualToString:@"f4"])  return kVK_F4;
    if ([k isEqualToString:@"f5"])  return kVK_F5;  if ([k isEqualToString:@"f6"])  return kVK_F6;
    if ([k isEqualToString:@"f7"])  return kVK_F7;  if ([k isEqualToString:@"f8"])  return kVK_F8;
    if ([k isEqualToString:@"f9"])  return kVK_F9;  if ([k isEqualToString:@"f10"]) return kVK_F10;
    if ([k isEqualToString:@"f11"]) return kVK_F11; if ([k isEqualToString:@"f12"]) return kVK_F12;

    return UINT32_MAX;
}

// Parse "CmdOrCtrl+Shift+Space" → (modifiers, keycode). Returns false
// on any unknown component.
static bool parse_accelerator(const char* accelerator, UInt32* out_mods, UInt32* out_key) {
    if (!accelerator || !accelerator[0]) return false;
    NSString* s = [NSString stringWithUTF8String:accelerator];
    if (!s) return false;
    NSArray<NSString*>* parts = [s componentsSeparatedByString:@"+"];
    if (parts.count == 0) return false;

    UInt32 mods = 0;
    UInt32 key = UINT32_MAX;
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString* tok = [parts[i] stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
        if (i == parts.count - 1) {
            // Last token is the key.
            key = carbon_keycode_for_token(tok);
        } else {
            UInt32 m = carbon_modifiers_from_token(tok);
            if (m == 0) return false;  // unknown modifier
            mods |= m;
        }
    }
    if (key == UINT32_MAX) return false;
    *out_mods = mods;
    *out_key = key;
    return true;
}

// --- Registration table ---
//
// Map accelerator string ↔ EventHotKeyRef. The Carbon ID we stuff into
// EventHotKeyID is just a sequential counter; the dispatch table in
// `slots[]` resolves the ID back to the accelerator string for the
// JS-side dispatch.

#ifndef ZAPP_MAX_SHORTCUTS
#define ZAPP_MAX_SHORTCUTS 64
#endif

typedef struct {
    BOOL active;
    UInt32 id;                  // Carbon EventHotKeyID
    EventHotKeyRef ref;         // Carbon registration handle
    char accelerator[128];      // owner-supplied string
} ShortcutSlot;

static ShortcutSlot slots[ZAPP_MAX_SHORTCUTS] = {0};
static UInt32 next_id = 1;
static EventHandlerRef carbon_handler = NULL;

static ShortcutSlot* find_slot_by_accelerator(const char* accelerator) {
    if (!accelerator) return NULL;
    for (int i = 0; i < ZAPP_MAX_SHORTCUTS; i++) {
        if (slots[i].active && strcmp(slots[i].accelerator, accelerator) == 0) {
            return &slots[i];
        }
    }
    return NULL;
}

static ShortcutSlot* find_slot_by_id(UInt32 id) {
    for (int i = 0; i < ZAPP_MAX_SHORTCUTS; i++) {
        if (slots[i].active && slots[i].id == id) return &slots[i];
    }
    return NULL;
}

static ShortcutSlot* claim_free_slot(void) {
    for (int i = 0; i < ZAPP_MAX_SHORTCUTS; i++) {
        if (!slots[i].active) return &slots[i];
    }
    return NULL;
}

// --- Carbon event handler ---

static OSStatus shortcut_event_handler(EventHandlerCallRef nextHandler,
                                        EventRef event, void* userData) {
    (void)nextHandler; (void)userData;
    EventHotKeyID hkID;
    OSStatus s = GetEventParameter(event, kEventParamDirectObject,
                                   typeEventHotKeyID, NULL,
                                   sizeof(hkID), NULL, &hkID);
    if (s != noErr) return s;
    ShortcutSlot* slot = find_slot_by_id(hkID.id);
    if (!slot) return noErr;

    // Build {"accelerator":"..."} payload, single-quoted-safe — the
    // JS template wraps the payload in single quotes.
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

    // Dispatch as a regular bridge event so both webviews and workers
    // receive it via Events.on. Same wire shape as deep-link OPEN_URL.
    char js[512];
    snprintf(js, sizeof(js),
        "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&b._onEvent)b._onEvent('app:shortcut-triggered','%s');})();",
        payload);
    darwin_webview_eval_all(js);
    worker_broadcast_eval_js(js);

    return noErr;
}

static void ensure_carbon_handler_installed(void) {
    if (carbon_handler) return;
    EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
    InstallApplicationEventHandler(&shortcut_event_handler, 1, &spec, NULL,
                                   &carbon_handler);
}

// --- Public API ---

bool darwin_shortcut_register(const char* accelerator) {
    if (!accelerator || !accelerator[0]) return false;
    @autoreleasepool {
        if (find_slot_by_accelerator(accelerator)) return false;  // already registered
        UInt32 mods = 0, key = 0;
        if (!parse_accelerator(accelerator, &mods, &key)) return false;

        ShortcutSlot* slot = claim_free_slot();
        if (!slot) return false;

        ensure_carbon_handler_installed();

        EventHotKeyID hkID = { .signature = 'zapp', .id = next_id++ };
        EventHotKeyRef ref = NULL;
        OSStatus status = RegisterEventHotKey(key, mods, hkID,
                                              GetApplicationEventTarget(),
                                              0, &ref);
        if (status != noErr || !ref) return false;

        slot->active = YES;
        slot->id = hkID.id;
        slot->ref = ref;
        strncpy(slot->accelerator, accelerator, sizeof(slot->accelerator) - 1);
        slot->accelerator[sizeof(slot->accelerator) - 1] = '\0';
        return true;
    }
}

bool darwin_shortcut_unregister(const char* accelerator) {
    ShortcutSlot* slot = find_slot_by_accelerator(accelerator);
    if (!slot) return false;
    if (slot->ref) UnregisterEventHotKey(slot->ref);
    slot->active = NO;
    slot->ref = NULL;
    slot->id = 0;
    slot->accelerator[0] = '\0';
    return true;
}

bool darwin_shortcut_is_registered(const char* accelerator) {
    return find_slot_by_accelerator(accelerator) != NULL;
}

void darwin_shortcut_unregister_all(void) {
    for (int i = 0; i < ZAPP_MAX_SHORTCUTS; i++) {
        if (slots[i].active && slots[i].ref) {
            UnregisterEventHotKey(slots[i].ref);
        }
        slots[i].active = NO;
        slots[i].ref = NULL;
        slots[i].id = 0;
        slots[i].accelerator[0] = '\0';
    }
}
