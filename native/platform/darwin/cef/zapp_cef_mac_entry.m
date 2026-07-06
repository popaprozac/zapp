// Zapp CEF host (macOS) — macOS scaffolding: the CefAppProtocol NSApplication
// subclass + the C helpers the future Nim/build-system caller (T2) uses to
// build cef_main_args_t / cef_settings_t / cef_window_info_t.
//
// Promoted from the proven GO spike (`spikes/cef-macos/mac_entry.m` — see
// docs/superpowers/specs/2026-07-05-cef-webengine-production-slice-macos-
// design.md and spikes/cef-macos/FINDINGS.md, Tasks 0/1). Renamed cefspike_
// -> zapp_cef_, ZappSpike* -> ZappCef*, "spike" dropped. (The host NSWindow
// itself is built in zapp_cef_host.m, not here — see
// zapp_cef_make_host_window / zapp_cef_create_browser_in_view.)
//
// Divergences from the CEF reference (cefsimple_capi/cefsimple_mac.m),
// unchanged from the spike:
//   - No runtime CEF library loader (cef_scoped_library_loader_*). Links the
//     framework DIRECTLY (rpath @executable_path/../Frameworks). That is
//     simpler for the current build and fine for a non-sandbox dev run; the
//     runtime loader is the production path needed for the macOS sandbox —
//     flagged for a later task.
//   - No MainMenu.xib load; an activation policy is set (zapp_cef_host.m
//     opens/hosts the window).
//   - The cef_initialize / cef_browser_host_create_browser / cef_shutdown
//     calls are NOT made here — this file only prepares the pieces the
//     caller (T2's build integration) assembles them from.

#import <Cocoa/Cocoa.h>

#include <string.h>

#include "zapp_cef.h"

#include "include/capi/cef_app_capi.h"  // cef_do_message_loop_work
#include "include/cef_api_hash.h"
#include "include/cef_application_mac.h"
#include "include/cef_version.h"
#include "include/internal/cef_string.h"

// ---------------------------------------------------------------------------
// CefAppProtocol NSApplication subclass (required by CEF on macOS).
// ---------------------------------------------------------------------------

@interface ZappCefApplication : NSApplication <CefAppProtocol> {
 @private
  BOOL handlingSendEvent_;
}
@end

@implementation ZappCefApplication
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

@interface ZappCefAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation ZappCefAppDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
  return NSTerminateNow;
}
// Secure state restoration (macOS 12+); also avoids incorrect window restore.
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication*)app {
  return YES;
}
@end

// NSApp.delegate is a weak reference — keep a strong one alive.
static ZappCefAppDelegate* g_delegate = nil;

// External-pump owner. Interface declared here so zapp_cef_ns_application_init
// (below) can create it; @implementation lives at the bottom of the file.
@interface ZappCefPump : NSObject
- (void)scheduleWork:(NSNumber*)delayMs;  // main thread
@end

static ZappCefPump* g_pump = nil;

// ---------------------------------------------------------------------------
// C helpers (declared in zapp_cef.h, called by the future build-integration
// caller).
// ---------------------------------------------------------------------------

void zapp_cef_ns_application_init(void) {
  // Configure the CEF API version before any other CEF call. Guarded so an
  // older SDK that predates API versioning still compiles.
#ifdef CEF_API_VERSION
  cef_api_hash(CEF_API_VERSION, 0);
#endif

  [ZappCefApplication sharedApplication];
  if (![NSApp isKindOfClass:[ZappCefApplication class]]) {
    fprintf(stderr, "[zapp-cef] NSApp is not a ZappCefApplication\n");
    abort();
  }

  g_delegate = [[ZappCefAppDelegate alloc] init];
  NSApp.delegate = g_delegate;
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

  // External-message-pump owner. Created before cef_initialize so the
  // browser-process handler's on_schedule_message_pump_work has a live target.
  g_pump = [[ZappCefPump alloc] init];
}

cef_main_args_t* zapp_cef_make_main_args(int argc, char** argv) {
  static cef_main_args_t args;
  args.argc = argc;
  args.argv = argv;
  return &args;
}

