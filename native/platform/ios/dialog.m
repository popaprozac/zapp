// iOS dialog shim — UIAlertController for messages. File pickers
// (open/save) require UIDocumentPickerViewController which has a richer
// presentation flow than NSOpenPanel; deferred to Phase 2 for full
// parity. For Phase 1 spike the Dialog.message path is the most
// important since it's what sample apps exercise.
//
// Returns JSON results matching the macOS contract. Buffers are
// reusable statics matching darwin/dialog.m's style.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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

// --- Open / Save: sync stubs (router routes iOS to the _async path) ---
//
// UIDocumentPickerViewController is async-presentation-driven, so the
// real iOS dialog code lives in `darwin_dialog_open_file_async` /
// `darwin_dialog_save_file_async` below. The router branches on
// TARGET_OS_IPHONE and never reaches these — kept as linkable
// fallbacks that return "cancelled".

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

// --- Open / Save: async (UIDocumentPickerViewController) ---
//
// Mirrors darwin_dialog_message_async's shape: the router hands us
// (window_id, request_id, callback). We present the picker, on pick
// or cancel call the callback with the same JSON shape macOS uses
// (`{"cancelled":true}` or `{"cancelled":false,"paths":[...]}`/
// `{"cancelled":false,"path":"..."}`). The runtime FS allowlist
// extension that macOS triggers via router_grant_paths_from_dialog
// works on iOS too because UIDocumentPickerViewController returns
// security-scoped URLs whose `.path` is a real filesystem path —
// security-scope must be started by the caller before reading.

typedef NS_ENUM(NSInteger, ZappIOSPickerMode) {
    ZAPP_IOS_PICKER_OPEN = 0,
    ZAPP_IOS_PICKER_SAVE = 1,
};

@interface ZappIOSDocPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, assign) int32_t windowId;
@property (nonatomic, assign) int32_t requestId;
@property (nonatomic, assign) zapp_ios_dialog_cb cb;
@property (nonatomic, assign) ZappIOSPickerMode mode;
@property (nonatomic, copy)   NSString* defaultName;       // save mode appends to picked dir
@property (nonatomic, strong) ZappIOSDocPickerDelegate* selfRetain;  // released after callback
@end

@implementation ZappIOSDocPickerDelegate

