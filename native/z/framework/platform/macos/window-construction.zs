import Foundation from "Foundation/Foundation.h";
import WebKit from "WebKit/WebKit.h";
import { WindowError } from "../../application-error.zs";
import { CapabilitySelection } from "../../application-capabilities.zs";
import { createPendingRequests } from "../../pending-requests.zs";
import {
  WindowManager,
  WindowOptions,
} from "../../window.zs";
import objc from "std/objc";
import { thread } from "std/thread";
import { createDesktopAssetSchemeHandler } from "./scheme-handler.zs";
import {
  DesktopDeliverResponseOperation,
  DesktopMessageHandler,
  DesktopRouteMessageOperation,
} from "./message-handler.zs";
import {
  createDesktopNavigationDelegate,
  resolveLogicalURL,
} from "./navigation.zs";
import {
  installWebViewScripts,
} from "./webview-injections.zs";
import {
  NativeWindowClosedOperation,
  createDesktopWindowDelegate,
} from "./window-delegate.zs";
import { macOSWindowFrame } from "./window-geometry.zs";
import { MacOSWindowRuntime } from "./window-runtime.zs";
import { startConfiguredWindowSmokeSupport } from "./configured-smoke.zs";

internal function createMacOSWindowRuntime(
  name: String,
  in id: String,
  nativeId: i32,
  in options: WindowOptions,
  capabilitySelection: CapabilitySelection,
  windowManager: Weak<WindowManager>,
  routeMessage: DesktopRouteMessageOperation,
  deliverResponse: DesktopDeliverResponseOperation,
  didCloseNativeWindow: NativeWindowClosedOperation
): MacOSWindowRuntime throws WindowError on thread.main {
  const contentController = WebKit.WKUserContentController.alloc().init();
  const handler = new DesktopMessageHandler({
    windowId: nativeId,
    routeMessage,
    deliverResponse,
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
  const configuration = WebKit.WKWebViewConfiguration.alloc().init();
  configuration.userContentController = contentController;
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
  let style = WebKit.NSWindowStyleMaskTitled
    | WebKit.NSWindowStyleMaskClosable;
  if (options.resizable) {
    style = style | WebKit.NSWindowStyleMaskResizable;
  }
  const window = WebKit.NSWindow.alloc().initWithContentRect(
    frame,
    styleMask: style,
    backing: WebKit.NSBackingStoreBuffered,
    defer: false
  );
  window.releasedWhenClosed = false;
  const title = options.title.byteLength == 0
    ? copy name
    : copy options.title;
  window.title = move title;
  window.contentView = webView;
  const initialURL = resolveLogicalURL(in options.url);
  if (initialURL == null) {
    throw WindowError({
      id: copy id,
      message: `could not resolve window URL "${options.url}"`,
    });
  }
  const navigationDelegate = createDesktopNavigationDelegate(window);
  webView.navigationDelegate = navigationDelegate;
  const windowDelegate = createDesktopWindowDelegate(
    copy id,
    nativeId,
    window,
    webView,
    windowManager,
    didCloseNativeWindow
  );
  window.delegate = windowDelegate;
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
    schemeHandler,
    navigationDelegate,
    windowDelegate,
    registration,
    pendingRequests: createPendingRequests(),
    capabilitySelection,
  });
}
