import Foundation from "Foundation/Foundation.h";
import WebKit from "WebKit/WebKit.h";
import { WindowError } from "../../application-error.zs";
import { CapabilitySelection } from "../../application-capabilities.zs";
import { ContextMenuSessions } from "../../context-menu.zs";
import { ApplicationMenu } from "../../application-menu.zs";
import { BridgeDocument } from "../../bridge-document.zs";
import {
  WindowManager,
  WindowOptions,
} from "../../window.zs";
import objc from "std/objc";
import { thread } from "std/thread";
import { createDesktopAssetSchemeHandler } from "./scheme-handler.zs";
import {
  DesktopMessageHandler,
} from "./message-handler.zs";
import { DesktopRouteMessageOperation } from "./document-transport.zs";
import {
  createDesktopNavigationDelegate,
} from "./navigation.zs";
import { resolveLogicalURL } from "./navigation-policy.zs";
import {
  installWebViewScripts,
} from "./webview-injections.zs";
import {
  NativeWindowClosedOperation,
  createDesktopWindowDelegate,
} from "./window-delegate.zs";
import { macOSWindowFrame } from "./window-geometry.zs";
import { MacOSWindowRuntime } from "./window-runtime.zs";
import { MacOSWindow } from "./window-resize.zs";
import { MacOSWindowGestures } from "./window-drag.zs";
import { macOSTitleBarStyleMask, applyMacOSTitleBar } from "./window-titlebar.zs";
import { observeWindowPresentation } from "./window-presentation.zs";
import { startConfiguredWindowSmokeSupport } from "./configured-smoke.zs";
import { MacOSRelatedWindows, createRelatedWindowUIDelegate } from "./related-window-creations.zs";

internal function createMacOSWindowRuntime(
  name: String,
  in id: String,
  nativeId: i32,
  in options: WindowOptions,
  capabilitySelection: CapabilitySelection,
  document: BridgeDocument,
  windowManager: Weak<WindowManager>,
  routeMessage: DesktopRouteMessageOperation,
  didCloseNativeWindow: NativeWindowClosedOperation,
  contextMenus: ContextMenuSessions,
  menu: ApplicationMenu,
  related: MacOSRelatedWindows
): MacOSWindowRuntime throws WindowError on thread.main {
  const contentController = WebKit.WKUserContentController.alloc().init();
  const configuration = WebKit.WKWebViewConfiguration.alloc().init();
  configuration.userContentController = contentController;
  // Both navigation policy and the UI delegate require a native reservation.
  // This enables the later asynchronous factory without allowing raw popups.
  configuration.preferences.javaScriptCanOpenWindowsAutomatically = true;
  const schemeHandler = createDesktopAssetSchemeHandler();
  configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "zapp");
  const scripts = attempt installWebViewScripts(
    contentController,
    in id,
    in options.inject
  );
  match (scripts) {
    success => {}
    failure(message) => throw WindowError({
      id: copy id,
      message,
    });
  }

  const frame = macOSWindowFrame(
    options.width,
    options.height
  );
  const webView = WebKit.WKWebView.alloc().initWithFrame(
    frame,
    configuration: configuration
  );
  // Bind native sender identity before navigation can start. Registration owns
  // removal of the handler, breaking its retained WebView/controller references
  // when this runtime is released after native callbacks have unwound.
  const handler = new DesktopMessageHandler({
    document,
    expectedView: webView,
    expectedController: contentController,
    routeMessage,
  });
  const handlerName = Foundation.NSString.alloc().initWithUTF8String("zapp");
  if (handlerName == null) {
    throw WindowError({
      id: copy id,
      message: "could not construct the WebKit bridge name",
    });
  }
  const registration = objc.register({
    add: contentController.addScriptMessageHandler(handler, handlerName),
    remove: contentController.removeScriptMessageHandlerForName(handlerName),
  });
  let style = WebKit.NSWindowStyleMaskTitled
    | WebKit.NSWindowStyleMaskClosable
    | WebKit.NSWindowStyleMaskMiniaturizable;
  if (options.resizable) {
    style = style | WebKit.NSWindowStyleMaskResizable;
  }
  const window = new MacOSWindow(frame, macOSTitleBarStyleMask(style, in options.titleBar));
  const gestures = new MacOSWindowGestures(window, webView, document);
  window.observeGestures(weak gestures);
  const title = options.title.byteLength == 0
    ? copy name
    : copy options.title;
  window.title = move title;
  window.contentView = webView;
  applyMacOSTitleBar(in window, in options.titleBar, in id);
  const initialURL = resolveLogicalURL(in options.url);
  if (initialURL == null) {
    throw WindowError({
      id: copy id,
      message: `could not resolve window URL "${options.url}"`,
    });
  }
  const navigationDelegate = createDesktopNavigationDelegate(
    copy id,
    copy options.navigation,
    window,
    webView,
    windowManager,
    contextMenus,
    menu,
    document,
    related
  );
  webView.navigationDelegate = navigationDelegate;
  const uiDelegate = createRelatedWindowUIDelegate(related);
  webView.UIDelegate = uiDelegate;
  const windowDelegate = createDesktopWindowDelegate(
    copy id,
    nativeId,
    window,
    webView,
    windowManager,
    didCloseNativeWindow
  );
  window.delegate = windowDelegate;
  const presentationObserver = observeWindowPresentation(copy id, window, webView, windowManager);
  startConfiguredWindowSmokeSupport(
    in id,
    nativeId,
    in webView,
    in contentController
  );
  const request = Foundation.NSURLRequest.requestWithURL(initialURL);
  webView.loadRequest(request);
  window.center();
  if (options.visible) window.makeKeyAndOrderFront(null);

  return new MacOSWindowRuntime({
    id: copy id,
    nativeId,
    window,
    webView,
    contentController,
    configuration,
    schemeHandler: Option.some(schemeHandler),
    navigationDelegate,
    uiDelegate,
    windowDelegate,
    presentationObserver,
    gestures,
    registration,
    document,
    capabilitySelection,
  });
}
