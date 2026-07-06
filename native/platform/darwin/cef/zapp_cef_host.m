// Zapp CEF host (macOS) — host the CEF browser inside a native macOS view,
// proving/serving hosting-fit for webEngine:"chromium".
//
// Promoted from the proven GO spike (`spikes/cef-macos/host.m` — see
// docs/superpowers/specs/2026-07-05-cef-webengine-production-slice-macos-
// design.md and spikes/cef-macos/FINDINGS.md, Task 2). Renamed cefspike_ ->
// zapp_cef_, "spike" dropped. The browser is created WINDOWED
// (cef_window_info_t.parent_view set to an NSView, Alloy runtime_style — see
// zapp_cef_make_window_info in zapp_cef_mac_entry.m), not windowless/
// off-screen.
//
// This file has two halves:
//
//   1. zapp_cef_make_host_window / zapp_cef_host_view_for_window — the
//      spike's STANDALONE-window helpers (titled/closable/miniaturizable/
//      resizable NSWindow, setReleasedWhenClosed:NO, windowBackgroundColor
//      pre-paint to avoid a white flash before the browser's first paint,
//      standard traffic lights, auto-center — mirrors
//      native/platform/darwin/window.m's darwin_window_create's BASICS
//      without importing that module or its sidebar/inspector/vibrancy/
//      toolbar machinery). Kept for parity with the spike / for any future
//      standalone debug harness; NOT the path production hosting uses.
//
//   2. zapp_cef_create_browser_in_view — the NEW production entry point (T1
//      of the production slice) T3 will call from the real window-creation
//      branch. Unlike (1), it takes an NSView the CALLER already owns (Zapp's
//      own window/webview content view — see
//      native/platform/darwin/window.m) and hosts the CEF browser INSIDE it
//      rather than creating a new NSWindow. See zapp_cef.h's doc comment on
//      this function for the full contract.
//
// Ordering (load-bearing, do not invert): for (1), the window + its
// contentView MUST exist before the CEF browser is created into it —
// cef_window_info_t.parent_view is read at cef_browser_host_create_browser
// time and CEF parents its NSView onto whatever we hand it right then. For
// (2), the caller's NSView must already be part of a shown window before
// calling zapp_cef_create_browser_in_view for the same reason.
//
// Resize: CEF's own Mac windowed-browser implementation gives its browser
// NSView an NSViewWidthSizable|NSViewHeightSizable autoresizing mask so it
// tracks parent_view's frame. As long as the parent view carries a
// compatible autoresizing/constraint setup relative to ITS superview, classic
// springs-and-struts (or Auto Layout) resizing chains through to CEF's
// browser view with no explicit CEF-side resize call needed.

#import <Cocoa/Cocoa.h>

#include "zapp_cef.h"

// Strong static ref — keeps the standalone host window (and its contentView,
// CEF's parent_view) alive for the process lifetime. Single-window helper; a
// real integration keys this off Zapp's own window registry instead (see
// window.m's zapp_webviews[] dispatch table) — not needed by
// zapp_cef_create_browser_in_view below, whose parent view is owned/kept
// alive by the CALLER.
static NSWindow* g_host_window = nil;

void* zapp_cef_make_host_window(int width, int height, const char* title) {
  NSRect frame = NSMakeRect(0, 0, width, height);
  NSWindow* window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskMiniaturizable |
                           NSWindowStyleMaskResizable)
                  backing:NSBackingStoreBuffered
                    defer:NO];

  // Mirror window.m's darwin_window_create: the NSWindow object survives a
  // close() rather than being deallocated.
  [window setReleasedWhenClosed:NO];

  // Paint the host dark-or-light correctly before the CEF browser's first
  // paint lands — same rationale as window.m: without this a brand-new
  // NSWindow flashes its default backing on a dark-mode launch.
  [window setBackgroundColor:[NSColor windowBackgroundColor]];

  NSString* titleStr = title ? [NSString stringWithUTF8String:title] : nil;
  [window setTitle:titleStr ?: @"Zapp"];

  // Standard traffic lights (close/miniaturize/zoom): all three enabled +
  // visible is the styleMask default above.

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

void* zapp_cef_host_view_for_window(void* window) {
  NSWindow* win = (__bridge NSWindow*)window;
  if (!win) return NULL;
  return (__bridge void*)win.contentView;
}

// ---------------------------------------------------------------------------
// Production entry point — see zapp_cef.h for the full contract.
// ---------------------------------------------------------------------------

void zapp_cef_create_browser_in_view(void* parent_view, const char* url) {
  NSView* parent = (__bridge NSView*)parent_view;
  if (!parent) {
    fprintf(stderr,
            "[zapp-cef] create_browser_in_view: NULL parent view\n");
    return;
  }

  NSRect bounds = parent.bounds;
  int width = (int)bounds.size.width;
  int height = (int)bounds.size.height;

  // parent_view is read by CEF at cef_browser_host_create_browser time (it
  // does not retain the NSView itself beyond that call — CEF's own browser
  // NSView is inserted as a subview and tracks |parent|'s frame via the
  // width/height-sizable autoresizing mask CEF sets on it, per the file
  // header's resize note). The CALLER (T3) is responsible for keeping
  // |parent| alive — this function does not take its own strong ref, unlike
  // zapp_cef_make_host_window's standalone-window path above, since |parent|
  // is presumed to already be owned by Zapp's window/webview registry.
  cef_window_info_t* window_info =
      zapp_cef_make_window_info((__bridge void*)parent, width, height);
  cef_client_t* client = zapp_cef_client_create();
  cef_string_t* cef_url =
      zapp_cef_make_cef_string((url && url[0] != '\0') ? url
                                                        : "zapp://index.html");
  cef_browser_settings_t* browser_settings = zapp_cef_make_browser_settings();

  // Fire-and-forget: cef_browser_host_create_browser is CEF's ASYNCHRONOUS
  // creation entry (returns a bool indicating the request was accepted, not
  // a browser*). The browser itself becomes available once the life-span
  // handler's on_after_created fires (zapp_cef_client.c retains it —
  // zapp_cef_get_active_browser()).
  cef_browser_host_create_browser(window_info, client, cef_url,
                                  browser_settings, NULL, NULL);
}
