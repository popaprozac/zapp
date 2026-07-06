// macOS platform — NSApplication, delegate, default menus, event loop.
// Pure Objective-C.

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <dispatch/dispatch.h>
#import <ServiceManagement/ServiceManagement.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import "platform.h"

#ifdef ZAPP_HAS_CEF
// webEngine:"chromium" browser-process bootstrap + teardown (native/platform/
// darwin/cef/zapp_cef_mac_entry.m). Declared here (rather than via zapp_cef.h,
// which pulls in the CEF SDK headers) so this TU stays CEF-header-free. The
// symbols are linked ONLY in a chromium build: ZAPP_HAS_CEF is defined solely
// by the gated CEF block in cli/src/build-config.ts (renderCefPlatformNim), so
// a `system` build compiles these blocks out entirely and references no
// zapp_cef_* symbol.
extern void zapp_cef_app_init(void);
extern void zapp_cef_app_shutdown(void);
#endif

// --- App Delegate ---

static BOOL zapp_should_terminate_after_last_window_closed = NO;
static BOOL zapp_quit_guard_enabled = NO;
static BOOL zapp_force_quit = NO;

@interface ZappAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, assign) BOOL themeObserverInstalled;
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
#define ZAPP_EVENT_APP_THEME_CHANGED      108
#define ZAPP_EVENT_APP_WILL_SLEEP         109
#define ZAPP_EVENT_APP_DID_WAKE           110
#define ZAPP_EVENT_APP_SCREEN_LOCKED      111
#define ZAPP_EVENT_APP_SCREEN_UNLOCKED    112
#define ZAPP_EVENT_APP_BEFORE_QUIT        113
#define ZAPP_EVENT_APP_POWER_STATE_CHANGED 114
#define ZAPP_EVENT_APP_BATTERY_LEVEL_CHANGED 115
#define ZAPP_EVENT_APP_SCREENS_CHANGED       116
#endif

void darwin_set_quit_guard(bool enabled) {
    zapp_quit_guard_enabled = enabled ? YES : NO;
}

void darwin_app_quit(bool force) {
    if (force) zapp_force_quit = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}

void darwin_app_activate(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp activateIgnoringOtherApps:YES]; });
}

// Form factor for Platform.formFactor. macOS is always "desktop". Shared by
// the webview config script (webview.m) and the worker engines (zjs/bare) so
// the value can never drift between contexts. Mirrored on iOS (ios/platform.m).
const char* zapp_form_factor(void) { return "desktop"; }

// Read the current effective appearance and return "light" or "dark".
// Returns string literals — caller must not free. Falls back to "light"
// on macOS < 10.14 (pre-dark-mode) or if NSApp isn't ready yet.
const char* darwin_get_theme(void) {
    if (![NSApp respondsToSelector:@selector(effectiveAppearance)]) {
        return "light";
    }
    NSAppearance* appearance = [NSApp effectiveAppearance];
    if (!appearance) return "light";
    NSAppearanceName best = [appearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua, NSAppearanceNameDarkAqua
    ]];
    return [best isEqualToString:NSAppearanceNameDarkAqua] ? "dark" : "light";
}

// Returns the current power state as a JSON object literal. Static buffer —
// callers (bootstrap seed + event dispatch) copy immediately on the main thread.
const char* darwin_get_power_state(void) {
    static char buf[160];
    BOOL low = NSProcessInfo.processInfo.isLowPowerModeEnabled;
    const char* source = "ac";
    int percent = -1;          // -1 -> emit null
    BOOL charging = NO;

    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (blob) {
        CFArrayRef list = IOPSCopyPowerSourcesList(blob);
        if (list) {
            if (CFArrayGetCount(list) > 0) {
                CFDictionaryRef d = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, 0));
                if (d) {
                    CFStringRef st = CFDictionaryGetValue(d, CFSTR(kIOPSPowerSourceStateKey));
                    if (st && CFEqual(st, CFSTR(kIOPSBatteryPowerValue))) source = "battery";
                    CFBooleanRef chg = CFDictionaryGetValue(d, CFSTR(kIOPSIsChargingKey));
                    if (chg && CFBooleanGetValue(chg)) charging = YES;
                    CFNumberRef cur = CFDictionaryGetValue(d, CFSTR(kIOPSCurrentCapacityKey));
                    CFNumberRef max = CFDictionaryGetValue(d, CFSTR(kIOPSMaxCapacityKey));
                    int c = 0, m = 0;
                    if (cur) CFNumberGetValue(cur, kCFNumberIntType, &c);
                    if (max) CFNumberGetValue(max, kCFNumberIntType, &m);
                    if (m > 0) percent = (c * 100 + m / 2) / m;   // integer round, no <math.h>
                }
            }
            CFRelease(list);
        }
        CFRelease(blob);
    }

    if (percent >= 0) {
        snprintf(buf, sizeof(buf),
            "{\"source\":\"%s\",\"lowPowerMode\":%s,\"percent\":%d,\"charging\":%s}",
            source, low ? "true" : "false", percent, charging ? "true" : "false");
    } else {
        snprintf(buf, sizeof(buf),
            "{\"source\":\"%s\",\"lowPowerMode\":%s,\"percent\":null,\"charging\":%s}",
            source, low ? "true" : "false", charging ? "true" : "false");
    }
    return buf;
}

