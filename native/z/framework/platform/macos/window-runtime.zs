import native from "zapp_desktop.h";
import WebKit from "WebKit/WebKit.h";
import { CapabilitySelection } from "../../application-capabilities.zs";
import { PendingRequests } from "../../pending-requests.zs";
import objc from "std/objc";
import { thread } from "std/thread";

internal class MacOSWindowRuntime on thread.main {
  readonly id: String;
  readonly nativeId: i32;
  readonly window: native.NSWindow;
  readonly webView: native.WKWebView;
  readonly contentController: native.WKUserContentController;
  readonly configuration: native.WKWebViewConfiguration;
  readonly schemeHandler: objc.Adapter<WebKit.WKURLSchemeHandler>;
  readonly navigationDelegate: objc.Adapter<WebKit.WKNavigationDelegate>;
  readonly windowDelegate: objc.Adapter<native.NSWindowDelegate>;
  readonly registration: objc.Registration;
  readonly pendingRequests: PendingRequests;
  readonly capabilitySelection: CapabilitySelection;
}
