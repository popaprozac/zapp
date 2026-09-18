import WebKit from "WebKit/WebKit.h";
import { CapabilitySelection } from "../../application-capabilities.zs";
import { BridgeDocument } from "../../bridge-document.zs";
import objc from "std/objc";
import { thread } from "std/thread";
import { WindowPresentationObserver } from "./window-presentation.zs";
import { MacOSWindowGestures } from "./window-drag.zs";
import { MacOSWindow } from "./window-resize.zs";
import { MacOSFileDrops } from "./file-drops.zs";

internal class MacOSWindowRuntime on thread.main {
  readonly id: String;
  readonly nativeId: i32;
  readonly window: MacOSWindow;
  readonly webView: WebKit.WKWebView;
  readonly contentController: WebKit.WKUserContentController;
  readonly configuration: WebKit.WKWebViewConfiguration;
  // Ordinary windows own the adapter; WebKit-provided related configurations
  // already retain their inherited native scheme handler.
  readonly schemeHandler: Option<objc.Adapter<WebKit.WKURLSchemeHandler>>;
  readonly navigationDelegate: objc.Adapter<WebKit.WKNavigationDelegate>;
  readonly uiDelegate: objc.Adapter<WebKit.WKUIDelegate>;
  readonly windowDelegate: objc.Adapter<WebKit.NSWindowDelegate>;
  readonly presentationObserver: WindowPresentationObserver;
  readonly gestures: MacOSWindowGestures;
  readonly fileDrops: Option<MacOSFileDrops>;
  readonly registration: objc.Registration;
  readonly document: BridgeDocument;
  readonly capabilitySelection: CapabilitySelection;

  deinit {
    // Routing has already been revoked. Clear non-owning native delegate
    // slots before releasing their owned adapters and the content graph.
    // Generated protocol/subclass entries pin in-flight receivers through
    // reentrant close, allowing related runtimes to be reclaimed promptly.
    this.webView.navigationDelegate = null;
    this.webView.UIDelegate = null;
    this.window.delegate = null;
    this.webView.stopLoading();
  }
}
