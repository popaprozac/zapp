import native from "zapp_desktop.h";
import { routeMessageWithServices } from "./bridge.zs";
import { createNotesService } from "./notes-service.zs";
import { Services, createServices } from "./services.zs";
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

class DesktopApplication {
  readonly name: String;
  readonly services: Services;
  window: native.NSWindow on thread.main;
  webView: native.WKWebView on thread.main;
  contentController: native.WKUserContentController on thread.main;
  configuration: native.WKWebViewConfiguration on thread.main;
  registrationOwner: native.ZAppDesktopRegistrationOwner on thread.main;
  registration: objc.Registration on thread.main;
}

const application = Once<DesktopApplication>();

export c function zapp_route_message_owned(
  message: String,
  windowId: i32
): void {
  const current = application.get();
  const services = current.services;
  const routed = routeMessageWithServices(in message, in services);
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

export c function zapp_invoke_service_owned(
  method: String,
  arguments: String,
  requestId: u64,
  contextId: i32
): void {
  const current = application.get();
  const services = current.services;
  const invoked = services.invoke(move method, move arguments);
  match (invoked) {
    success(payload) => zapp_deliver_response_from_z(
      payload,
      requestId,
      true,
      contextId
    );
    failure(error) => zapp_deliver_response_from_z(
      error,
      requestId,
      false,
      contextId
    );
  }
}

function initializeDesktopApplication(
): OnceLifetime<DesktopApplication> on thread.main {
  let services = createServices();
  services.register("notes", createNotesService());
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

  const frame = native.NSMakeRect(0.0, 0.0, 720.0, 460.0);
  const webView = native.WKWebView.alloc().initWithFrame(
    frame,
    configuration: configuration
  );
  const style = native.NSWindowStyleMaskTitled
    | native.NSWindowStyleMaskClosable
    | native.NSWindowStyleMaskResizable;
  const window = native.NSWindow.alloc().initWithContentRect(
    frame,
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
    services: services.freeze(),
    window,
    webView,
    contentController,
    configuration,
    registrationOwner,
    registration,
  });
  return application.initialize(move value);
}
