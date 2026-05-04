// iOS dialog shim — UIAlertController for messages. File pickers
// (open/save) require UIDocumentPickerViewController which has a richer
// presentation flow than NSOpenPanel; deferred to Phase 2 for full
// parity. For Phase 1 spike the Dialog.message path is the most
// important since it's what hello-world templates exercise.
//
// Returns JSON results matching the macOS contract. Buffers are
// reusable statics matching darwin/dialog.m's style.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static char dialog_result[8192];
static char dialog_args_buf[4096];
static char dialog_path_buf[4096];

// Extract "a" (args) from a full bridge envelope — same helper darwin
// dialog.m exposes. Used by router.zc when dispatching dialog actions.
const char* darwin_dialog_extract_args(const char* full_json) {
    if (!full_json || !full_json[0]) return "{}";
    NSData* data = [[NSString stringWithUTF8String:full_json] dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return "{}";
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return "{}";
    id args = ((NSDictionary*)obj)[@"a"];
    if (![args isKindOfClass:[NSDictionary class]]) return "{}";
    NSData* out = [NSJSONSerialization dataWithJSONObject:args options:0 error:nil];
    if (!out) return "{}";
    NSString* s = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
    strncpy(dialog_args_buf, [s UTF8String], sizeof(dialog_args_buf) - 1);
    dialog_args_buf[sizeof(dialog_args_buf) - 1] = '\0';
    return dialog_args_buf;
}

// --- Open / Save: Phase 2 work ---
//
// UIDocumentPickerViewController is async-presentation-driven (returns
// via a delegate callback). Plumbing the same JSON-result contract the
// macOS path uses requires async bridge support that isn't quite there
// yet for the iOS path. Stub returns "cancelled" — apps see a clean
// "no file selected" rather than a crash.

const char* darwin_dialog_open_file(const char* options_json) {
    (void)options_json;
    snprintf(dialog_result, sizeof(dialog_result), "{\"cancelled\":true}");
    return dialog_result;
}

const char* darwin_dialog_save_file(const char* options_json) {
    (void)options_json;
    snprintf(dialog_result, sizeof(dialog_result), "{\"cancelled\":true}");
    return dialog_result;
}

// --- Message: UIAlertController (sync stub kept for symbol parity) ---
//
// UIAlertController is async-presentation only — no `runModal`
// equivalent exists on iOS. The real iOS path is
// `darwin_dialog_message_async` below; the router calls it on
// TARGET_OS_IPHONE and never reaches this function. Kept as a linkable
// fallback that returns button:0 immediately.

const char* darwin_dialog_message(const char* options_json) {
    (void)options_json;
    snprintf(dialog_result, sizeof(dialog_result), "{\"button\":0}");
    return dialog_result;
}

// --- Message: async (real iOS path) ---
//
// Mirrors the notification module's async-callback shape: the router
// hands us (window_id, request_id, callback). We present the alert,
// wait for a tap, then invoke the callback with the button index
// payload. Callback resolves the invoke promise on the JS side.

typedef void (*zapp_ios_dialog_cb)(int32_t wid, int32_t rid, bool ok, const char* json);

static UIViewController* zapp_ios_find_present_root(void) {
    UIWindowScene* scene = nil;
    for (UIScene* s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene*)s; break; }
    }
    if (!scene) return nil;
    for (UIWindow* w in scene.windows) {
        if (w.isKeyWindow && w.rootViewController) return w.rootViewController;
    }
    if (scene.windows.count > 0) return scene.windows.firstObject.rootViewController;
    return nil;
}

void darwin_dialog_message_async(int32_t window_id, int32_t request_id,
                                 const char* options_json, zapp_ios_dialog_cb cb) {
    @autoreleasepool {
        NSData* data = (options_json && options_json[0])
            ? [[NSString stringWithUTF8String:options_json] dataUsingEncoding:NSUTF8StringEncoding]
            : nil;
        NSDictionary* opts = (data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : @{});
        if (![opts isKindOfClass:[NSDictionary class]]) opts = @{};

        NSString* message = opts[@"message"] ?: @"";
        NSString* title = opts[@"title"] ?: @"";
        NSArray* buttons = ([opts[@"buttons"] isKindOfClass:[NSArray class]] ? opts[@"buttons"] : @[@"OK"]);

        int32_t wid = window_id;
        int32_t rid = request_id;
        zapp_ios_dialog_cb captured = cb;

        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController* alert = [UIAlertController
                alertControllerWithTitle:title
                                 message:message
                          preferredStyle:UIAlertControllerStyleAlert];
            for (NSUInteger i = 0; i < buttons.count; i++) {
                NSString* btn = [buttons[i] description];
                NSUInteger idx = i;
                [alert addAction:[UIAlertAction actionWithTitle:btn
                    style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction* _Nonnull action) {
                        (void)action;
                        char json_buf[64];
                        snprintf(json_buf, sizeof(json_buf), "{\"button\":%lu}", (unsigned long)idx);
                        if (captured) captured(wid, rid, true, json_buf);
                    }]];
            }
            UIViewController* root = zapp_ios_find_present_root();
            if (root) {
                [root presentViewController:alert animated:YES completion:nil];
            } else if (captured) {
                // No scene available — fail safe so the JS promise still resolves.
                captured(wid, rid, true, "{\"button\":0}");
            }
        });
    }
}

// --- Native typed API stubs (return empty path / button 0) ---

const char* darwin_dialog_open_file_typed(const char* title, bool multiple, bool directory) {
    (void)title; (void)multiple; (void)directory;
    dialog_path_buf[0] = '\0';
    return dialog_path_buf;
}

const char* darwin_dialog_save_file_typed(const char* title, const char* default_name) {
    (void)title; (void)default_name;
    dialog_path_buf[0] = '\0';
    return dialog_path_buf;
}

int darwin_dialog_message_typed(const char* message, const char* title, int style) {
    (void)message; (void)title; (void)style;
    return 0;
}

int darwin_dialog_message_buttons_typed(const char* message, const char* title, int style,
                                        const char* btn1, const char* btn2, const char* btn3) {
    (void)message; (void)title; (void)style;
    (void)btn1; (void)btn2; (void)btn3;
    return 0;
}
