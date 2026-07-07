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
#include "include/capi/cef_values_capi.h"

// --- Doc-start carrier + bootstrap sources (the SAME native functions
// webview.m's WKUserScript block reads — see webview.m ~904-994). Reused here
// so the CEF page gets a byte-equivalent doc-start environment: config carrier,
// bindings manifest, owner/window ids, and the real compiled bootstrap. All are
// {.exportc.} / build-config C symbols in the MAIN binary, which this TU links
// into (the Helper, which can't call any of these, receives the finished string
// via extra_info). ---
extern const char* zapp_webview_bootstrap_script(void);
extern const char* permissions_bootstrap_json(void);
extern const char* service_get_manifest_json(void);
extern const char* darwin_get_theme(void);
extern const char* darwin_get_power_state(void);
extern const char* zapp_form_factor(void);
extern const char* zapp_build_csp(void);
extern int zapp_build_is_dev(void);
extern const char* app_get_bootstrap_name(void);
extern bool app_get_bootstrap_web_content_inspectable(void);
extern bool app_get_bootstrap_application_should_terminate_after_last_window_closed(void);
extern int app_get_bootstrap_max_workers(void);

// extra_info key carrying the doc-start bootstrap JS (must match
// zapp_cef_bridge.c's ZAPP_EXTRA_BOOTSTRAP_KEY).
#define ZAPP_CEF_EXTRA_BOOTSTRAP_KEY "zappBootstrap"

// Single-pass JS string escape (mirrors webview.m's zapp_escape_js_string):
// escapes backslash, single-quote, and the two line terminators — enough for
// splicing a value into a JS single-quoted literal. NULL/empty -> @"".
static NSString* zapp_cef_js_escape(const char* raw) {
  if (!raw || raw[0] == '\0') return @"";
  size_t len = strlen(raw);
  char* buf = (char*)malloc(len * 2 + 1);
  if (!buf) return @"";
  size_t j = 0;
  for (size_t i = 0; i < len; i++) {
    switch (raw[i]) {
      case '\\': buf[j++] = '\\'; buf[j++] = '\\'; break;
      case '\'': buf[j++] = '\\'; buf[j++] = '\''; break;
      case '\n': buf[j++] = '\\'; buf[j++] = 'n'; break;
      case '\r': buf[j++] = '\\'; buf[j++] = 'r'; break;
      default: buf[j++] = raw[i]; break;
    }
  }
  buf[j] = '\0';
  NSString* result = [NSString stringWithUTF8String:buf];
  free(buf);
  return result;
}

