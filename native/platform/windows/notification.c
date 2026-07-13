// Windows notifications — real WinRT toasts (Windows.UI.Notifications)
// from unpackaged C, raw COM ABI (no C++/WinRT, no WinAppSDK).
//
// Identity: AppUserModelID from zapp_build_identifier(), registered
// idempotently under HKCU\Software\Classes\AppUserModelId\<aumid> with
// the app name as DisplayName — the documented unpackaged-app recipe
// (no Start-Menu shortcut needed on Win10/11). MSIX packaging (M4)
// supplies the same identity from the manifest.
//
// userData/arguments trick (adopted from the wails implementation):
// action arguments and the toast's launch attribute carry
// base64(JSON) payloads — sidesteps XML escaping AND argument-grammar
// parsing, and lets arbitrary payloads round-trip like macOS.
//
// Activation: in-process Activated COM handler (works while the app
// runs — matching the macOS delegate path). Cold activation (click
// after quit) needs a LocalServer COM activator; deferred to the
// packaging milestone.
//
// Threading: Activated callbacks arrive on WinRT threadpool threads;
// dispatch marshals through zapp_post_to_ui_thread (webview.c funnel)
// so native App.on handlers and webview evals run on the UI thread.

#define WIN32_LEAN_AND_MEAN
#ifndef COBJMACROS
#define COBJMACROS
#endif
// Emit GUID definitions in this TU — mingw's import libs don't carry
// all the WinRT ABI IIDs (Statics2, ScheduledToastNotificationFactory,
// the parameterized collection interfaces).
#define INITGUID
#include <windows.h>
#include <shobjidl.h>   // SetCurrentProcessExplicitAppUserModelID
#include <roapi.h>
#include <winstring.h>
#include <windows.ui.notifications.h>
#include <windows.data.xml.dom.h>
#include <wincrypt.h>   // CryptBinaryToStringA / CryptStringToBinaryA
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "notification.h"

// Short names for the WinRT ABI mouthfuls.
typedef __x_ABI_CWindows_CUI_CNotifications_CIToastNotificationManagerStatics IToastStatics;
typedef __x_ABI_CWindows_CUI_CNotifications_CIToastNotificationManagerStatics2 IToastStatics2;
typedef __x_ABI_CWindows_CUI_CNotifications_CIToastNotificationFactory IToastFactory;
typedef __x_ABI_CWindows_CUI_CNotifications_CIToastNotifier ZIToastNotifier;
typedef __x_ABI_CWindows_CUI_CNotifications_CIToastNotification ZIToast;
typedef __x_ABI_CWindows_CUI_CNotifications_CIToastNotification2 ZIToast2;
typedef __x_ABI_CWindows_CUI_CNotifications_CIToastNotificationHistory ZIToastHistory;
typedef __x_ABI_CWindows_CUI_CNotifications_CIToastActivatedEventArgs ZIActivatedArgs;
typedef __x_ABI_CWindows_CUI_CNotifications_CIScheduledToastNotificationFactory IScheduledFactory;
typedef __x_ABI_CWindows_CUI_CNotifications_CIScheduledToastNotification ZIScheduled;
typedef __x_ABI_CWindows_CData_CXml_CDom_CIXmlDocument ZIXmlDoc;
typedef __x_ABI_CWindows_CData_CXml_CDom_CIXmlDocumentIO ZIXmlDocIO;
typedef __FITypedEventHandler_2_Windows__CUI__CNotifications__CToastNotification_IInspectable ZIActivatedHandler;

extern const char* zapp_build_identifier(void);
extern const char* zapp_get_app_name(void);
extern int zapp_app_dispatch(int event_id, const char* data);
extern void windows_webview_eval_all(const char* js);
extern bool zapp_post_to_ui_thread(void (*fn)(void* arg), void* arg);
extern char* zapp_js_lit_dup(const char* utf8);  // native/shared/jslit.c — complete quoted JSON/JS literal

#define ZAPP_EVENT_APP_NOTIFICATION_CLICK  102
#define ZAPP_EVENT_APP_NOTIFICATION_ACTION 103

#define ZAPP_NOTIF_GROUP L"zapp"

// Forward decls — show_with_category (defined alongside category
// registration) uses helpers from later sections.
static const char* notif_category_json(const char* cat_id);
static char* notif_build_xml(const char* notif_id, const char* title,
                             const char* subtitle, const char* body,
                             const char* attachment, const char* sound,
                             const char* category_json);
static ZIToast* notif_create_toast(const char* xml_utf8, const char* notif_id);

// ---------------------------------------------------------------------------
// Identity + WinRT bring-up
// ---------------------------------------------------------------------------

static wchar_t zapp_aumid[160] = L"";
static int zapp_notif_ready = 0;

static wchar_t* notif_utf8_to_wide(const char* s) {
    if (!s) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t* w = (wchar_t*) malloc((size_t) n * sizeof(wchar_t));
    if (!w) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}

static HSTRING notif_hstr(const wchar_t* s) {
    HSTRING h = NULL;
    WindowsCreateString(s, (UINT32) wcslen(s), &h);
    return h;
}

static int notif_ensure_identity(void) {
    if (zapp_notif_ready) return 1;

    const char* ident = zapp_build_identifier();
    if (!ident || !ident[0]) ident = "com.zapp.app";
    wchar_t* wident = notif_utf8_to_wide(ident);
    if (!wident) return 0;
    wcsncpy(zapp_aumid, wident, 159);
    zapp_aumid[159] = L'\0';
    free(wident);

    // Idempotent registry identity: DisplayName drives the toast header.
    wchar_t key_path[256];
    _snwprintf(key_path, 255, L"Software\\Classes\\AppUserModelId\\%s", zapp_aumid);
    key_path[255] = L'\0';
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, key_path, 0, NULL, 0, KEY_WRITE,
                        NULL, &key, NULL) == ERROR_SUCCESS) {
        const char* name = zapp_get_app_name();
        wchar_t* wname = notif_utf8_to_wide(name && name[0] ? name : "Zapp");
        if (wname) {
            RegSetValueExW(key, L"DisplayName", 0, REG_SZ, (const BYTE*) wname,
                           (DWORD) ((wcslen(wname) + 1) * sizeof(wchar_t)));
            free(wname);
        }
        RegCloseKey(key);
    }

    SetCurrentProcessExplicitAppUserModelID(zapp_aumid);

    // The main thread is already CoInitializeEx(APARTMENTTHREADED) —
    // RoInitialize(SINGLETHREADED) returns S_FALSE there, which is fine.
    HRESULT hr = RoInitialize(RO_INIT_SINGLETHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return 0;

    zapp_notif_ready = 1;
    return 1;
}

