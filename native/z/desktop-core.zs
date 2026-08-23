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
  const registrationOwner = native.ZAppDesktopBridge.registrationOwner();
  const handler = new DesktopMessageHandler({});
  const registration = objc.register({
    add: registrationOwner.addHandler(handler),
    remove: registrationOwner.removeHandler(),
  });
  const value = new DesktopApplication({
    name: "Zapp",
    registrationOwner,
    registration,
  });
  return application.initialize(move value);
}