// Build the doc-start JS string CEF's render process evals in on_context_created
// (via extra_info). Three parts, in order:
//   1. webkit.messageHandlers.zapp shim -> __zappSendNative (so the UNMODIFIED
//      bootstrap/webview.ts post() reaches native on CEF, keeping the WKWebView
//      bootstrap byte-identical).
//   2. the Symbol.for('zapp.*') carriers (bootstrapConfig / bindingsManifest /
//      ownerId / windowId) — same shape as webview.m's WKUserScript carriers.
//   3. the real compiled bootstrap (zapp_webview_bootstrap_script()).
// Returns a malloc'd C string (caller frees).
static char* zapp_cef_build_bootstrap_js(const char* window_id,
                                         const char* owner_id) {
  NSMutableString* js = [NSMutableString string];

  // 1. Transport shim. The runtime's post() checks
  // window.webkit?.messageHandlers?.zapp first (macOS); provide it so no
  // change to bootstrap/webview.ts is needed. __zappSendNative is bound by the
  // render V8 handler BEFORE this eval runs (zapp_cef_bridge.c).
  [js appendString:
      @"(function(){var g=(typeof window!=='undefined')?window:globalThis;"
      @"g.webkit=g.webkit||{};g.webkit.messageHandlers=g.webkit.messageHandlers||{};"
      @"g.webkit.messageHandlers.zapp={postMessage:function(m){__zappSendNative(String(m));}};"
      @"})();\n"];

  // 2a. bootstrapConfig — mirrors webview.m's configScript field-for-field.
  NSString* appNameC = app_get_bootstrap_name()
                           ? zapp_cef_js_escape(app_get_bootstrap_name())
                           : @"Zapp";
  BOOL terminate =
      app_get_bootstrap_application_should_terminate_after_last_window_closed();
  BOOL inspect = app_get_bootstrap_web_content_inspectable();
  int maxWorkers = app_get_bootstrap_max_workers();
  const char* themeC = darwin_get_theme();
  const char* powerStateC = darwin_get_power_state();
  if (!powerStateC || !powerStateC[0]) powerStateC = "null";
  const char* formFactorC = zapp_form_factor();
  const char* permsC = permissions_bootstrap_json();
  if (!permsC || !permsC[0])
    permsC = "{\"platform\":\"macos\",\"active\":false,\"allow\":[]}";
  NSString* cspExtra = @"";
  const char* cspRaw = zapp_build_csp();
  if (cspRaw && cspRaw[0] != '\0') {
    cspExtra = [NSString stringWithFormat:@",csp:'%@'",
                                          zapp_cef_js_escape(cspRaw)];
  }
  [js appendFormat:
      @"(function(){globalThis[Symbol.for('zapp.bootstrapConfig')]="
      @"{name:'%@',applicationShouldTerminateAfterLastWindowClosed:%@,"
      @"webContentInspectable:%@,maxWorkers:%d,theme:'%s',powerState:%s,"
      @"formFactor:'%s',env:'%s',permissions:%s%@};})();\n",
      appNameC,
      terminate ? @"true" : @"false",
      inspect ? @"true" : @"false",
      maxWorkers,
      themeC ? themeC : "light",
      powerStateC,
      formFactorC ? formFactorC : "desktop",
      zapp_build_is_dev() ? "dev" : "prod",
      permsC, cspExtra];

  // 2b. bindingsManifest.
  NSString* bindingsJson = zapp_cef_js_escape(service_get_manifest_json());
  [js appendFormat:
      @"(function(){globalThis[Symbol.for('zapp.bindingsManifest')]='%@';})();\n",
      bindingsJson];

  // 2c. owner + window ids.
  if (owner_id && owner_id[0] != '\0') {
    [js appendFormat:
        @"(function(){globalThis[Symbol.for('zapp.ownerId')]='%@';})();\n",
        zapp_cef_js_escape(owner_id)];
  }
  if (window_id && window_id[0] != '\0') {
    [js appendFormat:
        @"(function(){globalThis[Symbol.for('zapp.windowId')]='%@';})();\n",
        zapp_cef_js_escape(window_id)];
  }

  // 3. The real compiled bootstrap (bootstrap/webview.ts).
  const char* bootstrap = zapp_webview_bootstrap_script();
  if (bootstrap && bootstrap[0] != '\0') {
    [js appendString:[NSString stringWithUTF8String:bootstrap]];
  }

  return strdup([js UTF8String]);
}

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

void zapp_cef_create_browser_in_view(void* parent_view, const char* url,
                                     int32_t window_slot, const char* window_id,
                                     const char* owner_id) {
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
  cef_client_t* client = zapp_cef_client_create(window_slot);
  cef_string_t* cef_url =
      zapp_cef_make_cef_string((url && url[0] != '\0') ? url
                                                        : "zapp://index.html");
  cef_browser_settings_t* browser_settings = zapp_cef_make_browser_settings();

  // Build the doc-start bootstrap here (browser process — it can reach the
  // native carrier sources + the compiled bootstrap) and hand it to the render
  // process via extra_info -> on_browser_created (zapp_cef_bridge.c). The
  // Helper runs no Nim, so this is the ONLY way it gets the carriers/bootstrap.
  char* bootstrap_js = zapp_cef_build_bootstrap_js(window_id, owner_id);
  cef_dictionary_value_t* extra_info = cef_dictionary_value_create();
  if (bootstrap_js != NULL && extra_info != NULL) {
    cef_string_t key, val;
    memset(&key, 0, sizeof(key));
    memset(&val, 0, sizeof(val));
    cef_string_utf8_to_utf16(ZAPP_CEF_EXTRA_BOOTSTRAP_KEY,
                             strlen(ZAPP_CEF_EXTRA_BOOTSTRAP_KEY), &key);
    cef_string_utf8_to_utf16(bootstrap_js, strlen(bootstrap_js), &val);
    // set_string COPIES both key + value (const cef_string_t*) — it does NOT
    // consume the dict; we free our own bootstrap_js after.
    extra_info->set_string(extra_info, &key, &val);
    cef_string_clear(&key);
    cef_string_clear(&val);
  }
  free(bootstrap_js);

  // Fire-and-forget: cef_browser_host_create_browser is CEF's ASYNCHRONOUS
  // creation entry (returns a bool indicating the request was accepted, not
  // a browser*). The browser itself becomes available once the life-span
  // handler's on_after_created fires (zapp_cef_client.c registers it in
  // zapp_cef_browsers[window_slot] — see zapp_cef_browser_for_slot()).
  //
  // REFCOUNT: |client| and |extra_info| are refptr_same params — create_browser
  // CONSUMES them (each created with ref=1, ownership transferred to CEF). Do
  // NOT release either afterward (same Unwrap-consumed rule the bridge follows
  // for send_process_message).
  cef_browser_host_create_browser(window_info, client, cef_url,
                                  browser_settings, extra_info, NULL);
}