static ZIToastNotifier* notif_notifier(void) {
    if (!notif_ensure_identity()) return NULL;
    static ZIToastNotifier* notifier = NULL;
    if (notifier) return notifier;
    HSTRING cls = notif_hstr(L"Windows.UI.Notifications.ToastNotificationManager");
    IToastStatics* statics = NULL;
    HRESULT hr = RoGetActivationFactory(cls,
        &IID___x_ABI_CWindows_CUI_CNotifications_CIToastNotificationManagerStatics,
        (void**) &statics);
    WindowsDeleteString(cls);
    if (FAILED(hr) || !statics) return NULL;
    HSTRING haumid = notif_hstr(zapp_aumid);
    hr = __x_ABI_CWindows_CUI_CNotifications_CIToastNotificationManagerStatics_CreateToastNotifierWithId(statics, haumid, &notifier);
    WindowsDeleteString(haumid);
    __x_ABI_CWindows_CUI_CNotifications_CIToastNotificationManagerStatics_Release(statics);
    if (FAILED(hr)) { notifier = NULL; }
    return notifier;
}

// ---------------------------------------------------------------------------
// Small helpers — JSON field extraction (flat keys), XML escaping,
// base64, string building.
// ---------------------------------------------------------------------------

static int notif_json_str(const char* json, const char* key, char* buf, int buf_size) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", key);
    const char* p = json ? strstr(json, pattern) : NULL;
    if (!p) return 0;
    p += strlen(pattern);
    int i = 0;
    while (*p && *p != '"' && i < buf_size - 1) {
        if (*p == '\\' && *(p + 1)) { buf[i++] = *(p + 1); p += 2; }
        else { buf[i++] = *p++; }
    }
    buf[i] = '\0';
    return 1;
}

static double notif_json_num(const char* json, const char* key, double fallback) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char* p = json ? strstr(json, pattern) : NULL;
    if (!p) return fallback;
    p += strlen(pattern);
    while (*p == ' ') p++;
    if (*p == 't') return 1; // true
    if (*p == 'f') return 0; // false
    return atof(p);
}

// Heap string builder (same shape as screen.c's).
typedef struct { char* buf; size_t len; size_t cap; } NotifSB;

static int nsb_ensure(NotifSB* sb, size_t extra) {
    if (sb->len + extra < sb->cap) return 1;
    while (sb->len + extra >= sb->cap) sb->cap *= 2;
    char* grown = (char*) realloc(sb->buf, sb->cap);
    if (!grown) return 0;
    sb->buf = grown;
    return 1;
}

static int nsb_append(NotifSB* sb, const char* s) {
    size_t n = strlen(s);
    if (!nsb_ensure(sb, n + 1)) return 0;
    memcpy(sb->buf + sb->len, s, n + 1);
    sb->len += n;
    return 1;
}

// XML-escape into the builder (toast text and attribute values).
static int nsb_append_xml(NotifSB* sb, const char* s) {
    for (const char* p = s; *p; p++) {
        const char* rep = NULL;
        char one[2] = { *p, 0 };
        switch (*p) {
            case '&': rep = "&amp;"; break;
            case '<': rep = "&lt;"; break;
            case '>': rep = "&gt;"; break;
            case '"': rep = "&quot;"; break;
            case '\'': rep = "&apos;"; break;
            default: rep = one; break;
        }
        if (!nsb_append(sb, rep)) return 0;
    }
    return 1;
}

// base64 of a UTF-8 string (caller frees).
static char* notif_b64(const char* s) {
    DWORD out_len = 0;
    if (!CryptBinaryToStringA((const BYTE*) s, (DWORD) strlen(s),
            CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, NULL, &out_len)) return NULL;
    char* out = (char*) malloc(out_len + 1);
    if (!out) return NULL;
    if (!CryptBinaryToStringA((const BYTE*) s, (DWORD) strlen(s),
            CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, out, &out_len)) {
        free(out);
        return NULL;
    }
    out[out_len] = '\0';
    return out;
}

static char* notif_b64_decode(const char* b64) {
    DWORD bin_len = 0;
    if (!CryptStringToBinaryA(b64, 0, CRYPT_STRING_BASE64, NULL, &bin_len, NULL, NULL)) return NULL;
    char* out = (char*) malloc(bin_len + 1);
    if (!out) return NULL;
    if (!CryptStringToBinaryA(b64, 0, CRYPT_STRING_BASE64, (BYTE*) out, &bin_len, NULL, NULL)) {
        free(out);
        return NULL;
    }
    out[bin_len] = '\0';
    return out;
}

// ---------------------------------------------------------------------------
// Category store — raw args JSON per category id, mirrored from
// darwin's register-time dictionary. Categories are re-registered by
// app code every launch (no persistence needed).
// ---------------------------------------------------------------------------

#define ZAPP_MAX_NOTIF_CATEGORIES 16

typedef struct {
    int active;
    char id[64];
    char* args_json;
} NotifCategory;

static NotifCategory zapp_notif_categories[ZAPP_MAX_NOTIF_CATEGORIES] = {0};

