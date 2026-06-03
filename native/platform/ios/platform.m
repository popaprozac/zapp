// iOS platform layer — UIApplicationMain entry, app delegate, scene
// delegate, app event dispatch, theme detection, shell helpers.
//
// This is the iOS counterpart to darwin/platform.m. The `darwin_*`
// function names are kept (rather than renamed to `ios_*`) so the
// framework's Zen-C calls bind to the same symbols across platforms.
// `Apple platform` is the right mental model — these are darwin
// platform functions, just an iOS implementation.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

extern int zapp_app_dispatch(int event_id, const char* data);

#ifndef ZAPP_EVENT_APP_STARTED
#define ZAPP_EVENT_APP_STARTED             100
#define ZAPP_EVENT_APP_SHUTDOWN            101
#define ZAPP_EVENT_APP_NOTIFICATION_CLICK  102
#define ZAPP_EVENT_APP_NOTIFICATION_ACTION 103
#define ZAPP_EVENT_APP_REOPEN             104
#define ZAPP_EVENT_APP_OPEN_URL           105
#define ZAPP_EVENT_APP_DID_BECOME_ACTIVE  106
#define ZAPP_EVENT_APP_DID_RESIGN_ACTIVE  107
#define ZAPP_EVENT_APP_THEME_CHANGED      108
#define ZAPP_EVENT_APP_WILL_SLEEP         109
#define ZAPP_EVENT_APP_DID_WAKE           110
#define ZAPP_EVENT_APP_SCREEN_LOCKED      111
#define ZAPP_EVENT_APP_SCREEN_UNLOCKED    112
#define ZAPP_EVENT_APP_BEFORE_QUIT        113
#endif

// --- Theme detection ---
//
// iOS exposes the same NSAppearance machinery via UITraitCollection.
// `UIScreen.mainScreen.traitCollection.userInterfaceStyle` returns
// UIUserInterfaceStyleLight / .Dark / .Unspecified. Trait changes are
// caught via UIViewController.traitCollectionDidChange — wired in
// window.m so the app dispatches THEME_CHANGED events.

const char* darwin_get_theme(void) {
    UIUserInterfaceStyle style = UITraitCollection.currentTraitCollection.userInterfaceStyle;
    return style == UIUserInterfaceStyleDark ? "dark" : "light";
}

// --- Shell helpers (App.openExternal / openPath / showItemInFolder / trashItem) ---
//
// `openExternal` works the same conceptually (open URL in default app)
// but uses UIApplication.openURL: which is async-callback only on iOS
// 10+. `openPath` doesn't have a clean iOS equivalent for arbitrary
// filesystem paths — we route through openURL with a file:// URL,
// which on iOS opens the file in QuickLook for known types or fails
// silently. `showItemInFolder` is no-op (no Finder). `trashItem` does
// a regular delete via NSFileManager (no system Trash on iOS).

void darwin_open_external(const char* url_str) {
    if (!url_str || !url_str[0]) return;
    @autoreleasepool {
        NSURL* url = [NSURL URLWithString:[NSString stringWithUTF8String:url_str]];
        if (!url) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        });
    }
}

void darwin_show_item_in_folder(const char* path) {
    (void)path;  // no-op: no Finder on iOS
}

void darwin_open_path(const char* path) {
    if (!path || !path[0]) return;
    @autoreleasepool {
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        if (!url) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        });
    }
}

void darwin_trash_item(const char* path) {
    if (!path || !path[0]) return;
    @autoreleasepool {
        // iOS has no system Trash — just delete. The framework's
        // FS allowlist gating already happened on the Zen-C side; by
        // the time we're here the path is allowed.
        [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:path] error:nil];
    }
}

// --- JS string escape helper (mirrors darwin/webview.m export) ---

