// macOS platform — NSApplication, delegate, default menus, event loop.
// Pure Objective-C.

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <dispatch/dispatch.h>
#import "platform.h"

// --- App Delegate ---

static BOOL zapp_should_terminate_after_last_window_closed = NO;

@interface ZappAppDelegate : NSObject <NSApplicationDelegate>
@end

// App event dispatch — defined in app/app_events.zc
extern int zapp_app_dispatch(int event_id, const char* data);

// App event IDs (must match events.zc)
#ifndef ZAPP_EVENT_APP_STARTED
#define ZAPP_EVENT_APP_STARTED             100
#define ZAPP_EVENT_APP_SHUTDOWN            101
#define ZAPP_EVENT_APP_NOTIFICATION_CLICK  102
#define ZAPP_EVENT_APP_NOTIFICATION_ACTION 103
#define ZAPP_EVENT_APP_REOPEN             104
#define ZAPP_EVENT_APP_OPEN_URL           105
#define ZAPP_EVENT_APP_DID_BECOME_ACTIVE  106
#define ZAPP_EVENT_APP_DID_RESIGN_ACTIVE  107
#endif

@implementation ZappAppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return zapp_should_terminate_after_last_window_closed;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    zapp_app_dispatch(ZAPP_EVENT_APP_STARTED, NULL);
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    (void)notification;
    // Service shutdown in reverse registration order (before SHUTDOWN event)
    extern void service_run_shutdown_all(void);
    service_run_shutdown_all();
    zapp_app_dispatch(ZAPP_EVENT_APP_SHUTDOWN, NULL);
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    zapp_app_dispatch(ZAPP_EVENT_APP_REOPEN, flag ? "{\"hasVisibleWindows\":true}" : "{\"hasVisibleWindows\":false}");
    return YES;
}

- (void)applicationDidBecomeActive:(NSNotification*)notification {
    (void)notification;
    zapp_app_dispatch(ZAPP_EVENT_APP_DID_BECOME_ACTIVE, NULL);
}

- (void)applicationDidResignActive:(NSNotification*)notification {
    (void)notification;
    zapp_app_dispatch(ZAPP_EVENT_APP_DID_RESIGN_ACTIVE, NULL);
}

// Deep link handler: receives URLs when app is opened via custom scheme (e.g., myapp://path)
- (void)application:(NSApplication*)application openURLs:(NSArray<NSURL*>*)urls {
    (void)application;
    extern void darwin_webview_eval_all(const char* js);

    for (NSURL* url in urls) {
        NSString* urlStr = [url absoluteString];
        if (!urlStr || [urlStr length] == 0) continue;

        // Build JSON payload
        NSString* escaped = [urlStr stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        NSString* payload = [NSString stringWithFormat:@"{\"url\":\"%@\"}", escaped];

        // Layer 1: Native app event callbacks (fires immediately)
        zapp_app_dispatch(ZAPP_EVENT_APP_OPEN_URL, [payload UTF8String]);

        // Layer 2: Forward to JS bridge (all WebViews)
        NSString* escapedForJs = [urlStr stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        escapedForJs = [escapedForJs stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        NSString* js = [NSString stringWithFormat:
            @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
            "if(b&&b._onEvent)b._onEvent('app:open-url','{\"url\":\\'%@\\'}');})();",
            escapedForJs];
        darwin_webview_eval_all([js UTF8String]);
    }
}
@end

// --- Default Menus ---

static void zapp_create_default_menu(const char* nameC) {
    NSMenu* mainMenu = [[NSMenu alloc] init];
    NSString* appName = nameC ? [NSString stringWithUTF8String:nameC] : @"Zapp";

    // App menu
    NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
    NSMenu* appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"About %@", appName]
            action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Hide %@", appName]
            action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem* hideOthers = [appMenu addItemWithTitle:@"Hide Others"
            action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    [hideOthers setKeyEquivalentModifierMask:NSEventModifierFlagOption | NSEventModifierFlagCommand];
    [appMenu addItemWithTitle:@"Show All"
            action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
            action:@selector(terminate:) keyEquivalent:@"q"];
    [appMenuItem setSubmenu:appMenu];
    [mainMenu addItem:appMenuItem];

    // Edit menu
    NSMenuItem* editMenuItem = [[NSMenuItem alloc] init];
    NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenuItem setSubmenu:editMenu];
    [mainMenu addItem:editMenuItem];

    // View menu
    NSMenuItem* viewMenuItem = [[NSMenuItem alloc] init];
    NSMenu* viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem* fullScreenItem = [viewMenu addItemWithTitle:@"Enter Full Screen"
            action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    [fullScreenItem setKeyEquivalentModifierMask:NSEventModifierFlagControl | NSEventModifierFlagCommand];
    [viewMenuItem setSubmenu:viewMenu];
    [mainMenu addItem:viewMenuItem];

    // Window menu
    NSMenuItem* windowMenuItem = [[NSMenuItem alloc] init];
    NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    [windowMenuItem setSubmenu:windowMenu];
    [mainMenu addItem:windowMenuItem];
    [NSApp setWindowsMenu:windowMenu];

    [NSApp setMainMenu:mainMenu];
}

// --- C API ---

static ZappAppDelegate* zapp_app_delegate = nil;

// Set up notification delegate early so cold-launch notification clicks are handled
extern void darwin_notification_setup_delegate(void);

void darwin_platform_init(const char* app_name) {
    NSApplication* app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    if (!zapp_app_delegate) {
        zapp_app_delegate = [[ZappAppDelegate alloc] init];
    }
    [app setDelegate:zapp_app_delegate];
    zapp_create_default_menu(app_name);
    darwin_notification_setup_delegate();
}

int darwin_platform_run(bool terminate_after_last_window) {
    @autoreleasepool {
        zapp_should_terminate_after_last_window_closed = terminate_after_last_window ? YES : NO;

        // Graceful SIGINT handler
        static dispatch_source_t sigint_source = nil;
        if (!sigint_source) {
            signal(SIGINT, SIG_IGN);
            sigint_source = dispatch_source_create(
                DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
            dispatch_source_set_event_handler(sigint_source, ^{ exit(0); });
            dispatch_resume(sigint_source);
        }

        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];
    }
    return 0;
}