void windows_notification_register_category(const char* cat_id, const char* args_json) {
    if (!cat_id || !cat_id[0]) return;
    NotifCategory* slot = NULL;
    for (int i = 0; i < ZAPP_MAX_NOTIF_CATEGORIES; i++) {
        if (zapp_notif_categories[i].active &&
            strcmp(zapp_notif_categories[i].id, cat_id) == 0) {
            slot = &zapp_notif_categories[i];
            break;
        }
    }
    if (!slot) {
        for (int i = 0; i < ZAPP_MAX_NOTIF_CATEGORIES; i++) {
            if (!zapp_notif_categories[i].active) { slot = &zapp_notif_categories[i]; break; }
        }
    }
    if (!slot) return;
    free(slot->args_json);
    slot->args_json = args_json ? _strdup(args_json) : NULL;
    strncpy(slot->id, cat_id, sizeof(slot->id) - 1);
    slot->id[sizeof(slot->id) - 1] = '\0';
    slot->active = 1;
}

void windows_notification_remove_category(const char* cat_id) {
    if (!cat_id) return;
    for (int i = 0; i < ZAPP_MAX_NOTIF_CATEGORIES; i++) {
        if (zapp_notif_categories[i].active &&
            strcmp(zapp_notif_categories[i].id, cat_id) == 0) {
            free(zapp_notif_categories[i].args_json);
            zapp_notif_categories[i].args_json = NULL;
            zapp_notif_categories[i].active = 0;
        }
    }
}

// Typed registration (native Zen-C path) — serialize the struct fields
// into the same args JSON the XML builder + JS-bridge path consume, so
// both registration routes share one store and one code path.
// (ZappWinNotifAction comes from notification.h.)

static int nsb_append_json_str(NotifSB* sb, const char* s) {
    // JSON-escape (backslash + quote; control chars are rare in labels).
    if (!nsb_append(sb, "\"")) return 0;
    for (const char* p = s ? s : ""; *p; p++) {
        char one[3];
        if (*p == '\\' || *p == '"') { one[0] = '\\'; one[1] = *p; one[2] = 0; }
        else { one[0] = *p; one[1] = 0; }
        if (!nsb_append(sb, one)) return 0;
    }
    return nsb_append(sb, "\"");
}

void windows_notification_register_category_typed(
        const char* cat_id, ZappWinNotifAction* actions, int action_count,
        int has_reply, const char* reply_placeholder, const char* reply_button) {
    if (!cat_id) return;
    NotifSB sb = { (char*) malloc(256), 0, 256 };
    if (!sb.buf) return;
    sb.buf[0] = '\0';
    int ok = nsb_append(&sb, "{\"hasReplyField\":");
    ok = ok && nsb_append(&sb, has_reply ? "true" : "false");
    if (ok && reply_placeholder) {
        ok = nsb_append(&sb, ",\"replyPlaceholder\":") && nsb_append_json_str(&sb, reply_placeholder);
    }
    if (ok && reply_button) {
        ok = nsb_append(&sb, ",\"replyButtonTitle\":") && nsb_append_json_str(&sb, reply_button);
    }
    if (ok) ok = nsb_append(&sb, ",\"actions\":[");
    for (int i = 0; ok && i < action_count; i++) {
        if (i > 0) ok = nsb_append(&sb, ",");
        ok = ok && nsb_append(&sb, "{\"id\":") && nsb_append_json_str(&sb, actions[i].id) &&
             nsb_append(&sb, ",\"title\":") && nsb_append_json_str(&sb, actions[i].title) &&
             nsb_append(&sb, "}");
    }
    if (ok) ok = nsb_append(&sb, "]}");
    if (ok) windows_notification_register_category(cat_id, sb.buf);
    free(sb.buf);
}

void windows_notification_show_with_category(const char* title, const char* body,
                                             const char* category_id) {
    ZIToastNotifier* notifier = notif_notifier();
    if (!notifier) return;
    char notif_id[64];
    snprintf(notif_id, sizeof(notif_id), "notif-%lu-%lu",
             (unsigned long) GetTickCount64(), (unsigned long) rand());
    char* xml = notif_build_xml(notif_id, title ? title : "", "", body ? body : "",
                                NULL, NULL, notif_category_json(category_id));
    if (!xml) return;
    ZIToast* toast = notif_create_toast(xml, notif_id);
    free(xml);
    if (toast) {
        __x_ABI_CWindows_CUI_CNotifications_CIToastNotifier_Show(notifier, toast);
        __x_ABI_CWindows_CUI_CNotifications_CIToastNotification_Release(toast);
    }
}

