import WebKit from "WebKit/WebKit.h";
import objc from "std/objc";
import { thread } from "std/thread";
import { BridgeDocument } from "../../bridge-document.zs";
import { RelatedDocumentIdentity } from "../../related-documents.zs";
import { DesktopRouteMessageOperation, requestBridgeDocumentBinding } from "./document-transport.zs";
import { DesktopMessageHandler } from "./message-handler.zs";
import { macOSWindowFrame } from "./window-geometry.zs";
import { MacOSWindow } from "./window-resize.zs";
import { installWebViewScripts } from "./webview-injections.zs";
import { WindowManager } from "../../window.zs";
import { MacOSWindowRuntime } from "./window-runtime.zs";
import { createDesktopWindowDelegate, NativeWindowClosedOperation } from "./window-delegate.zs";
import { observeWindowPresentation } from "./window-presentation.zs";

internal type RelatedNativeFailure = () => void on thread.main;

class RelatedNavigation on thread.main implements WebKit.WKNavigationDelegate {
  readonly view: WebKit.WKWebView;
  readonly address: String;
  readonly document: BridgeDocument;
  readonly failed: RelatedNativeFailure;

  function policy(
    in view: WebKit.WKWebView,
    in action: WebKit.WKNavigationAction,
    in decide: (policy: WebKit.WKNavigationActionPolicy) => void
  ): void as "webView:decidePolicyForNavigationAction:decisionHandler:" {
    const target = action.targetFrame;
    const url = action.request.URL;
    let allowed = false;
    if (view == this.view && target != null && target.mainFrame && url != null) {
      const absolute = url.absoluteString;
      if (absolute != null) {
        const address: String = absolute;
        allowed = address == this.address;
      }
    }
    decide(allowed ? WebKit.WKNavigationActionPolicyAllow : WebKit.WKNavigationActionPolicyCancel);
    if (!allowed) this.failed();
  }

  function commit(inout this, in view: WebKit.WKWebView, in navigation: WebKit.WKNavigation | null): void as "webView:didCommitNavigation:" {
    if (view != this.view) return;
    this.document.didCommit();
    match (this.document.creationIdentity()) {
      some(_) => requestBridgeDocumentBinding(in view);
      none => this.failed();
    }
  }

  function failedBeforeCommit(in view: WebKit.WKWebView, in navigation: WebKit.WKNavigation | null,
    in error: WebKit.NSError): void as "webView:didFailProvisionalNavigation:withError:" {
    if (view == this.view) this.failed();
  }
  function failedAfterCommit(in view: WebKit.WKWebView, in navigation: WebKit.WKNavigation | null,
    in error: WebKit.NSError): void as "webView:didFailNavigation:withError:" {
    if (view == this.view) this.failed();
  }
  function terminated(inout this, in view: WebKit.WKWebView): void as "webViewWebContentProcessDidTerminate:" {
    if (view != this.view) return;
    this.document.retire();
    this.failed();
  }
}

class RelatedUI on thread.main implements WebKit.WKUIDelegate {
  readonly view: WebKit.WKWebView;
  readonly window: MacOSWindow;
  function closed(inout this, in view: WebKit.WKWebView): void as "webViewDidClose:" {
    // DOM close is already committed, not a second cancellable close request.
    if (view == this.view) this.window.close();
  }
}

// The caller must already have claimed a creation reservation against the
// actual sending WebView/frame/origin. WebKit owns navigation of the returned
// view: do not allocate a replacement configuration or call loadRequest here.
internal function createMacOSRelatedWindowRuntime(
  configuration: WebKit.WKWebViewConfiguration,
  document: BridgeDocument,
  id: String,
  address: String,
  title: String,
  width: u32,
  height: u32,
  route: DesktopRouteMessageOperation,
  failed: RelatedNativeFailure,
  closed: NativeWindowClosedOperation,
  windows: Weak<WindowManager>
): MacOSWindowRuntime throws String on thread.main {
  const controller = WebKit.WKUserContentController.alloc().init();
  configuration.userContentController = controller;
  const inject = Array<String>();
  try installWebViewScripts(controller, in id, in inject);
  const frame = macOSWindowFrame(width, height);
  const view = WebKit.WKWebView.alloc().initWithFrame(frame, configuration: configuration);
  const handler = new DesktopMessageHandler({ document, expectedView: view,
    expectedController: controller, routeMessage: route });
  const registration = objc.register({
    add: controller.addScriptMessageHandler(handler, "zapp"),
    remove: controller.removeScriptMessageHandlerForName("zapp"),
  });
  const window = new MacOSWindow(frame, WebKit.NSWindowStyleMaskTitled
    | WebKit.NSWindowStyleMaskClosable | WebKit.NSWindowStyleMaskResizable
    | WebKit.NSWindowStyleMaskMiniaturizable);
  window.title = move title;
  window.contentView = view;
  const navigationController = new RelatedNavigation({ view, address, document, failed });
  const uiController = new RelatedUI({ view, window });
  const navigation = objc.adapt<WebKit.WKNavigationDelegate>(navigationController);
  const ui = objc.adapt<WebKit.WKUIDelegate>(uiController);
  const delegate = createDesktopWindowDelegate(copy id, document.windowId, window, view, windows, closed);
  const presentationObserver = observeWindowPresentation(copy id, window, view, windows);
  view.navigationDelegate = navigation;
  view.UIDelegate = ui;
  window.delegate = delegate;
  // The creation coordinator retains this graph before exposing the WebView.
  // Presentation waits for the acknowledged child activation.
  return new MacOSWindowRuntime({ id, nativeId: document.windowId, window, webView: view,
    contentController: controller, configuration, document, schemeHandler: Option.none,
    navigationDelegate: navigation, uiDelegate: ui, windowDelegate: delegate,
    presentationObserver, registration, capabilitySelection: document.capabilities });
}
