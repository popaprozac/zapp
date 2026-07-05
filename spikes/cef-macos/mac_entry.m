// CEF spike (Task 0) — macOS scaffolding: the CefAppProtocol NSApplication
// subclass + the C helpers main.nim calls to build cef_main_args_t /
// cef_settings_t / cef_window_info_t and to open a host NSWindow.
//
// Adapted from cefsimple_capi/cefsimple_mac.m. Divergences (deliberate, spike):
//   - No runtime CEF library loader (cef_scoped_library_loader_*). The spike
//     links the framework DIRECTLY (rpath @executable_path/../Frameworks). That
//     is simpler for a Nim build and fine for a non-sandbox dev run; the runtime
//     loader is the production path (needed for the macOS sandbox).
//   - No MainMenu.xib load; we set an activation policy and open our own window.
//   - The cef_initialize / cef_run_message_loop / cef_shutdown calls live in
//     main.nim (Nim drives the lifecycle) — this file only prepares the pieces.

#import <Cocoa/Cocoa.h>

#include <string.h>

#include "cef_spike.h"

#include "include/cef_api_hash.h"
#include "include/cef_application_mac.h"
#include "include/cef_version.h"
#include "include/internal/cef_string.h"

// ---------------------------------------------------------------------------
// CefAppProtocol NSApplication subclass (required by CEF on macOS).
// ---------------------------------------------------------------------------

@interface ZappSpikeApplication : NSApplication <CefAppProtocol> {
 @private
  BOOL handlingSendEvent_;
}
@end

@implementation ZappSpikeApplication
- (BOOL)isHandlingSendEvent {
  return handlingSendEvent_;
}
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  handlingSendEvent_ = handlingSendEvent;
}
- (void)sendEvent:(NSEvent*)event {
  BOOL wasHandlingSendEvent = [self isHandlingSendEvent];
  [self setHandlingSendEvent:YES];
  [super sendEvent:event];
  [self setHandlingSendEvent:wasHandlingSendEvent];
}
@end

@interface ZappSpikeAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation ZappSpikeAppDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
  return NSTerminateNow;
}
// Secure state restoration (macOS 12+); also avoids incorrect window restore.
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication*)app {
  return YES;
}
@end

// NSApp.delegate is a weak reference — keep a strong one alive.
static ZappSpikeAppDelegate* g_delegate = nil;
// The host window; retained so its content view survives as CEF's parent_view.
static NSWindow* g_window = nil;

// ---------------------------------------------------------------------------
// C helpers (declared in cef_spike.h, called from main.nim).
// ---------------------------------------------------------------------------

void cefspike_ns_application_init(void) {
  // Configure the CEF API version before any other CEF call. Guarded so an
  // older SDK that predates API versioning still compiles.
#ifdef CEF_API_VERSION
  cef_api_hash(CEF_API_VERSION, 0);
#endif

  [ZappSpikeApplication sharedApplication];
  if (![NSApp isKindOfClass:[ZappSpikeApplication class]]) {
    fprintf(stderr, "[cef-spike] NSApp is not a ZappSpikeApplication\n");
    abort();
  }

  g_delegate = [[ZappSpikeAppDelegate alloc] init];
  NSApp.delegate = g_delegate;
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
}

cef_main_args_t* cefspike_make_main_args(int argc, char** argv) {
  static cef_main_args_t args;
  args.argc = argc;
  args.argv = argv;
  return &args;
}

cef_settings_t* cefspike_make_settings(void) {
  static cef_settings_t settings;
  memset(&settings, 0, sizeof(settings));
  settings.size = sizeof(cef_settings_t);

  // Dev spike: no sandbox. T0 uses CEF's own message loop (cef_run_message_loop),
  // so both multi_threaded_message_loop and external_message_pump stay 0.
  settings.no_sandbox = 1;
  settings.log_severity = LOGSEVERITY_WARNING;

  NSString* frameworksDir = [[NSBundle mainBundle] privateFrameworksPath];
  NSString* fw = [frameworksDir
      stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
  NSString* helper = [frameworksDir
      stringByAppendingPathComponent:
          @"cef-spike Helper.app/Contents/MacOS/cef-spike Helper"];
  NSString* bundle = [[NSBundle mainBundle] bundlePath];

  const char* fwc = fw.UTF8String;
  const char* helperc = helper.UTF8String;
  const char* bundlec = bundle.UTF8String;
  cef_string_utf8_to_utf16(fwc, strlen(fwc), &settings.framework_dir_path);
  cef_string_utf8_to_utf16(helperc, strlen(helperc),
                           &settings.browser_subprocess_path);
  cef_string_utf8_to_utf16(bundlec, strlen(bundlec), &settings.main_bundle_path);

  return &settings;
}

void* cefspike_create_window(int width, int height, const char* title) {
  NSRect frame = NSMakeRect(0, 0, width, height);
  NSWindow* win = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskMiniaturizable |
                           NSWindowStyleMaskResizable)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [win setTitle:[NSString stringWithUTF8String:(title ? title : "CEF Spike")]];
  [win center];

  NSView* content = [[NSView alloc] initWithFrame:frame];
  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  win.contentView = content;

  [win makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];

  g_window = win;  // strong static ref keeps window + content view alive
  return (__bridge void*)content;
}

cef_window_info_t* cefspike_make_window_info(void* parent_view, int width,
                                             int height) {
  static cef_window_info_t info;
  memset(&info, 0, sizeof(info));
  info.size = sizeof(cef_window_info_t);
  info.bounds.x = 0;
  info.bounds.y = 0;
  info.bounds.width = width;
  info.bounds.height = height;
  info.parent_view = (cef_window_handle_t)parent_view;
  // Alloy style: the browser is hosted inside our NSView. (Chrome style would
  // manage its own top-level window/UI.)
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  return &info;
}
