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
import { Map } from "std/collections";
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
  pendingRequests: Map<u64, PendingRequest> on thread.main;
  nextRequestGeneration: u64 on thread.main;
  window: native.NSWindow on thread.main;
  webView: native.WKWebView on thread.main;
  contentController: native.WKUserContentController on thread.main;
  configuration: native.WKWebViewConfiguration on thread.main;
  registrationOwner: native.ZAppDesktopRegistrationOwner on thread.main;
  registration: objc.Registration on thread.main;

  function beginRequest(
    inout this,
    request: PendingRequest
  ): void on thread.main {
    const generation = this.nextRequestGeneration;
    this.nextRequestGeneration = this.nextRequestGeneration + 1;
    request.assignGeneration(generation);
    const previous = this.pendingRequests.remove(request.id);
    match (previous) {
      some(active) => active.requestCancel();
      none => {}
    }
    this.pendingRequests.set(request.id, request);
  }

  function finishRequest(
    inout this,
    request: PendingRequest
  ): void on thread.main {
    request.finish();
    const active = this.pendingRequests.get(request.id);
    const current = match (in active) {
      some(value) => value.generation == request.generation;
      none => false;
    };
    if (current) this.pendingRequests.delete(request.id);
  }

  function cancelRequest(
    inout this,
    id: u64
  ): boolean on thread.main {
    const found = this.pendingRequests.remove(id);
    return match (found) {
      some(request) => request.requestCancel();
      none => false;
    };
  }
}

class PendingRequest {
  readonly id: u64;
  generation: u64;
  control: Option<TaskControl>;
  completed: boolean;

  function assignGeneration(
    inout this,
    generation: u64
  ): void {
    this.generation = generation;
  }

  function attach(
    inout this,
    control: TaskControl
  ): void {
    if (this.completed) return;
    this.control = Option.some(control);
  }

  function finish(inout this): void {
    this.completed = true;
    this.control = Option.none;
  }

  function requestCancel(inout this): boolean {
    this.completed = true;
    const requested = match (in this.control) {
      some(control) => control.requestCancel();
      none => false;
    };
    this.control = Option.none;
    return requested;
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
  const pending = new PendingRequest({
    id: bridgeMessage.id,
    generation: 0,
    control: Option<TaskControl>.none,
    completed: false,
  });
  let request = Option<PendingRequest>.none;
  if (tracked) request = Option.some(pending);
  const control = updates.schedule(
    thread.main,
    async move (): void => await routeMessageAndDeliver(
      move bridgeMessage,
      services,
      windowId,
      request
    )
  );
  const accepted: boolean = control.accepted;
  if (tracked) pending.attach(control);
  if (!accepted) {
    if (tracked) pending.finish();
    zapp_deliver_response_from_z(
      "Application is closing",
      0,
      false,
      windowId
    );
  }
}

async function routeMessageAndDeliver(
  message: BridgeMessage,
  services: AsyncServices,
  windowId: i32,
  request: Option<PendingRequest>
): void on thread.main {
  match (in request) {
    some(pending) => beginPendingRequest(pending);
    none => {}
  }
  const routed = await routeDecodedMessageWithServicesAsync(
    move message,
    services
  );
  match (in request) {
    some(pending) => finishPendingRequest(pending);
    none => {}
  }
  match (routed) {
    some(response) => deliverResponse(in response, windowId);
    none => {}
  }
}

function beginPendingRequest(
  request: PendingRequest
): void on thread.main {
  const current = application.get();
  current.beginRequest(request);
}

function finishPendingRequest(
  request: PendingRequest
): void on thread.main {
  const current = application.get();
  current.finishRequest(request);
}

function cancelPendingRequest(id: u64): void on thread.main {
  const current = application.get();
  current.cancelRequest(id);
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
    pendingRequests: Map<u64, PendingRequest>(),
    nextRequestGeneration: 1,
  });
  return application.initialize(move value);
}