const char* darwin_escape_js_string(const char* raw) {
    static char zapp_ios_escape_buf[8192];
    if (!raw || !raw[0]) { zapp_ios_escape_buf[0] = '\0'; return zapp_ios_escape_buf; }
    size_t j = 0;
    for (size_t i = 0; raw[i] && j + 2 < sizeof(zapp_ios_escape_buf) - 1; i++) {
        switch (raw[i]) {
            case '\\': zapp_ios_escape_buf[j++] = '\\'; zapp_ios_escape_buf[j++] = '\\'; break;
            case '\'': zapp_ios_escape_buf[j++] = '\\'; zapp_ios_escape_buf[j++] = '\''; break;
            case '\n': zapp_ios_escape_buf[j++] = '\\'; zapp_ios_escape_buf[j++] = 'n'; break;
            case '\r': zapp_ios_escape_buf[j++] = '\\'; zapp_ios_escape_buf[j++] = 'r'; break;
            default:   zapp_ios_escape_buf[j++] = raw[i]; break;
        }
    }
    zapp_ios_escape_buf[j] = '\0';
    return zapp_ios_escape_buf;
}

// --- App delegate ---

@interface ZappAppDelegate : UIResponder <UIApplicationDelegate, UISceneDelegate>
// No `window` property — UIWindows are scene-attached and retained via
// UIWindowScene; the deferred-window registry in window.m holds the
// app-side strong reference for setter dispatch.
@end

@implementation ZappAppDelegate

- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id>*)launchOptions {
    (void)application; (void)launchOptions;
    zapp_app_dispatch(ZAPP_EVENT_APP_STARTED, NULL);

    // Drain the deferred-window queue from window.m. The framework's
    // startup sequence (`app.window.create()` → `app.run()` →
    // platform_run → UIApplicationMain) means user code asked for a
    // window before any UIWindowScene existed. window.m responded by
    // returning a deferred handle and recording intent; now that we're
    // inside UIApplicationMain with a connected scene available, build
    // the real UIWindow + UIViewController + WKWebView.
    //
    // This is the same shape Tauri Mobile uses (see tao's app_state.rs
    // queued_windows / on_app_ready). Trying to migrate an orphaned
    // pre-created window's view controller crashes the gesture
    // recognizer subsystem on first tap; deferred creation sidesteps
    // the entire class of bug.
    extern void zapp_ios_materialize_pending_windows(void);
    zapp_ios_materialize_pending_windows();
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication*)application {
    (void)application;
    zapp_app_dispatch(ZAPP_EVENT_APP_DID_BECOME_ACTIVE, NULL);
}

- (void)applicationWillResignActive:(UIApplication*)application {
    (void)application;
    zapp_app_dispatch(ZAPP_EVENT_APP_DID_RESIGN_ACTIVE, NULL);
}

- (void)applicationWillTerminate:(UIApplication*)application {
    (void)application;
    extern void service_run_shutdown_all(void);
    service_run_shutdown_all();
    zapp_app_dispatch(ZAPP_EVENT_APP_SHUTDOWN, NULL);
}

- (BOOL)application:(UIApplication*)app openURL:(NSURL*)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id>*)options {
    (void)app; (void)options;
    NSString* urlStr = [url absoluteString];
    if (urlStr.length > 0) {
        NSString* escaped = [urlStr stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        NSString* payload = [NSString stringWithFormat:@"{\"url\":\"%@\"}", escaped];
        zapp_app_dispatch(ZAPP_EVENT_APP_OPEN_URL, [payload UTF8String]);
    }
    return YES;
}

@end

// --- Platform init / run ---
//
// `darwin_platform_init` is called from the framework's app.zc startup
// before windows are created. On macOS this stuffs the dock title,
// builds default menus, etc. On iOS there's no analog — UIApplication
// handles everything. We accept the call and no-op.
//
// `darwin_platform_run` is the main loop. macOS calls [NSApp run]; iOS
// calls UIApplicationMain which never returns. We pass our app
// delegate class name in.

void darwin_platform_init(const char* app_name) {
    (void)app_name;
}

int darwin_platform_run(bool terminate_after_last_window) {
    (void)terminate_after_last_window;  // iOS doesn't have multi-window-close-quits semantics
    @autoreleasepool {
        // UIApplicationMain blocks; the framework's app.run() returns
        // when the app terminates. Pass NULL for principal class to
        // use UIApplication; pass our delegate's class name.
        return UIApplicationMain(0, NULL, nil, NSStringFromClass([ZappAppDelegate class]));
    }
}
