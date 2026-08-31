import native from "zapp_desktop.h";
import { thread } from "std/thread";

// Editor-safe production default. Smoke builds replace this staged module with
// enabled hooks into the native test harness.
internal function configuredMacOSApplicationSmokeMode(): boolean {
  return false;
}

internal function startConfiguredWindowSmokeSupport(
  in windowId: String,
  nativeId: i32,
  in webView: native.WKWebView,
  in contentController: native.WKUserContentController
): void on thread.main {}

internal function observeConfiguredWebViewResponse(
  in webView: native.WKWebView,
  nativeId: i32,
  activeWindowCount: usize,
  in payload: String,
  requestId: u64,
  development: boolean,
  ok: boolean
): void {}