cef_settings_t* zapp_cef_make_settings(void) {
  static cef_settings_t settings;
  memset(&settings, 0, sizeof(settings));
  settings.size = sizeof(cef_settings_t);

  // Dev/spike-derived default: no sandbox. PRODUCTION SEED: a shipping
  // webEngine:"chromium" build needs the sandboxed path — flagged for a
  // later task.
  settings.no_sandbox = 1;
  settings.log_severity = LOGSEVERITY_WARNING;

  // EXTERNAL MESSAGE PUMP. NSApplication owns the loop ([NSApp run]); CEF is
  // advanced by cef_do_message_loop_work() calls that the ObjC pump below
  // schedules from the browser-process handler's
  // on_schedule_message_pump_work. multi_threaded_message_loop MUST stay 0
  // for external pump (see below).
  settings.multi_threaded_message_loop = 0;
  settings.external_message_pump = 1;

  NSString* frameworksDir = [[NSBundle mainBundle] privateFrameworksPath];
  NSString* fw = [frameworksDir
      stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
  // BUILD-INTEGRATION TODO (T2): the Helper bundle name/path is still the
  // originating spike's literal ("cef-spike Helper.app") — T2 must update
  // this to match whatever name its packaging step gives the app's CEF
  // Helper bundle(s) (build.sh assembled five variants for the spike: GPU,
  // Renderer, Plugin, Alerts, and the base Helper — a real package needs the
  // same set, named after the app rather than "cef-spike").
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

cef_window_info_t* zapp_cef_make_window_info(void* parent_view, int width,
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

// ===========================================================================
// External message pump (the #1 risk gate the originating spike proved out).
//
// This is the C-API port of cefclient's browser_message_loop_external_pump*
// (chromiumembedded/cef, BSD). The scheme:
//
//   * CEF calls on_schedule_message_pump_work(delay_ms) from ANY thread when it
//     has queued browser-UI work (zapp_cef_app.c forwards to zapp_cef_pump_schedule).
//   * zapp_cef_pump_schedule hops to the MAIN thread (performSelectorOnMainThread
//     in NSRunLoopCommonModes, so it also fires during modal/resize tracking
//     loops) and calls -scheduleWork:.
//   * -scheduleWork: with delay <= 0 pumps immediately; with delay > 0 arms an
//     NSTimer (capped at kMaxTimerDelay so an idle CEF still gets serviced).
//   * -doWork runs cef_do_message_loop_work() under a reentrancy guard (CEF may
//     pump nested run loops that re-enter us), and — if CEF asked for more work
//     mid-pump — reschedules immediately; otherwise arms the fallback timer.
//
// Because [NSApp run] owns the loop and each cef_do_message_loop_work() is
// non-blocking, AppKit keeps servicing user events (drag/resize) between
// pumps — proven alongside a second, worker-shaped loop in the originating
// spike (see spikes/cef-macos/FINDINGS.md, Task 1).
// ===========================================================================

// Never wait longer than this between pumps (~30fps) even if CEF forgets to
// schedule — matches cefclient's kMaxTimerDelay.
static const int64_t kCefPumpMaxDelayMs = 1000 / 30;

@implementation ZappCefPump {
 @private
  NSTimer* timer_;
  BOOL isActive_;
  BOOL reentrancyDetected_;
}

- (BOOL)isTimerPending {
  return timer_ != nil;
}

- (void)killTimer {
  if (timer_ != nil) {
    [timer_ invalidate];
    timer_ = nil;
  }
}

- (void)setTimer:(int64_t)delayMs {
  [self killTimer];
  double delaySeconds = (double)delayMs / 1000.0;
  timer_ = [NSTimer timerWithTimeInterval:delaySeconds
                                   target:self
                                 selector:@selector(onTimer:)
                                 userInfo:nil
                                  repeats:NO];
  // Common modes so the pump keeps firing during live-resize / modal tracking.
  [[NSRunLoop currentRunLoop] addTimer:timer_ forMode:NSRunLoopCommonModes];
}

- (void)onTimer:(NSTimer*)timer {
  (void)timer;
  [self killTimer];
  [self doWork];
}

// Returns YES if a reentrant pump was detected (CEF wants more work now).
- (BOOL)performMessageLoopWork {
  if (isActive_) {
    // Reentrant call (CEF pumped a nested run loop): flag it and unwind.
    reentrancyDetected_ = YES;
    return NO;
  }
  BOOL wasReentrant = NO;
  for (;;) {
    isActive_ = YES;
    reentrancyDetected_ = NO;
    [self killTimer];
    cef_do_message_loop_work();
    isActive_ = NO;
    if (!reentrancyDetected_) {
      break;
    }
    wasReentrant = YES;
  }
  return wasReentrant;
}

- (void)doWork {
  BOOL wasReentrant = [self performMessageLoopWork];
  if (wasReentrant) {
    // CEF asked for more work while we were pumping — service it ASAP.
    zapp_cef_pump_schedule(0);
  } else if (![self isTimerPending]) {
    // Arm a fallback timer so an otherwise-idle CEF still gets serviced.
    [self setTimer:kCefPumpMaxDelayMs];
  }
}

- (void)scheduleWork:(NSNumber*)delayMs {
  int64_t delay = [delayMs longLongValue];
  if (delay <= 0) {
    [self doWork];
  } else {
    if (delay > kCefPumpMaxDelayMs) {
      delay = kCefPumpMaxDelayMs;
    }
    [self setTimer:delay];
  }
}

@end

void zapp_cef_pump_schedule(int64_t delay_ms) {
  // May be called on any thread (and possibly before [NSApp run]). Hop to the
  // main thread in common modes; the call is queued until the loop spins.
  ZappCefPump* pump = g_pump;
  if (pump == nil) {
    return;  // pre-init; CEF re-schedules once the handler is live.
  }
  [pump performSelectorOnMainThread:@selector(scheduleWork:)
                         withObject:@(delay_ms)
                      waitUntilDone:NO
                              modes:@[ NSRunLoopCommonModes ]];
}

void zapp_cef_run_main_loop(void) {
  [NSApp run];
}

void zapp_cef_quit_main_loop(void) {
  // External-pump mode: cef_quit_message_loop does not apply. Stop the NSApp
  // loop; -stop: only takes effect after the next event is dequeued, so post a
  // dummy application-defined event to wake the loop immediately.
  [NSApp stop:nil];
  NSEvent* wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                     location:NSZeroPoint
                                modifierFlags:0
                                    timestamp:0
                                 windowNumber:0
                                      context:nil
                                      subtype:0
                                        data1:0
                                        data2:0];
  [NSApp postEvent:wake atStart:YES];
}