static char zapp_power_last_source[16] = "";
static int  zapp_power_last_low = -1;
static int zapp_power_last_percent = -2;   // -2 = unset (-1 = "null/unknown" is a valid value)
static int zapp_power_last_charging = -1;
static CFRunLoopSourceRef zapp_power_rls = NULL;

static void zapp_power_read(const char** out_source, int* out_low, int* out_percent, int* out_charging) {
    *out_low = NSProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0;
    const char* source = "ac"; int percent = -1; int charging = 0;
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (blob) {
        CFArrayRef list = IOPSCopyPowerSourcesList(blob);
        if (list) {
            if (CFArrayGetCount(list) > 0) {
                CFDictionaryRef d = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, 0));
                if (d) {
                    CFStringRef st = CFDictionaryGetValue(d, CFSTR(kIOPSPowerSourceStateKey));
                    if (st && CFEqual(st, CFSTR(kIOPSBatteryPowerValue))) source = "battery";
                    CFBooleanRef chg = CFDictionaryGetValue(d, CFSTR(kIOPSIsChargingKey));
                    if (chg && CFBooleanGetValue(chg)) charging = 1;
                    CFNumberRef cur = CFDictionaryGetValue(d, CFSTR(kIOPSCurrentCapacityKey));
                    CFNumberRef max = CFDictionaryGetValue(d, CFSTR(kIOPSMaxCapacityKey));
                    int c = 0, m = 0;
                    if (cur) CFNumberGetValue(cur, kCFNumberIntType, &c);
                    if (max) CFNumberGetValue(max, kCFNumberIntType, &m);
                    if (m > 0) percent = (c * 100 + m / 2) / m;
                }
            }
            CFRelease(list);
        }
        CFRelease(blob);
    }
    *out_source = source; *out_percent = percent; *out_charging = charging;
}
static void zapp_power_init_cache(void) {
    const char* source; int low, percent, charging;
    zapp_power_read(&source, &low, &percent, &charging);
    strncpy(zapp_power_last_source, source, sizeof(zapp_power_last_source) - 1);
    zapp_power_last_source[sizeof(zapp_power_last_source) - 1] = '\0';
    zapp_power_last_low = low;
    zapp_power_last_percent = percent;
    zapp_power_last_charging = charging;
}
static void zapp_power_on_change(void) {
    const char* source; int low, percent, charging;
    zapp_power_read(&source, &low, &percent, &charging);
    int sl_changed  = (strcmp(source, zapp_power_last_source) != 0) || (low != zapp_power_last_low);
    int lvl_changed = (percent != zapp_power_last_percent) || (charging != zapp_power_last_charging);
    strncpy(zapp_power_last_source, source, sizeof(zapp_power_last_source) - 1);
    zapp_power_last_source[sizeof(zapp_power_last_source) - 1] = '\0';
    zapp_power_last_low = low;
    zapp_power_last_percent = percent;
    zapp_power_last_charging = charging;
    if (sl_changed || lvl_changed) {
        char payload[160];
        snprintf(payload, sizeof(payload), "%s", darwin_get_power_state());
        if (sl_changed)  zapp_app_dispatch(ZAPP_EVENT_APP_POWER_STATE_CHANGED, payload);
        if (lvl_changed) zapp_app_dispatch(ZAPP_EVENT_APP_BATTERY_LEVEL_CHANGED, payload);
    }
}
static void zapp_power_iops_cb(void* ctx) { (void)ctx; zapp_power_on_change(); }

