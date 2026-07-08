// Engine-aware DevTools show/close router surface (D sub-cycle Task 1).
//
// Reverse of the WK inspector's system-provided path: DevTools on CEF needs
// an explicit trigger (there is no equivalent of macOS's system Develop menu
// / right-click Inspect Element for a CEF-hosted webview). CEF opens/closes
// real Chromium DevTools; WK no-ops (its inspector stays reachable via the
// system UI, unaffected by this file).
//
// This file compiles for BOTH engines — it is registered in the SHARED
// darwin source list (cli/src/native.ts's getPlatformSources), not the
// CEF-only source list (cli/src/build-config.ts's renderCefPlatformNim) —
// exactly like window.m's/toolbar.m's `#ifdef ZAPP_HAS_CEF` engine-branch
// convention. ZAPP_HAS_CEF is a GLOBAL passC define emitted ONLY when
// webEngine:"chromium" is configured (renderCefPlatformNim), reaching every
// C/ObjC translation unit the Nim build compiles (including this new one) —
// so a `system` (WKWebView) build never defines it and the CEF branch below
// compiles out entirely, leaving this TU with no `cef_*` type or
// `zapp_cef_*` symbol reference whatsoever.
//
// The CEF branch forward-declares `cef_browser_t` as an OPAQUE type (rather
// than #include-ing zapp_cef.h, which pulls in the full CEF SDK header set)
// — this file only tests zapp_cef_browser_for_slot's result for NULL and
// never dereferences it, so the incomplete type is sufficient. Mirrors
// platform.m's "stay CEF-header-free" convention for cross-file CEF externs.

#include <stdint.h>
#include <stdio.h>

#ifdef ZAPP_HAS_CEF
typedef struct _cef_browser_t cef_browser_t;  // opaque — see file header
extern cef_browser_t* zapp_cef_browser_for_slot(int32_t slot);
extern void zapp_cef_show_dev_tools(int32_t slot);
extern void zapp_cef_close_dev_tools(int32_t slot);
#endif

void darwin_devtools_open(int32_t window_id) {
#ifdef ZAPP_HAS_CEF
  if (zapp_cef_browser_for_slot(window_id) != NULL) {
    zapp_cef_show_dev_tools(window_id);
    return;
  }
#endif
  fprintf(stderr,
          "[zapp] devtools:open on a WKWebView window (slot %d) — use the "
          "system Develop menu / right-click Inspect Element.\n",
          window_id);
}

void darwin_devtools_close(int32_t window_id) {
#ifdef ZAPP_HAS_CEF
  if (zapp_cef_browser_for_slot(window_id) != NULL) {
    zapp_cef_close_dev_tools(window_id);
    return;
  }
#endif
  (void)window_id;  // WK: no-op — DevTools close is the system Develop menu's job.
}