static const char* notif_category_json(const char* cat_id) {
    if (!cat_id || !cat_id[0]) return NULL;
    for (int i = 0; i < ZAPP_MAX_NOTIF_CATEGORIES; i++) {
        if (zapp_notif_categories[i].active &&
            strcmp(zapp_notif_categories[i].id, cat_id) == 0) {
            return zapp_notif_categories[i].args_json;
        }
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// Toast XML builder
// ---------------------------------------------------------------------------

// Append one <action> with base64(JSON) arguments (the wails trick).
static int notif_append_action(NotifSB* sb, const char* notif_id,
                               const char* action_id, const char* title,
                               const char* hint_input) {
    char payload[512];
    snprintf(payload, sizeof(payload),
             "{\"kind\":\"action\",\"id\":\"%s\",\"action\":\"%s\"}",
             notif_id, action_id);
    char* b64 = notif_b64(payload);
    if (!b64) return 0;
    int ok = nsb_append(sb, "<action content=\"") &&
             nsb_append_xml(sb, title) &&
             nsb_append(sb, "\" arguments=\"") &&
             nsb_append(sb, b64) && // base64 is XML-safe by construction
             nsb_append(sb, "\" activationType=\"foreground\"");
    free(b64);
    if (ok && hint_input) {
        ok = nsb_append(sb, " hint-inputId=\"") &&
             nsb_append_xml(sb, hint_input) &&
             nsb_append(sb, "\"");
    }
    return ok && nsb_append(sb, "/>");
}

// Build the full toast XML from flat options + optional category.
// Caller frees. NULL on allocation failure.
static char* notif_build_xml(const char* notif_id, const char* title,
                             const char* subtitle, const char* body,
                             const char* attachment, const char* sound,
                             const char* category_json) {
    NotifSB sb = { (char*) malloc(1024), 0, 1024 };
    if (!sb.buf) return NULL;
    sb.buf[0] = '\0';

    // launch carries the click payload (base64 JSON like actions).
    char click_payload[256];
    snprintf(click_payload, sizeof(click_payload), "{\"kind\":\"click\",\"id\":\"%s\"}", notif_id);
    char* launch_b64 = notif_b64(click_payload);
    if (!launch_b64) { free(sb.buf); return NULL; }

    int ok = nsb_append(&sb, "<toast activationType=\"foreground\" launch=\"") &&
             nsb_append(&sb, launch_b64) &&
             nsb_append(&sb, "\"><visual><binding template=\"ToastGeneric\">");
    free(launch_b64);
    if (!ok) { free(sb.buf); return NULL; }

    if (title && title[0]) {
        ok = nsb_append(&sb, "<text>") && nsb_append_xml(&sb, title) && nsb_append(&sb, "</text>");
    }
    if (ok && subtitle && subtitle[0]) {
        ok = nsb_append(&sb, "<text>") && nsb_append_xml(&sb, subtitle) && nsb_append(&sb, "</text>");
    }
    if (ok && body && body[0]) {
        ok = nsb_append(&sb, "<text>") && nsb_append_xml(&sb, body) && nsb_append(&sb, "</text>");
    }
    if (ok && attachment && attachment[0]) {
        // Hero image from a local file path — file URIs want forward
        // slashes.
        ok = nsb_append(&sb, "<image placement=\"hero\" src=\"file:///");
        if (ok) {
            char* esc = _strdup(attachment);
            if (esc) {
                for (char* p = esc; *p; p++) if (*p == '\\') *p = '/';
                ok = nsb_append_xml(&sb, esc);
                free(esc);
            } else ok = 0;
        }
        if (ok) ok = nsb_append(&sb, "\"/>");
    }
    if (ok) ok = nsb_append(&sb, "</binding></visual>");

    // Category → actions + optional reply input.
    if (ok && category_json) {
        int has_reply = notif_json_num(category_json, "hasReplyField", 0) != 0;
        char placeholder[128] = "";
        char reply_button[64] = "Send";
        notif_json_str(category_json, "replyPlaceholder", placeholder, sizeof(placeholder));
        notif_json_str(category_json, "replyButtonTitle", reply_button, sizeof(reply_button));

        ok = nsb_append(&sb, "<actions>");
        if (ok && has_reply) {
            ok = nsb_append(&sb, "<input id=\"reply\" type=\"text\" placeHolderContent=\"") &&
                 nsb_append_xml(&sb, placeholder) &&
                 nsb_append(&sb, "\"/>");
            if (ok) ok = notif_append_action(&sb, notif_id, "__reply", reply_button, "reply");
        }
        // Walk the actions array: minimal scan for {"id":"...","title":"..."}
        // pairs inside "actions":[...]. The objects are flat.
        const char* arr = strstr(category_json, "\"actions\":");
        if (ok && arr) {
            arr = strchr(arr, '[');
            const char* end = arr ? strchr(arr, ']') : NULL;
            const char* p = arr;
            while (ok && p && end && p < end) {
                const char* obj = strchr(p, '{');
                if (!obj || obj > end) break;
                const char* obj_end = strchr(obj, '}');
                if (!obj_end || obj_end > end) break;
                char one[256];
                size_t n = (size_t) (obj_end - obj + 1);
                if (n >= sizeof(one)) n = sizeof(one) - 1;
                memcpy(one, obj, n);
                one[n] = '\0';
                char aid[64] = "", atitle[128] = "";
                if (notif_json_str(one, "id", aid, sizeof(aid)) &&
                    notif_json_str(one, "title", atitle, sizeof(atitle))) {
                    ok = notif_append_action(&sb, notif_id, aid, atitle, NULL);
                }
                p = obj_end + 1;
            }
        }
        if (ok) ok = nsb_append(&sb, "</actions>");
    }

    if (ok && sound && strcmp(sound, "none") == 0) {
        ok = nsb_append(&sb, "<audio silent=\"true\"/>");
    }
    if (ok) ok = nsb_append(&sb, "</toast>");
    if (!ok) { free(sb.buf); return NULL; }
    return sb.buf;
}

// ---------------------------------------------------------------------------
// Activation — in-process Activated handler. Decodes the base64(JSON)
// arguments, mirrors darwin's two-layer dispatch (app event + bridge
// event), marshaled to the UI thread.
// ---------------------------------------------------------------------------

static int zapp_notif_bridge_ready = 0;
#define ZAPP_NOTIF_PENDING_MAX 16
static char* zapp_notif_pending_js[ZAPP_NOTIF_PENDING_MAX] = {0};
static int zapp_notif_pending_count = 0;

typedef struct {
    int app_event_id;
    char* payload;     // {"id":...} / {"id","action","userText"}
    char* event_name;  // __notif:click / __notif:action
} NotifDispatchTask;

static void notif_dispatch_on_ui(void* arg) {
    NotifDispatchTask* t = (NotifDispatchTask*) arg;
    if (!t) return;

    // Layer 1: native Zen-C callbacks.
    zapp_app_dispatch(t->app_event_id, t->payload);

    // Layer 2: JS bridge event (buffered until a bridge subscribes —
    // mirrors darwin's pending list).
    char* esc_name = zapp_js_lit_dup(t->event_name);
    char* esc_payload = zapp_js_lit_dup(t->payload);
    if (esc_name && esc_payload) {
        const char* tmpl =
            "(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&b._onEvent)b._onEvent(%s,%s);})();";
        int needed = snprintf(NULL, 0, tmpl, esc_name, esc_payload);
        if (needed > 0) {
            char* js = (char*) malloc((size_t) needed + 1);
            if (js) {
                snprintf(js, (size_t) needed + 1, tmpl, esc_name, esc_payload);
                if (zapp_notif_bridge_ready) {
                    windows_webview_eval_all(js);
                    free(js);
                } else if (zapp_notif_pending_count < ZAPP_NOTIF_PENDING_MAX) {
                    zapp_notif_pending_js[zapp_notif_pending_count++] = js;
                } else {
                    free(js);
                }
            }
        }
    }
    free(esc_name);
    free(esc_payload);
    free(t->payload);
    free(t->event_name);
    free(t);
}

void windows_notification_set_bridge_ready(void) {
    zapp_notif_bridge_ready = 1;
    for (int i = 0; i < zapp_notif_pending_count; i++) {
        if (zapp_notif_pending_js[i]) {
            windows_webview_eval_all(zapp_notif_pending_js[i]);
            free(zapp_notif_pending_js[i]);
            zapp_notif_pending_js[i] = NULL;
        }
    }
    zapp_notif_pending_count = 0;
}

// Read the reply text from IToastActivatedEventArgs2.UserInput
// (ValueSet → IMap<HSTRING, IInspectable> → IPropertyValue string).
static char* notif_read_user_text(IInspectable* args_insp) {
    __x_ABI_CWindows_CUI_CNotifications_CIToastActivatedEventArgs2* args2 = NULL;
    if (FAILED(IInspectable_QueryInterface(args_insp,
            &IID___x_ABI_CWindows_CUI_CNotifications_CIToastActivatedEventArgs2,
            (void**) &args2)) || !args2) return NULL;

    __x_ABI_CWindows_CFoundation_CCollections_CIPropertySet* set = NULL;
    HRESULT hr = __x_ABI_CWindows_CUI_CNotifications_CIToastActivatedEventArgs2_get_UserInput(args2, &set);
    __x_ABI_CWindows_CUI_CNotifications_CIToastActivatedEventArgs2_Release(args2);
    if (FAILED(hr) || !set) return NULL;

    __FIMap_2_HSTRING_IInspectable* map = NULL;
    hr = __x_ABI_CWindows_CFoundation_CCollections_CIPropertySet_QueryInterface(
        set, &IID___FIMap_2_HSTRING_IInspectable, (void**) &map);
    __x_ABI_CWindows_CFoundation_CCollections_CIPropertySet_Release(set);
    if (FAILED(hr) || !map) return NULL;

    char* result = NULL;
    HSTRING key = notif_hstr(L"reply");
    IInspectable* value = NULL;
    if (SUCCEEDED(__FIMap_2_HSTRING_IInspectable_Lookup(map, key, &value)) && value) {
        __x_ABI_CWindows_CFoundation_CIPropertyValue* pv = NULL;
        if (SUCCEEDED(IInspectable_QueryInterface(value,
                &IID___x_ABI_CWindows_CFoundation_CIPropertyValue, (void**) &pv)) && pv) {
            HSTRING text = NULL;
            if (SUCCEEDED(__x_ABI_CWindows_CFoundation_CIPropertyValue_GetString(pv, &text)) && text) {
                UINT32 len = 0;
                const wchar_t* w = WindowsGetStringRawBuffer(text, &len);
                if (w) {
                    int n = WideCharToMultiByte(CP_UTF8, 0, w, (int) len, NULL, 0, NULL, NULL);
                    if (n > 0) {
                        result = (char*) malloc((size_t) n + 1);
                        if (result) {
                            WideCharToMultiByte(CP_UTF8, 0, w, (int) len, result, n, NULL, NULL);
                            result[n] = '\0';
                        }
                    }
                }
                WindowsDeleteString(text);
            }
            __x_ABI_CWindows_CFoundation_CIPropertyValue_Release(pv);
        }
        IInspectable_Release(value);
    }
    WindowsDeleteString(key);
    __FIMap_2_HSTRING_IInspectable_Release(map);
    return result;
}

// --- Activated handler COM object ---

typedef struct {
    ZIActivatedHandler iface;
    LONG ref;
} NotifActivatedHandler;

static HRESULT STDMETHODCALLTYPE NotifAct_QueryInterface(ZIActivatedHandler* This, REFIID riid, void** ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IAgileObject) ||
        IsEqualIID(riid, &IID___FITypedEventHandler_2_Windows__CUI__CNotifications__CToastNotification_IInspectable)) {
        *ppv = This;
        This->lpVtbl->AddRef(This);
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE NotifAct_AddRef(ZIActivatedHandler* This) {
    return (ULONG) InterlockedIncrement(&((NotifActivatedHandler*) This)->ref);
}
static ULONG STDMETHODCALLTYPE NotifAct_Release(ZIActivatedHandler* This) {
    NotifActivatedHandler* self = (NotifActivatedHandler*) This;
    LONG r = InterlockedDecrement(&self->ref);
    if (r == 0) free(self);
    return (ULONG) r;
}

static HRESULT STDMETHODCALLTYPE NotifAct_Invoke(ZIActivatedHandler* This,
        __x_ABI_CWindows_CUI_CNotifications_CIToastNotification* sender,
        IInspectable* args) {
    (void) This; (void) sender;

    // Decode the base64(JSON) arguments.
    char* decoded = NULL;
    ZIActivatedArgs* act = NULL;
    if (args && SUCCEEDED(IInspectable_QueryInterface(args,
            &IID___x_ABI_CWindows_CUI_CNotifications_CIToastActivatedEventArgs,
            (void**) &act)) && act) {
        HSTRING harg = NULL;
        if (SUCCEEDED(__x_ABI_CWindows_CUI_CNotifications_CIToastActivatedEventArgs_get_Arguments(act, &harg)) && harg) {
            UINT32 len = 0;
            const wchar_t* w = WindowsGetStringRawBuffer(harg, &len);
            if (w && len > 0) {
                int n = WideCharToMultiByte(CP_UTF8, 0, w, (int) len, NULL, 0, NULL, NULL);
                char* b64 = (n > 0) ? (char*) malloc((size_t) n + 1) : NULL;
                if (b64) {
                    WideCharToMultiByte(CP_UTF8, 0, w, (int) len, b64, n, NULL, NULL);
                    b64[n] = '\0';
                    decoded = notif_b64_decode(b64);
                    free(b64);
                }
            }
            WindowsDeleteString(harg);
        }
        __x_ABI_CWindows_CUI_CNotifications_CIToastActivatedEventArgs_Release(act);
    }

    char notif_id[128] = "";
    char action_id[64] = "";
    if (decoded) {
        notif_json_str(decoded, "id", notif_id, sizeof(notif_id));
        notif_json_str(decoded, "action", action_id, sizeof(action_id));
        free(decoded);
    }

    NotifDispatchTask* task = (NotifDispatchTask*) calloc(1, sizeof(NotifDispatchTask));
    if (!task) return S_OK;

    if (action_id[0]) {
        char* user_text = notif_read_user_text(args);
        // esc_text is a COMPLETE, already-quoted JSON string value (e.g.
        // "hello \"world\"") — embed it directly as the userText VALUE, no
        // manual "\"...\"" wrapping (that used to let a raw `"` in the
        // OS-supplied reply text corrupt the JSON outright, since the old
        // libc escaper here never escaped `"`). Only encode when there's
        // actual text, matching the prior no-userText-field behavior for
        // NULL/empty replies.
        char* esc_text = (user_text && user_text[0]) ? zapp_js_lit_dup(user_text) : NULL;
        free(user_text);
        size_t cap = 256 + (esc_text ? strlen(esc_text) : 0);
        task->payload = (char*) malloc(cap);
        if (task->payload) {
            if (esc_text) {
                snprintf(task->payload, cap, "{\"id\":\"%s\",\"action\":\"%s\",\"userText\":%s}",
                         notif_id, action_id, esc_text);
            } else {
                snprintf(task->payload, cap, "{\"id\":\"%s\",\"action\":\"%s\"}", notif_id, action_id);
            }
        }
        free(esc_text);
        task->event_name = _strdup("__notif:action");
        task->app_event_id = ZAPP_EVENT_APP_NOTIFICATION_ACTION;
    } else {
        task->payload = (char*) malloc(192);
        if (task->payload) snprintf(task->payload, 192, "{\"id\":\"%s\"}", notif_id);
        task->event_name = _strdup("__notif:click");
        task->app_event_id = ZAPP_EVENT_APP_NOTIFICATION_CLICK;
    }

    if (!task->payload || !task->event_name ||
        !zapp_post_to_ui_thread(notif_dispatch_on_ui, task)) {
        free(task->payload);
        free(task->event_name);
        free(task);
    }
    return S_OK;
}

static __FITypedEventHandler_2_Windows__CUI__CNotifications__CToastNotification_IInspectableVtbl NotifAct_Vtbl = {
    NotifAct_QueryInterface, NotifAct_AddRef, NotifAct_Release, NotifAct_Invoke,
};

static ZIActivatedHandler* notif_make_activated_handler(void) {
    NotifActivatedHandler* h = (NotifActivatedHandler*) calloc(1, sizeof(NotifActivatedHandler));
    if (!h) return NULL;
    h->iface.lpVtbl = &NotifAct_Vtbl;
    h->ref = 1;
    return &h->iface;
}

// ---------------------------------------------------------------------------
// Show / schedule core
// ---------------------------------------------------------------------------

// Parse XML into a fresh XmlDocument (caller releases). NULL on failure.
static ZIXmlDoc* notif_parse_xml(const char* xml_utf8) {
    wchar_t* wxml = notif_utf8_to_wide(xml_utf8);
    if (!wxml) return NULL;
    ZIXmlDoc* doc = NULL;
    IInspectable* insp = NULL;
    HSTRING xml_cls = notif_hstr(L"Windows.Data.Xml.Dom.XmlDocument");
    HRESULT hr = RoActivateInstance(xml_cls, &insp);
    WindowsDeleteString(xml_cls);
    if (SUCCEEDED(hr) && insp) {
        ZIXmlDocIO* io = NULL;
        if (SUCCEEDED(IInspectable_QueryInterface(insp,
                &IID___x_ABI_CWindows_CData_CXml_CDom_CIXmlDocumentIO, (void**) &io)) && io) {
            HSTRING hxml = NULL;
            WindowsCreateString(wxml, (UINT32) wcslen(wxml), &hxml);
            if (SUCCEEDED(__x_ABI_CWindows_CData_CXml_CDom_CIXmlDocumentIO_LoadXml(io, hxml))) {
                IInspectable_QueryInterface(insp,
                    &IID___x_ABI_CWindows_CData_CXml_CDom_CIXmlDocument, (void**) &doc);
            }
            if (hxml) WindowsDeleteString(hxml);
            __x_ABI_CWindows_CData_CXml_CDom_CIXmlDocumentIO_Release(io);
        }
        IInspectable_Release(insp);
    }
    free(wxml);
    return doc;
}

// Build the ZIToast from XML; sets tag/group and hooks activation.
static ZIToast* notif_create_toast(const char* xml_utf8, const char* notif_id) {
    ZIXmlDoc* doc = notif_parse_xml(xml_utf8);
    if (!doc) return NULL;

    ZIToast* toast = NULL;
    HSTRING toast_cls = notif_hstr(L"Windows.UI.Notifications.ToastNotification");
    IToastFactory* factory = NULL;
    if (SUCCEEDED(RoGetActivationFactory(toast_cls,
            &IID___x_ABI_CWindows_CUI_CNotifications_CIToastNotificationFactory,
            (void**) &factory)) && factory) {
        __x_ABI_CWindows_CUI_CNotifications_CIToastNotificationFactory_CreateToastNotification(factory, doc, &toast);
        __x_ABI_CWindows_CUI_CNotifications_CIToastNotificationFactory_Release(factory);
    }
    WindowsDeleteString(toast_cls);
    __x_ABI_CWindows_CData_CXml_CDom_CIXmlDocument_Release(doc);
    if (!toast) return NULL;

    // Tag + group enable cancel/remove via history.
    ZIToast2* toast2 = NULL;
    if (SUCCEEDED(__x_ABI_CWindows_CUI_CNotifications_CIToastNotification_QueryInterface(toast,
            &IID___x_ABI_CWindows_CUI_CNotifications_CIToastNotification2, (void**) &toast2)) && toast2) {
        wchar_t* wid = notif_utf8_to_wide(notif_id);
        if (wid) {
            HSTRING htag = notif_hstr(wid);
            HSTRING hgroup = notif_hstr(ZAPP_NOTIF_GROUP);
            __x_ABI_CWindows_CUI_CNotifications_CIToastNotification2_put_Tag(toast2, htag);
            __x_ABI_CWindows_CUI_CNotifications_CIToastNotification2_put_Group(toast2, hgroup);
            WindowsDeleteString(htag);
            WindowsDeleteString(hgroup);
            free(wid);
        }
        __x_ABI_CWindows_CUI_CNotifications_CIToastNotification2_Release(toast2);
    }

    ZIActivatedHandler* handler = notif_make_activated_handler();
    if (handler) {
        EventRegistrationToken token;
        __x_ABI_CWindows_CUI_CNotifications_CIToastNotification_add_Activated(toast, handler, &token);
        handler->lpVtbl->Release(handler); // toast holds its own ref
    }
    return toast;
}

static void notif_pick_id(const char* options_json, char* out, size_t out_size) {
    if (!notif_json_str(options_json, "id", out, (int) out_size) || !out[0]) {
        snprintf(out, out_size, "notif-%lu-%lu",
                 (unsigned long) GetTickCount64(), (unsigned long) rand());
    }
}

void windows_notification_show(const char* options_json, int32_t window_id,
                               int32_t request_id, notif_callback_fn cb) {
    ZIToastNotifier* notifier = notif_notifier();
    char notif_id[128];
    notif_pick_id(options_json, notif_id, sizeof(notif_id));

    char title[256] = "", subtitle[256] = "", body[1024] = "";
    char sound[64] = "", category[64] = "", attachment[512] = "";
    notif_json_str(options_json, "title", title, sizeof(title));
    notif_json_str(options_json, "subtitle", subtitle, sizeof(subtitle));
    notif_json_str(options_json, "body", body, sizeof(body));
    notif_json_str(options_json, "sound", sound, sizeof(sound));
    notif_json_str(options_json, "categoryId", category, sizeof(category));
    notif_json_str(options_json, "attachment", attachment, sizeof(attachment));

    bool ok = false;
    if (notifier) {
        char* xml = notif_build_xml(notif_id, title, subtitle, body,
                                    attachment, sound, notif_category_json(category));
        if (xml) {
            ZIToast* toast = notif_create_toast(xml, notif_id);
            free(xml);
            if (toast) {
                ok = SUCCEEDED(__x_ABI_CWindows_CUI_CNotifications_CIToastNotifier_Show(notifier, toast));
                __x_ABI_CWindows_CUI_CNotifications_CIToastNotification_Release(toast);
            }
        }
    }

    if (cb) {
        char json[192];
        snprintf(json, sizeof(json), "{\"id\":\"%s\"}", notif_id);
        cb(window_id, request_id, ok, ok ? json : "\"toast show failed\"");
    }
}

void windows_notification_schedule(const char* options_json, int32_t window_id,
                                   int32_t request_id, notif_callback_fn cb) {
    ZIToastNotifier* notifier = notif_notifier();
    char notif_id[128];
    notif_pick_id(options_json, notif_id, sizeof(notif_id));

    char title[256] = "", subtitle[256] = "", body[1024] = "";
    char sound[64] = "", category[64] = "";
    notif_json_str(options_json, "title", title, sizeof(title));
    notif_json_str(options_json, "subtitle", subtitle, sizeof(subtitle));
    notif_json_str(options_json, "body", body, sizeof(body));
    notif_json_str(options_json, "sound", sound, sizeof(sound));
    notif_json_str(options_json, "categoryId", category, sizeof(category));
    // Trigger shape mirrors darwin: {"trigger":{"seconds":N}} — the
    // flat scan finds the nested key (it's the only "seconds").
    double seconds = notif_json_num(options_json, "seconds", 0);
    if (seconds <= 0) seconds = 1;

    bool ok = false;
    if (notifier) {
        char* xml = notif_build_xml(notif_id, title, subtitle, body, NULL, sound,
                                    notif_category_json(category));
        if (xml) {
            ZIXmlDoc* doc = notif_parse_xml(xml);
            free(xml);
            if (doc) {
                // WinRT DateTime: 100ns ticks since 1601-01-01 UTC.
                FILETIME ft;
                GetSystemTimeAsFileTime(&ft);
                ULARGE_INTEGER uli;
                uli.LowPart = ft.dwLowDateTime;
                uli.HighPart = ft.dwHighDateTime;
                __x_ABI_CWindows_CFoundation_CDateTime when;
                when.UniversalTime = (INT64) uli.QuadPart + (INT64) (seconds * 10000000.0);

                HSTRING sched_cls = notif_hstr(L"Windows.UI.Notifications.ScheduledToastNotification");
                IScheduledFactory* sfactory = NULL;
                if (SUCCEEDED(RoGetActivationFactory(sched_cls,
                        &IID___x_ABI_CWindows_CUI_CNotifications_CIScheduledToastNotificationFactory,
                        (void**) &sfactory)) && sfactory) {
                    ZIScheduled* sched = NULL;
                    if (SUCCEEDED(__x_ABI_CWindows_CUI_CNotifications_CIScheduledToastNotificationFactory_CreateScheduledToastNotification(
                            sfactory, doc, when, &sched)) && sched) {
                        ok = SUCCEEDED(__x_ABI_CWindows_CUI_CNotifications_CIToastNotifier_AddToSchedule(notifier, sched));
                        __x_ABI_CWindows_CUI_CNotifications_CIScheduledToastNotification_Release(sched);
                    }
                    __x_ABI_CWindows_CUI_CNotifications_CIScheduledToastNotificationFactory_Release(sfactory);
                }
                WindowsDeleteString(sched_cls);
                __x_ABI_CWindows_CData_CXml_CDom_CIXmlDocument_Release(doc);
            }
        }
    }

    if (cb) {
        char json[192];
        snprintf(json, sizeof(json), "{\"id\":\"%s\"}", notif_id);
        cb(window_id, request_id, ok, ok ? json : "\"toast schedule failed\"");
    }
}

void windows_notification_show_typed(const char* title, const char* subtitle,
                                     const char* body, const char* sound) {
    ZIToastNotifier* notifier = notif_notifier();
    if (!notifier) return;
    char notif_id[64];
    snprintf(notif_id, sizeof(notif_id), "notif-%lu-%lu",
             (unsigned long) GetTickCount64(), (unsigned long) rand());
    char* xml = notif_build_xml(notif_id, title ? title : "",
                                subtitle ? subtitle : "", body ? body : "",
                                NULL, sound, NULL);
    if (!xml) return;
    ZIToast* toast = notif_create_toast(xml, notif_id);
    free(xml);
    if (toast) {
        __x_ABI_CWindows_CUI_CNotifications_CIToastNotifier_Show(notifier, toast);
        __x_ABI_CWindows_CUI_CNotifications_CIToastNotification_Release(toast);
    }
}

// ---------------------------------------------------------------------------
// Cancel / permission
// ---------------------------------------------------------------------------

static ZIToastHistory* notif_history(void) {
    if (!notif_ensure_identity()) return NULL;
    static ZIToastHistory* history = NULL;
    if (history) return history;
    HSTRING cls = notif_hstr(L"Windows.UI.Notifications.ToastNotificationManager");
    IToastStatics2* statics2 = NULL;
    HRESULT hr = RoGetActivationFactory(cls,
        &IID___x_ABI_CWindows_CUI_CNotifications_CIToastNotificationManagerStatics2,
        (void**) &statics2);
    WindowsDeleteString(cls);
    if (FAILED(hr) || !statics2) return NULL;
    __x_ABI_CWindows_CUI_CNotifications_CIToastNotificationManagerStatics2_get_History(statics2, &history);
    __x_ABI_CWindows_CUI_CNotifications_CIToastNotificationManagerStatics2_Release(statics2);
    return history;
}

void windows_notification_cancel(const char* notification_id) {
    ZIToastHistory* history = notif_history();
    if (!history || !notification_id) return;
    wchar_t* wid = notif_utf8_to_wide(notification_id);
    if (!wid) return;
    HSTRING htag = notif_hstr(wid);
    HSTRING hgroup = notif_hstr(ZAPP_NOTIF_GROUP);
    HSTRING haumid = notif_hstr(zapp_aumid);
    __x_ABI_CWindows_CUI_CNotifications_CIToastNotificationHistory_RemoveGroupedTagWithId(history, htag, hgroup, haumid);
    WindowsDeleteString(htag);
    WindowsDeleteString(hgroup);
    WindowsDeleteString(haumid);
    free(wid);
}

void windows_notification_cancel_all(void) {
    ZIToastHistory* history = notif_history();
    if (!history) return;
    HSTRING haumid = notif_hstr(zapp_aumid);
    __x_ABI_CWindows_CUI_CNotifications_CIToastNotificationHistory_ClearWithId(history, haumid);
    WindowsDeleteString(haumid);
}

// Returns a JSON string VALUE (quoted) — the router passes it straight
// through as the invoke response body.
const char* windows_notification_get_permission(void) {
    ZIToastNotifier* notifier = notif_notifier();
    if (!notifier) return "\"denied\"";
    enum __x_ABI_CWindows_CUI_CNotifications_CNotificationSetting setting;
    HRESULT hr = __x_ABI_CWindows_CUI_CNotifications_CIToastNotifier_get_Setting(notifier, &setting);
    // ERROR_NOT_FOUND: no per-app settings record yet (nothing shown
    // before) — default-enabled.
    if (hr == HRESULT_FROM_WIN32(ERROR_NOT_FOUND)) return "\"granted\"";
    if (FAILED(hr)) return "\"denied\"";
    return setting == NotificationSetting_Enabled ? "\"granted\"" : "\"denied\"";
}

void windows_notification_request_permission(int32_t window_id, int32_t request_id,
                                             notif_callback_fn cb) {
    // No runtime prompt concept on Windows — permission lives in the
    // per-app Settings toggle. Report the real current state in the
    // same {"status": ...} shape darwin's completion uses.
    const char* quoted = windows_notification_get_permission();
    const char* status = (strstr(quoted, "granted") != NULL) ? "granted" : "denied";
    if (cb) {
        char json[64];
        snprintf(json, sizeof(json), "{\"status\":\"%s\"}", status);
        cb(window_id, request_id, true, json);
    }
}

// ---------------------------------------------------------------------------
// Delivered-notification management (darwin_notification_* twins). WinRT has no
// pending/delivered split — both live in the action-center toast history — so
// these reuse the cancel/cancel_all history primitives above.
// ---------------------------------------------------------------------------

// Clear the app's entire toast history.
void windows_notification_remove_all_delivered(void) {
    windows_notification_cancel_all();
}

// Remove one delivered toast by its "id" (which is the toast tag).
void windows_notification_remove_delivered_json(const char* json) {
    if (!json) return;
    char id[128] = "";
    if (notif_json_str(json, "id", id, (int)sizeof(id)) && id[0])
        windows_notification_cancel(id);
}

// Update a visible toast: re-issue with the same "id" tag. WinRT replaces a
// toast that shares tag+group, so a fresh show updates the notification in place.
void windows_notification_update_json(const char* json) {
    if (!json) return;
    windows_notification_show(json, -1, 0, NULL);
}