- (NSString*)escapeJson:(NSString*)s {
    NSString* e = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    return [e stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

- (void)deliver:(NSString*)json {
    if (self.cb) self.cb(self.windowId, self.requestId, true, [json UTF8String]);
    self.selfRetain = nil;
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    (void)controller;
    if (self.mode == ZAPP_IOS_PICKER_SAVE) {
        // Save flow: user picked a directory — append defaultName to
        // produce the final path. JS-side runtime is expected to write
        // via FS.writeFile against this path. iOS security scope: the
        // router's allowlist grant pulls the path through, and the FS
        // helper (fs.m) calls startAccessingSecurityScopedResource on
        // first access if the path is outside the app sandbox.
        NSURL* dir = urls.firstObject;
        if (!dir) {
            [self deliver:@"{\"cancelled\":true}"];
            return;
        }
        NSString* name = self.defaultName.length > 0 ? self.defaultName : @"untitled";
        NSURL* full = [dir URLByAppendingPathComponent:name];
        NSString* path = full.path ?: @"";
        NSString* json = [NSString stringWithFormat:
            @"{\"cancelled\":false,\"path\":\"%@\"}", [self escapeJson:path]];
        [self deliver:json];
        return;
    }

    // Open flow: build a paths array.
    NSMutableString* json = [NSMutableString stringWithString:@"{\"cancelled\":false,\"paths\":["];
    for (NSUInteger i = 0; i < urls.count; i++) {
        if (i > 0) [json appendString:@","];
        NSString* path = urls[i].path ?: @"";
        [json appendFormat:@"\"%@\"", [self escapeJson:path]];
    }
    [json appendString:@"]}"];
    [self deliver:json];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller {
    (void)controller;
    [self deliver:@"{\"cancelled\":true}"];
}

@end

// Convert filters from `[{name,extensions:[...]}]` form to UTType array.
// Unknown extensions fall through to `UTType.data` so the picker still
// presents a sensible list.
static NSArray<UTType*>* zapp_ios_utis_for_filters(NSArray* filters, BOOL directoryMode) {
    if (directoryMode) return @[[UTType typeWithIdentifier:@"public.folder"]];
    NSMutableArray<UTType*>* result = [NSMutableArray array];
    if ([filters isKindOfClass:[NSArray class]]) {
        for (id f in filters) {
            if (![f isKindOfClass:[NSDictionary class]]) continue;
            NSArray* exts = ((NSDictionary*)f)[@"extensions"];
            if (![exts isKindOfClass:[NSArray class]]) continue;
            for (id e in exts) {
                if (![e isKindOfClass:[NSString class]]) continue;
                UTType* t = [UTType typeWithFilenameExtension:(NSString*)e];
                if (t) [result addObject:t];
            }
        }
    }
    if (result.count == 0) [result addObject:[UTType typeWithIdentifier:@"public.item"]];
    return result;
}

void darwin_dialog_open_file_async(int32_t window_id, int32_t request_id,
                                   const char* options_json, zapp_ios_dialog_cb cb) {
    @autoreleasepool {
        NSData* data = (options_json && options_json[0])
            ? [[NSString stringWithUTF8String:options_json] dataUsingEncoding:NSUTF8StringEncoding]
            : nil;
        NSDictionary* opts = (data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : @{});
        if (![opts isKindOfClass:[NSDictionary class]]) opts = @{};

        BOOL multiple = [opts[@"multiple"] boolValue];
        BOOL directory = [opts[@"directory"] boolValue];
        NSArray* filters = opts[@"filters"];

        int32_t wid = window_id;
        int32_t rid = request_id;
        zapp_ios_dialog_cb captured = cb;

        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<UTType*>* types = zapp_ios_utis_for_filters(filters, directory);
            UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc]
                initForOpeningContentTypes:types asCopy:NO];
            picker.allowsMultipleSelection = multiple;

            ZappIOSDocPickerDelegate* del = [[ZappIOSDocPickerDelegate alloc] init];
            del.windowId = wid;
            del.requestId = rid;
            del.cb = captured;
            del.mode = ZAPP_IOS_PICKER_OPEN;
            del.selfRetain = del;        // keep alive past stack frame
            picker.delegate = del;

            UIViewController* root = zapp_ios_find_present_root();
            if (root) {
                [root presentViewController:picker animated:YES completion:nil];
            } else if (captured) {
                captured(wid, rid, true, "{\"cancelled\":true}");
            }
        });
    }
}

void darwin_dialog_save_file_async(int32_t window_id, int32_t request_id,
                                   const char* options_json, zapp_ios_dialog_cb cb) {
    @autoreleasepool {
        NSData* data = (options_json && options_json[0])
            ? [[NSString stringWithUTF8String:options_json] dataUsingEncoding:NSUTF8StringEncoding]
            : nil;
        NSDictionary* opts = (data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : @{});
        if (![opts isKindOfClass:[NSDictionary class]]) opts = @{};

        NSString* defaultName = opts[@"defaultName"] ?: @"untitled";

        int32_t wid = window_id;
        int32_t rid = request_id;
        zapp_ios_dialog_cb captured = cb;

        dispatch_async(dispatch_get_main_queue(), ^{
            // iOS save flow: NSSavePanel doesn't exist. The closest match
            // is "let user pick a directory" then we append defaultName.
            // Apps then write via FS.writeFile to the returned path. This
            // is the same model Files.app + share-sheet exporters use.
            UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc]
                initForOpeningContentTypes:@[[UTType typeWithIdentifier:@"public.folder"]] asCopy:NO];
            picker.allowsMultipleSelection = NO;

            ZappIOSDocPickerDelegate* del = [[ZappIOSDocPickerDelegate alloc] init];
            del.windowId = wid;
            del.requestId = rid;
            del.cb = captured;
            del.mode = ZAPP_IOS_PICKER_SAVE;
            del.defaultName = defaultName;
            del.selfRetain = del;
            picker.delegate = del;

            UIViewController* root = zapp_ios_find_present_root();
            if (root) {
                [root presentViewController:picker animated:YES completion:nil];
            } else if (captured) {
                captured(wid, rid, true, "{\"cancelled\":true}");
            }
        });
    }
}