// --- Launch-at-login (SMAppService.mainApp, macOS 13+) ---
//
// Backs App.setLoginItem / getLoginItemEnabled. registerAndReturnError:
// adds the app as a login item; unregisterAndReturnError: removes it.
// The .status property reports whether the main-app service is currently
// enabled. No-op (false) on macOS 12, where SMAppService is unavailable.
bool darwin_set_login_item(bool enabled) {
    if (@available(macOS 13.0, *)) {
        SMAppService* svc = [SMAppService mainAppService];
        NSError* err = nil;
        BOOL ok = enabled ? [svc registerAndReturnError:&err]
                          : [svc unregisterAndReturnError:&err];
        if (!ok && err) NSLog(@"[zapp] setLoginItem error: %@", err);
        return ok ? true : false;
    }
    return false; // login-item API unavailable on macOS 12
}

bool darwin_get_login_item(void) {
    if (@available(macOS 13.0, *)) {
        return [SMAppService mainAppService].status == SMAppServiceStatusEnabled ? true : false;
    }
    return false;
}

@implementation ZappAppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return zapp_should_terminate_after_last_window_closed;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
    (void)sender;
    // Forced quit (App.quit({force:true})): consume the latch and proceed.
    // Resetting here ensures an AppKit-vetoed terminate doesn't leave the
    // latch permanently set — a subsequent plain Cmd-Q re-engages the guard.
    if (zapp_force_quit) { zapp_force_quit = NO; return NSTerminateNow; }
    // No guard armed → proceed.
    if (!zapp_quit_guard_enabled) return NSTerminateNow;
    // Guard armed: tell JS a quit was requested and cancel this attempt.
    // The app runs its own (possibly async) confirmation, then re-issues
    // App.quit({force:true}) to actually terminate. Mirrors setCloseGuard;
    // avoids the NSTerminateLater "must reply or hang" footgun.
    zapp_app_dispatch(ZAPP_EVENT_APP_BEFORE_QUIT, "{}");
    return NSTerminateCancel;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;

    // KVO on NSApp.effectiveAppearance fires whenever the effective theme
    // changes — system-wide (System Settings → Appearance) and per-window
    // overrides via setAppearance:. Cheaper and more reliable than
    // listening to NSDistributedNotificationCenter's
    // AppleInterfaceThemeChangedNotification (which only catches the
    // system-wide toggle).
    if ([NSApp respondsToSelector:@selector(effectiveAppearance)]) {
        [NSApp addObserver:self
                forKeyPath:@"effectiveAppearance"
                   options:0
                   context:NULL];
        self.themeObserverInstalled = YES;
    }

    // Power / session observers. Sleep/wake come from NSWorkspace's own
    // notification center (NOT the default center); lock/unlock come from
    // the distributed center via the documented com.apple.screenIs* names.
    // All are torn down in applicationWillTerminate.
    NSNotificationCenter* wsCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
    [wsCenter addObserver:self selector:@selector(zappWillSleep:)
                     name:NSWorkspaceWillSleepNotification object:nil];
    [wsCenter addObserver:self selector:@selector(zappDidWake:)
                     name:NSWorkspaceDidWakeNotification object:nil];

    NSDistributedNotificationCenter* dist = [NSDistributedNotificationCenter defaultCenter];
    [dist addObserver:self selector:@selector(zappScreenLocked:)
                 name:@"com.apple.screenIsLocked" object:nil];
    [dist addObserver:self selector:@selector(zappScreenUnlocked:)
                 name:@"com.apple.screenIsUnlocked" object:nil];

    // Display reconfiguration (monitor plug/unplug, resolution change) — posted
    // by NSApplication on the DEFAULT center, not the distributed one.
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(zappScreensChanged:)
        name:NSApplicationDidChangeScreenParametersNotification object:nil];

    // Power-state monitoring: IOKit run-loop source for AC/battery, plus the
    // NSProcessInfo notification for Low Power Mode toggles. Seed the cache
    // first so the first real transition compares correctly.
    zapp_power_init_cache();
    zapp_power_rls = IOPSNotificationCreateRunLoopSource(zapp_power_iops_cb, NULL);
    if (zapp_power_rls) {
        CFRunLoopAddSource(CFRunLoopGetMain(), zapp_power_rls, kCFRunLoopDefaultMode);
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(zappPowerStateChanged:)
                                                 name:NSProcessInfoPowerStateDidChangeNotification
                                               object:nil];

    zapp_app_dispatch(ZAPP_EVENT_APP_STARTED, NULL);
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object
                        change:(NSDictionary*)change context:(void*)context {
    (void)object; (void)change; (void)context;
    if ([keyPath isEqualToString:@"effectiveAppearance"]) {
        const char* theme = darwin_get_theme();
        char payload[64];
        snprintf(payload, sizeof(payload), "{\"theme\":\"%s\"}", theme);
        zapp_app_dispatch(ZAPP_EVENT_APP_THEME_CHANGED, payload);
    }
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    (void)notification;
    if (self.themeObserverInstalled) {
        @try {
            [NSApp removeObserver:self forKeyPath:@"effectiveAppearance"];
        } @catch (NSException* ignored) { (void)ignored; }
        self.themeObserverInstalled = NO;
    }
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    if (zapp_power_rls) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), zapp_power_rls, kCFRunLoopDefaultMode);
        CFRelease(zapp_power_rls);
        zapp_power_rls = NULL;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // Service shutdown in reverse registration order (before SHUTDOWN event)
    extern void service_run_shutdown_all(void);
    service_run_shutdown_all();
    zapp_app_dispatch(ZAPP_EVENT_APP_SHUTDOWN, NULL);
