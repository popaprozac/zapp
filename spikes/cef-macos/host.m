// CEF spike (Task 2) — host the CEF browser inside a standard Zapp-style
// NSWindow (titlebar + traffic lights), proving hosting-fit for
// webEngine:"chromium".
//
// T0/T1 already created the browser as WINDOWED (cef_window_info_t.parent_view
// set to an NSView, Alloy runtime_style — see cefspike_make_window_info in
// mac_entry.m) rather than windowless/off-screen — that part needed no change.
// What T0/T1 left as a placeholder was the HOST WINDOW itself: a plain ad hoc
// NSWindow opened directly in mac_entry.m (cefspike_create_window), noted there
// as "T2 formalizes this into Zapp's NSWindow shape in host.m." This file is
// that formalization; mac_entry.m's placeholder is removed.
//
// Shape mirrors native/platform/darwin/window.m's darwin_window_create for the
// BASICS the brief asks for — titled/closable/miniaturizable/resizable
// NSWindow, setReleasedWhenClosed:NO, windowBackgroundColor pre-paint (avoids
// a white flash before the browser's first paint), standard traffic lights,
// auto-center — WITHOUT importing that module or its sidebar/inspector/
// vibrancy/toolbar machinery (out of scope for this hosting-fit spike; the
// brief explicitly allows mirroring the shape rather than pulling in the whole
// module).
//
// Ordering (load-bearing, do not invert): the window + its contentView MUST
// exist before the CEF browser is created into it — cef_window_info_t.parent_view
// is read at cef_browser_host_create_browser time and CEF parents its NSView
// onto whatever we hand it right then. main.nim's call sequence enforces this:
// cefspike_make_host_window -> cefspike_host_view_for_window -> cefspike_make_window_info
// (captures parent_view) -> cef_browser_host_create_browser.
//
// Resize: CEF's own Mac windowed-browser implementation gives its browser NSView
// an NSViewWidthSizable|NSViewHeightSizable autoresizing mask so it tracks
// parent_view's frame. Our content view (parent_view) carries the same mask
// relative to the window, so classic springs-and-struts autoresizing chains
// window resize -> content view -> CEF's browser view. No CEF resize call is
// needed from our side.

#import <Cocoa/Cocoa.h>

#include "cef_spike.h"

// Strong static ref — keeps the window (and its contentView, CEF's
// parent_view) alive for the process lifetime. Single-window spike; a real
// integration would key this off a window registry (see window.m's
// zapp_webviews[] dispatch table) instead of one static.
static NSWindow* g_host_window = nil;

void* cefspike_make_host_window(int width, int height, const char* title) {
  NSRect frame = NSMakeRect(0, 0, width, height);
  NSWindow* window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskMiniaturizable |
                           NSWindowStyleMaskResizable)
                  backing:NSBackingStoreBuffered
                    defer:NO];

  // Mirror window.m's darwin_window_create: the NSWindow object survives a
  // close() rather than being deallocated (not exercised by this
  // single-browser spike, but the correct Zapp-shaped default).
  [window setReleasedWhenClosed:NO];

  // Paint the host dark-or-light correctly before the CEF browser's first
  // paint lands — same rationale as window.m: without this a brand-new
  // NSWindow flashes its default backing on a dark-mode launch.
  [window setBackgroundColor:[NSColor windowBackgroundColor]];

  NSString* titleStr = title ? [NSString stringWithUTF8String:title] : nil;
  [window setTitle:titleStr ?: @"Zapp"];

  // Standard traffic lights (close/miniaturize/zoom): all three enabled +
  // visible is the styleMask default above — the "reasonable default" the
  // brief asks for, no per-button overrides needed for this spike.

  [window center];

  // Content view: this becomes cef_window_info_t.parent_view. Sized to the
  // window and set to track its resizes (see the resize note up top).
  NSView* content = [[NSView alloc] initWithFrame:frame];
  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  window.contentView = content;

  [window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];

  g_host_window = window;  // strong ref keeps window + content view alive
  return (__bridge void*)window;
}

void* cefspike_host_view_for_window(void* window) {
  NSWindow* win = (__bridge NSWindow*)window;
  if (!win) return NULL;
  return (__bridge void*)win.contentView;
}