// ---------------------------------------------------------------------------
// TASK 2 (Electrobun teardown) — graceful CEF browser teardown on host-window
// close. This lives in zapp_cef_host.m because it needs BOTH the CEF C-API
// (get_host / close_browser / get_window_handle) AND ObjC/NSView + libdispatch.
//
// Root cause it fixes: Zapp creates a SetAsChild Alloy browser
// (CEF_RUNTIME_STYLE_ALLOY, parent_view == the window's contentView — see
// zapp_cef_make_window_info) and Zapp NSWindows are setReleasedWhenClosed:NO,
// so [window close] only HIDES the window. The browser's NSView stays in the
// hidden view hierarchy, CEF never finishes destroying the browser, and
// on_before_close is deferred all the way to cef_shutdown — the owned ref +
// zapp_cef_browsers[] slot leak.
//
// The fix (Electrobun's CEFWebViewImpl remove, nativeWrapper.mm): after
// CloseBrowser(false), REMOVE the browser's NSView from its superview on a
// later main-thread turn. That lets CEF finish the teardown -> on_before_close
// fires -> zapp_cef_client.c deregisters the slot + releases the owned ref.
// No defer machinery, no re-entrant windowShouldClose: dance.
//
// Idempotent: no-op if |slot| has no live browser (already closed / out of
// range), which is what makes the darwin_window_destroy safety-net call harmless.
void zapp_cef_teardown_browser_for_slot(int32_t slot) {
  extern cef_browser_t* zapp_cef_browser_for_slot(int32_t slot);
  cef_browser_t* b = zapp_cef_browser_for_slot(slot);
  if (b == NULL) return;  // already closed / never registered — no-op.
  cef_browser_host_t* host = b->get_host(b);  // owned ref
  if (host == NULL) return;
  // Capture the browser's NSView BEFORE closing. For a SetAsChild Alloy browser
  // (NOT wrapped in a cef_browser_view_t — has_view() == 0) get_window_handle
  // returns the CEF-created NSView, a direct subview of the parent contentView
  // handed to zapp_cef_make_window_info. This is exactly the view Electrobun
  // removes.
  cef_window_handle_t handle = host->get_window_handle(host);
  NSView* view = handle ? (__bridge NSView*)(void*)handle : nil;
  fprintf(stderr, "[zapp-cef] teardown_browser (slot %d) handle=%s\n", slot,
          view != nil ? "view" : "NULL");
  host->close_browser(host, /*force_close=*/0);
  host->base.release(&host->base);
  // Electrobun pattern: the DELAYED removeFromSuperview is what lets CEF finish
  // destroying the browser -> on_before_close fires. The block strongly captures
  // |view| under ARC, so it stays alive until the removal runs even if the close
  // races. close_browser is async and does not remove the view synchronously.
  if (view != nil) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (view.superview != nil) [view removeFromSuperview];
    });
  } else {
    // Should not happen for a SetAsChild Alloy browser; if it ever does, the
    // documented fallback is to remove CEF's subview(s) of the parent
    // contentView. Logged so the interactive-close gate surfaces it.
    fprintf(stderr,
            "[zapp-cef] teardown_browser (slot %d): get_window_handle NULL — "
            "on_before_close may not fire; subview fallback needed\n",
            slot);
  }
}
