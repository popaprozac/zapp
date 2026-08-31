import WebKit from "WebKit/WebKit.h";
import { CapabilitySelection } from "../../application-capabilities.zs";
import { PendingRequests } from "../../pending-requests.zs";
import objc from "std/objc";
import { thread } from "std/thread";

internal class MacOSWindowRuntime on thread.main {
  readonly id: String;
  readonly nativeId: i32;
  readonly window: WebKit.NSWindow;
  readonly webView: WebKit.WKWebView;
  readonly contentController: WebKit.WKUserContentController;
  readonly configuration: WebKit.WKWebViewConfiguration;
  readonly schemeHandler: objc.Adapter<WebKit.WKURLSchemeHandler>;
  readonly navigationDelegate: objc.Adapter<WebKit.WKNavigationDelegate>;
  readonly windowDelegate: objc.Adapter<WebKit.NSWindowDelegate>;
  readonly registration: objc.Registration;
  readonly pendingRequests: PendingRequests;
  readonly capabilitySelection: CapabilitySelection;
}
