import native from "zapp_desktop.h";
import { ApplicationConfig } from "../application-contract.zs";
import { routeDecodedMessageWithServicesAsync } from "../async-bridge.zs";
import { AsyncServices } from "../async-services.zs";
import {
  BridgeMessage,
  BridgeMessageKind,
  BridgeResponse,
  decodeBridgeMessage,
} from "../bridge.zs";
import {
  ApplicationContext,
  ServiceLifecycleError,
} from "../service-lifecycle-contract.zs";
import { zapp_deliver_response_from_z } from "zapp_router.h";
import objc from "std/objc";
import { Once, OnceLifetime } from "std/sync";
import { TaskControl, TaskScope } from "std/async";
import { thread } from "std/thread";
import {
  PendingRequests,
  createPendingRequests,
} from "../pending-requests.zs";

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
  pendingRequests: PendingRequests on thread.main;
  window: native.NSWindow on thread.main;
  webView: native.WKWebView on thread.main;
  contentController: native.WKUserContentController on thread.main;
  configuration: native.WKWebViewConfiguration on thread.main;
  registrationOwner: native.ZAppDesktopRegistrationOwner on thread.main;
  registration: objc.Registration on thread.main;

  function beginRequest(
    inout this,
    id: u64
  ): u64 on thread.main {
    return this.pendingRequests.begin(id);
  }

  function attachRequest(
    inout this,
    id: u64,
    control: TaskControl
  ): void on thread.main {
    this.pendingRequests.attach(id, control);
  }

  function finishRequest(
    inout this,
    id: u64,
    generation: u64
  ): void on thread.main {
    this.pendingRequests.finish(id, generation);
  }

  function cancelRequest(
    inout this,
    id: u64
  ): boolean on thread.main {
    return this.pendingRequests.cancel(id);
  }
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
  const updates = current.updates;
  const decoded = attempt decodeBridgeMessage(in message);
  const bridgeMessage = match (decoded) {
    success(value) => value;
    failure(error) => {
      zapp_deliver_response_from_z(
        error.message,
        0,
        false,
        windowId
      );
      return;
    }
  };
  if (bridgeMessage.kind == BridgeMessageKind.cancel) {
    const cancellationId = bridgeMessage.id;
    const cancellation = updates.schedule(
      thread.main,
      async move (): void => cancelPendingRequest(cancellationId)
    );
    if (!cancellation.accepted) return;
    return;
  }
  const services = current.services;
  const tracked = bridgeMessage.kind == BridgeMessageKind.invoke;
  const requestId = bridgeMessage.id;
  const control = updates.schedule(
    thread.main,
    async move (): void => await routeScheduledMessageAndDeliver(
      move bridgeMessage,
      services,
      windowId,
      requestId,
      tracked
    )
  );
  const accepted: boolean = control.accepted;
  if (tracked && accepted) {
    const attachment = updates.schedule(
      thread.main,
      async move (): void => attachPendingRequest(requestId, control)
    );
    if (!attachment.accepted) return;
  }
  if (!accepted) {
    zapp_deliver_response_from_z(
      "Application is closing",
      0,
      false,
      windowId
    );
  }
}

function attachPendingRequest(
  id: u64,
  control: TaskControl
): void on thread.main {
  const current = application.get();
  current.attachRequest(id, control);
}

async function routeScheduledMessageAndDeliver(
  message: BridgeMessage,
  services: AsyncServices,
  windowId: i32,
  requestId: u64,
  tracked: boolean
): void on thread.main {
  let generation: u64 = 0;
  if (tracked) generation = beginPendingRequest(requestId);
  const delivered = await routeMessageAndDeliver(
    move message,
    services,
    windowId,
    requestId,
    generation,
    tracked
  );
  if (!delivered) return;
}

async function routeMessageAndDeliver(
  message: BridgeMessage,
  services: AsyncServices,
  windowId: i32,
  requestId: u64,
  generation: u64,
  tracked: boolean
): boolean {
  const routed = await routeDecodedMessageWithServicesAsync(
    move message,
    services
  );
  const delivered = await on thread.main finishAndDeliverRoutedResponse(
    move routed,
    windowId,
    requestId,
    generation,
    tracked
  );
  return delivered;
}

async function finishAndDeliverRoutedResponse(
  routed: Option<BridgeResponse>,
  windowId: i32,
  requestId: u64,
  generation: u64,
  tracked: boolean
): boolean on thread.main {
  if (tracked) finishPendingRequest(requestId, generation);
  return match (routed) {
    some(response) => {
      deliverResponse(in response, windowId);
      select true;
    }
    none => false;
  };
}

function beginPendingRequest(
  id: u64
): u64 on thread.main {
  const current = application.get();
  return current.beginRequest(id);
}

function finishPendingRequest(
  id: u64,
  generation: u64
): void on thread.main {
  const current = application.get();
  current.finishRequest(id, generation);
}

function cancelPendingRequest(id: u64): void on thread.main {
  const current = application.get();
  current.cancelRequest(id);
}

function deliverResponse(
  in response: BridgeResponse,
  windowId: i32
): void on thread.main {
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
    pendingRequests: createPendingRequests(),
  });
  return application.initialize(move value);
}
