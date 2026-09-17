import WebKit from "WebKit/WebKit.h";
import objc from "std/objc";
import { thread } from "std/thread";
import { MacOSWindowStateObserver } from "./window-state.zs";
import { BridgeDocument } from "../../bridge-document.zs";
import { RelatedDocumentIdentity } from "../../related-documents.zs";
import { DesktopRouteMessageOperation, requestBridgeDocumentBinding } from "./document-transport.zs";
import { DesktopMessageHandler } from "./message-handler.zs";
import { macOSWindowFrame } from "./window-geometry.zs";
import { MacOSWindow } from "./window-resize.zs";
import { MacOSWindowGestures } from "./window-drag.zs";
import { TitleBarOptions } from "../../window-titlebar.zs";
import { macOSTitleBarStyleMask, applyMacOSTitleBar } from "./window-titlebar.zs";
import { applyMacOSWindowPolicy } from "./window-policy.zs";
import { installWindowChrome } from "./window-chrome.zs";
import { installWebViewScripts } from "./webview-injections.zs";
import { WindowManager } from "../../window.zs";
import { MacOSWindowRuntime } from "./window-runtime.zs";
import { createDesktopWindowDelegate, NativeWindowClosedOperation } from "./window-delegate.zs";
import { observeWindowPresentation } from "./window-presentation.zs";
import { MacOSWebView } from "./webview.zs";
import { configuredFrontendIsDevelopment, configureWebViewDeveloperExtras } from "./configured-webview.zs";

internal type RelatedNativeFailure = () => void on thread.main;
internal type RelatedNativeAllowsCreation = (in view: WebKit.WKWebView, in action: WebKit.WKNavigationAction) => boolean on thread.main;
internal type RelatedNativeCreateChild = (in view: WebKit.WKWebView, configuration: WebKit.WKWebViewConfiguration,
  in action: WebKit.WKNavigationAction) => WebKit.WKWebView | null on thread.main;

class RelatedNavigation on thread.main implements WebKit.WKNavigationDelegate {
  readonly view: WebKit.WKWebView;
  readonly address: String;
  readonly document: BridgeDocument;
  readonly failed: RelatedNativeFailure;
  readonly allowsCreation: RelatedNativeAllowsCreation;

  function policy(
    in view: WebKit.WKWebView,
    in action: WebKit.WKNavigationAction,
    in decide: (policy: WebKit.WKNavigationActionPolicy) => void
  ): void as "webView:decidePolicyForNavigationAction:decisionHandler:" {
    const target = action.targetFrame;
    if (target == null) {
      // Popup refusal is not navigation/replacement of this document. A nested
      // child still needs the same authenticated one-shot gate as a root child.
      const allowed = view == this.view && this.allowsCreation(in view, in action);
      decide(allowed ? WebKit.WKNavigationActionPolicyAllow : WebKit.WKNavigationActionPolicyCancel);
      return;
    }
    const url = action.request.URL;
    let allowed = false;
    if (view == this.view && target.mainFrame && url != null) {
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
  readonly createChild: RelatedNativeCreateChild;
  function create(in view: WebKit.WKWebView, in configuration: WebKit.WKWebViewConfiguration,
    in action: WebKit.WKNavigationAction, in features: WebKit.WKWindowFeatures
  ): WebKit.WKWebView | null as "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:" {
    if (view != this.view) return null;
    return this.createChild(in view, configuration, in action);
  }
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
  titleBar: TitleBarOptions,
  resizable: boolean,
  maximizable: boolean,
  fullscreenable: boolean,
  inspectable: boolean,
  route: DesktopRouteMessageOperation,
  failed: RelatedNativeFailure,
  closed: NativeWindowClosedOperation,
  allowsCreation: RelatedNativeAllowsCreation,
  createChild: RelatedNativeCreateChild,
  windows: Weak<WindowManager>
): MacOSWindowRuntime throws String on thread.main {
  const controller = WebKit.WKUserContentController.alloc().init();
  configuration.userContentController = controller;
  const inject = Array<String>();
  try installWebViewScripts(controller, in id, in inject);
  const frame = macOSWindowFrame(width, height);
  configureWebViewDeveloperExtras(in configuration, inspectable);
  const view = new MacOSWebView(frame, configuration, configuredFrontendIsDevelopment());
  view.inspectable = inspectable;
  const handler = new DesktopMessageHandler({ document, expectedView: view,
    expectedController: controller, routeMessage: route });
  const registration = objc.register({
    add: controller.addScriptMessageHandler(handler, "zapp"),
    remove: controller.removeScriptMessageHandlerForName("zapp"),
  });
  let style = WebKit.NSWindowStyleMaskTitled
    | WebKit.NSWindowStyleMaskClosable
    | WebKit.NSWindowStyleMaskMiniaturizable;
  if (resizable) style = style | WebKit.NSWindowStyleMaskResizable;
  const window = new MacOSWindow(frame, macOSTitleBarStyleMask(style, in titleBar));
  const gestures = new MacOSWindowGestures(window, view, document);
  window.observeGestures(weak gestures);
  window.title = move title;
  window.contentView = view;
  applyMacOSTitleBar(in window, in titleBar, in id);
  applyMacOSWindowPolicy(window, maximizable, fullscreenable);
  installWindowChrome(in view, in controller);
  const navigationController = new RelatedNavigation({ view, address, document, failed, allowsCreation });
  const uiController = new RelatedUI({ view, window, createChild });
  const navigation = objc.adapt<WebKit.WKNavigationDelegate>(navigationController);
  const ui = objc.adapt<WebKit.WKUIDelegate>(uiController);
  const noState = Option<MacOSWindowStateObserver>.none;
  const delegate = createDesktopWindowDelegate(copy id, document.windowId, window, view, windows, closed, in noState);
  const presentationObserver = observeWindowPresentation(copy id, window, view, windows, in noState);
  view.navigationDelegate = navigation;
  view.UIDelegate = ui;
  window.delegate = delegate;
  // The creation coordinator retains this graph before exposing the WebView.
  // Presentation waits for the acknowledged child activation.
  return new MacOSWindowRuntime({ id, nativeId: document.windowId, window, webView: view,
    contentController: controller, configuration, document, schemeHandler: Option.none,
    navigationDelegate: navigation, uiDelegate: ui, windowDelegate: delegate,
    presentationObserver, gestures, registration, capabilitySelection: document.capabilities });
}
