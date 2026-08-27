import native from "zapp_desktop.h";
import { PreparedApplication } from "../application-contract.zs";
import {
  ApplicationError,
  PlatformError,
  WindowError,
} from "../application-error.zs";
import { ApplicationMetadata } from "../application-metadata.zs";
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
import {
  WindowBackend,
  WindowCreateOperation,
  WindowOptions,
  WindowOperation,
  WindowTitleOperation,
} from "../window.zs";

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
  config: PreparedApplication,
  updates: TaskScope
): i32 throws ApplicationError on thread.main {
  const prepared = native.zapp_desktop_prepare();
  if (prepared != 0) {
    throw ApplicationError.platform(PlatformError({
      code: prepared,
      message: "could not prepare the macOS application runtime",
    }));
  }
  let windows = config.windows;
  const registeredWindows = windows.all();
  if (registeredWindows.length == 0) {
    throw ApplicationError.window(WindowError({
      id: "",
      message: "a macOS desktop application requires a registered window in this tier",
    }));
  }
  if (registeredWindows.length > 1) {
    throw ApplicationError.window(WindowError({
      id: "",
      message: "native multi-window realization is not implemented yet",
    }));
  }
  const primaryWindow = registeredWindows[0];
  const primaryWindowId = copy primaryWindow.id;
  const configuredOptions = windows.__options(in primaryWindowId);
  const primaryOptions = match (configuredOptions) {
    some(options) => options;
    none => throw ApplicationError.window(WindowError({
      id: copy primaryWindowId,
      message: "the registered window lost its configuration",
    }));
  };
  const context = ApplicationContext({
    metadata: ApplicationMetadata({
      name: copy config.metadata.name,
      identifier: copy config.metadata.identifier,
      version: copy config.metadata.version,
    }),
  });
  const lifetime = initializeMacOSApplicationRuntime(
    copy config.metadata.name,
    config.services,
    updates,
    in primaryOptions
  );
  windows.__start(macOSWindowBackend(), false);
  const started = attempt config.lifecycles.start(in context);
  match (started) {
    success => {}
    failure(startError) => throw ApplicationError.lifecycle(startError);
  }
  const status = native.zapp_desktop_run();
  windows.__stop();
  await updates.cancel();
  const stopped = attempt config.lifecycles.stop(in context);
  match (stopped) {
    success => {}
    failure(stopError) => throw ApplicationError.lifecycle(stopError);
  }
  return status;
}

function createMacOSWindowDeferred(
  in id: String,
  in options: WindowOptions
): void on thread.main {
  // Startup realization is owned by runMacOSApplication in the first native
  // window tier. Dynamic and multi-window creation use this seam next.
}

function showMacOSWindow(in id: String): void on thread.main {
  native.zapp_desktop_window_show(id);
}

function hideMacOSWindow(in id: String): void on thread.main {
  native.zapp_desktop_window_hide(id);
}

function closeMacOSWindow(in id: String): void on thread.main {
  native.zapp_desktop_window_close(id);
}

function setMacOSWindowTitle(
  in id: String,
  in title: String
): void on thread.main {
  native.zapp_desktop_window_set_title(id, title);
}

function macOSWindowBackend(): WindowBackend on thread.main {
  const create: WindowCreateOperation = createMacOSWindowDeferred;
  const show: WindowOperation = showMacOSWindow;
  const hide: WindowOperation = hideMacOSWindow;
  const close: WindowOperation = closeMacOSWindow;
  const setTitle: WindowTitleOperation = setMacOSWindowTitle;
  return WindowBackend({
    create,
    show,
    hide,
    close,
    setTitle,
  });
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
  updates: TaskScope,
  in options: WindowOptions
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
  native.ZAppDesktopBridge.configureWebViewConfiguration(configuration);

  const frame = native.zapp_desktop_make_rect(
    options.width,
    options.height
  );
  const webView = native.WKWebView.alloc().initWithFrame(
    frame,
    configuration: configuration
  );
  let style = native.NSWindowStyleMaskTitled
    | native.NSWindowStyleMaskClosable;
  if (options.resizable) {
    style = style | native.NSWindowStyleMaskResizable;
  }
  const window = native.NSWindow.alloc().initWithContentRect(
    frame,
    styleMask: style,
    backing: native.NSBackingStoreBuffered,
    defer: false
  );
  const title = options.title.byteLength == 0
    ? copy name
    : copy options.title;
  const logicalURL = copy options.url;
  window.title = move title;
  window.contentView = webView;
  native.zapp_desktop_set_logical_url(logicalURL);
  native.ZAppDesktopBridge.attachWindow(
    window,
    webView: webView,
    contentController: contentController,
    visible: options.visible
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
