import WebKit from "WebKit/WebKit.h";
import { thread } from "std/thread";

// Editor-safe production default. Smoke builds replace this staged module with
// enabled hooks into the native test harness.
internal function configuredMacOSApplicationSmokeMode(): boolean {
  return false;
}

internal function startConfiguredWindowSmokeSupport(
  in windowId: String,
  nativeId: i32,
  in webView: WebKit.WKWebView,
  in contentController: WebKit.WKUserContentController
): void on thread.main {}

internal function observeConfiguredWebViewResponse(
  in webView: WebKit.WKWebView,
  nativeId: i32,
  activeWindowCount: usize,
  in payload: String,
  requestId: u64,
  development: boolean,
  ok: boolean
): void {}
