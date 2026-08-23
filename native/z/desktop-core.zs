import native from "zapp_desktop.h";
import { routeMessage } from "./bridge.zs";
import { zapp_deliver_response_from_z } from "zapp_router.h";
import objc from "std/objc";
import { Once, OnceLifetime } from "std/sync";
import { thread } from "std/thread";

class DesktopMessageHandler on thread.main
  implements native.WKScriptMessageHandler {
  function receive(
    in controller: native.WKUserContentController,
    in message: native.WKScriptMessage
  ): void as "userContentController:didReceiveScriptMessage:" {
    const body = message.body;
    if (body instanceof native.NSString) {
      const text: String = body;
      zapp_route_message_owned(move text, 1);
      return;
    }
    zapp_deliver_response_from_z(
      "WebView message body must be a string",
      0,
      false,
      1
    );
  }
}

class DesktopApplication on thread.main {
  readonly name: String;
  window: native.NSWindow;
  webView: native.WKWebView;
  contentController: native.WKUserContentController;
  configuration: native.WKWebViewConfiguration;
  registrationOwner: native.ZAppDesktopRegistrationOwner;
  registration: objc.Registration;
}

const application = Once<DesktopApplication>();

export c function zapp_route_message_owned(
  message: String,
  windowId: i32
): void {
  const current = application.get();
  const routed = routeMessage(in message);
  match (routed) {
    some(response) => zapp_deliver_response_from_z(
      response.payload,
      response.id,
      response.ok,
      windowId
    );
    none => {}
  }
}

function initializeDesktopApplication(
): OnceLifetime<DesktopApplication> on thread.main {
  const contentController = native.WKUserContentController.alloc().init();
  const registrationOwner = native.ZAppDesktopRegistrationOwner.alloc()
    .initWithContentController(contentController);
  const handler = new DesktopMessageHandler({});
  const registration = objc.register({
    add: registrationOwner.addHandler(handler),
    remove: registrationOwner.removeHandler(),
  });
  const configuration = native.WKWebViewConfiguration.alloc().init();
  configuration.userContentController = contentController;

  const webViewFrame = native.CGRect({
    origin: native.CGPoint({ x: 0.0, y: 0.0 }),
    size: native.CGSize({ width: 720.0, height: 460.0 }),
  });
  const webView = native.WKWebView.alloc().initWithFrame(
    webViewFrame,
    configuration: configuration
  );
  const windowFrame = native.NSMakeRect(0.0, 0.0, 720.0, 460.0);
  const style = native.NSWindowStyleMaskTitled
    | native.NSWindowStyleMaskClosable
    | native.NSWindowStyleMaskResizable;
  const window = native.NSWindow.alloc().initWithContentRect(
    windowFrame,
    styleMask: style,
    backing: native.NSBackingStoreBuffered,
    defer: false
  );
  window.title = "Zapp — Z WebView Bridge";
  window.contentView = webView;
  native.ZAppDesktopBridge.attachWindow(
    window,
    webView: webView,
    contentController: contentController
  );

  const value = new DesktopApplication({
    name: "Zapp",
    window,
    webView,
    contentController,
    configuration,
    registrationOwner,
    registration,
  });
  return application.initialize(move value);
}