#ifdef ZAPP_HAS_CEF
    // cef_shutdown on the terminate path (Cmd-Q / last-window-closed ->
    // NSTerminateNow). Idempotent, so the [NSApp stop] browser-close path in
    // darwin_platform_run can also call it without a double-shutdown.
    zapp_cef_app_shutdown();
#endif
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

- (void)zappWillSleep:(NSNotification*)note     { (void)note; zapp_app_dispatch(ZAPP_EVENT_APP_WILL_SLEEP, "{}"); }
- (void)zappDidWake:(NSNotification*)note        { (void)note; zapp_app_dispatch(ZAPP_EVENT_APP_DID_WAKE, "{}"); }
- (void)zappScreenLocked:(NSNotification*)note   { (void)note; zapp_app_dispatch(ZAPP_EVENT_APP_SCREEN_LOCKED, "{}"); }
- (void)zappScreenUnlocked:(NSNotification*)note { (void)note; zapp_app_dispatch(ZAPP_EVENT_APP_SCREEN_UNLOCKED, "{}"); }
- (void)zappScreensChanged:(NSNotification*)note { (void)note; zapp_app_dispatch(ZAPP_EVENT_APP_SCREENS_CHANGED, "{}"); }
- (void)zappPowerStateChanged:(NSNotification*)note { (void)note; zapp_power_on_change(); }

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
        // Workers receive this event via Layer 2 (zapp_app_dispatch
        // → _dispatchAppEvent) — don't broadcast here or Events.on
        // handlers fire twice.
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
#ifdef ZAPP_HAS_CEF
    // Install CEF's CefAppProtocol NSApplication subclass (ZappCefApplication)
    // and cef_initialize BEFORE the [NSApplication sharedApplication] below —
    // that call would otherwise create a plain NSApplication and lock NSApp to
    // the wrong class. zapp_cef_app_init installs the subclass first, so the
    // sharedApplication call below returns that same instance. CEF's external
    // message pump then drives off the [NSApp run] loop darwin_platform_run
    // owns; no second run loop is started (THE #1 integration risk). The
    // ZappCefApplication also installs its own (throwaway) delegate, which the
    // [app setDelegate:zapp_app_delegate] below immediately supersedes — Zapp's
    // delegate (theme/screen/reopen/quit-guard) stays authoritative.
    zapp_cef_app_init();
#endif
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
#ifdef ZAPP_HAS_CEF
        // [NSApp run] returns when the CEF life-span handler stops the loop
        // ([NSApp stop] on the last browser close). Shut CEF down here; the
        // terminate path is covered by applicationWillTerminate. Idempotent.
        zapp_cef_app_shutdown();
#endif
    }
    return 0;
}
