import native from "zapp_desktop.h";
import { ApplicationConfig } from "../application-contract.zs";
import { routeMessageWithServicesAsync } from "../async-bridge.zs";
import { AsyncServices } from "../async-services.zs";
import { BridgeResponse } from "../bridge.zs";
import {
  ApplicationContext,
  ServiceLifecycleError,
} from "../service-lifecycle-contract.zs";
import { zapp_deliver_response_from_z } from "zapp_router.h";
import objc from "std/objc";
import { Once, OnceLifetime } from "std/sync";
import { TaskScope } from "std/async";
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

class MacOSApplicationRuntime {
  readonly name: String;
  readonly services: AsyncServices;
  readonly updates: TaskScope;
  window: native.NSWindow on thread.main;
  webView: native.WKWebView on thread.main;
  contentController: native.WKUserContentController on thread.main;
  configuration: native.WKWebViewConfiguration on thread.main;
  registrationOwner: native.ZAppDesktopRegistrationOwner on thread.main;
  registration: objc.Registration on thread.main;
}

const application = Once<MacOSApplicationRuntime>();

export async function runMacOSApplication(
  config: ApplicationConfig,
  updates: TaskScope
): i32 throws ServiceLifecycleError on thread.main {
  const prepared = native.zapp_desktop_prepare();
  if (prepared != 0) return prepared;
  const context = ApplicationContext({ name: copy config.name });
  const lifetime = initializeMacOSApplicationRuntime(
    copy config.name,
    config.services,
    updates
  );
  const started = attempt config.lifecycles.start(in context);
  match (started) {
    success => {}
    failure(startError) => throw startError;
  }
  const status = native.zapp_desktop_run();
  await updates.cancel();
  const stopped = attempt config.lifecycles.stop(in context);
  match (stopped) {
    success => {}
    failure(stopError) => throw stopError;
  }
  return status;
}

export c function zapp_route_message_owned(
  message: String,
  windowId: i32
): void {
  const current = application.get();
  const services = current.services;
  const updates = current.updates;
  const control = updates.schedule(
    thread.main,
    async move (): void => {
      const routed = await routeMessageWithServicesAsync(
        move message,
        services
      );
      match (routed) {
        some(response) => deliverResponse(in response, windowId);
        none => {}
      }
    }
  );
  if (!control.accepted) {
    zapp_deliver_response_from_z(
      "Application is closing",
      0,
      false,
      windowId
    );
  }
}

function deliverResponse(
  in response: BridgeResponse,
  windowId: i32
): void {
  zapp_deliver_response_from_z(
    response.payload,
    response.id,
    response.ok,
    windowId
  );
}

function initializeMacOSApplicationRuntime(
  name: String,
  services: AsyncServices,
  updates: TaskScope
): OnceLifetime<MacOSApplicationRuntime> on thread.main {
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
  window.title = copy name;
  window.contentView = webView;
  native.ZAppDesktopBridge.attachWindow(
    window,
    webView: webView,
    contentController: contentController
  );

  const value = new MacOSApplicationRuntime({
    name: move name,
    services: move services,
    updates,
    window,
    webView,
    contentController,
    configuration,
    registrationOwner,
    registration,
  });
  return application.initialize(move value);
}
