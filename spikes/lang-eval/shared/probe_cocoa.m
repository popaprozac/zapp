#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include "probe.h"

// Minimal stand-in for window.m: opens a real NSWindow, pumps the run loop
// ~1s so it's visibly shown, then returns (non-blocking probe — the binary
// launches, shows a window, exits 0). The interop mechanism being measured
// (orchestration lang -> C ABI -> ObjC) is identical to the real layer.
void spike_cocoa_open_window(int w, int h, const char* title) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow* win = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, w, h)
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                        backing:NSBackingStoreBuffered defer:NO];
        win.title = title ? [NSString stringWithUTF8String:title] : @"spike";
        [win center];
        [win makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        NSDate* until = [NSDate dateWithTimeIntervalSinceNow:1.0];
        for (;;) {
            NSEvent* e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until
                                               inMode:NSDefaultRunLoopMode dequeue:YES];
            if (!e) break;
            [NSApp sendEvent:e];
        }
        (void)fprintf(stdout, "[spike] cocoa window opened %dx%d '%s'\n", w, h, title ? title : "");
    }
}

void spike_print_windows(void) {
    (void)fprintf(stdout, "[spike] windows path (stub)\n");
}

// Phase 2: the macOS branch of a platform-gated action (dock:bounce-ish).
void spike_cocoa_beep(void) {
    NSBeep();
    (void)fprintf(stdout, "[spike] cocoa beep\n");
}
