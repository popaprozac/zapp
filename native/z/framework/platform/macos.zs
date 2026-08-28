import native from "zapp_desktop.h";
import { PreparedApplication } from "../application-contract.zs";
import {
  ApplicationError,
  PlatformError,
  WindowError,
} from "../application-error.zs";
import { ApplicationMetadata } from "../application-metadata.zs";
import { ApplicationPermissions } from "../application-permissions.zs";
import { routeDecodedMessageWithServicesAsync } from "../async-bridge.zs";
import { AsyncServices } from "../async-services.zs";
import {
  BridgeMessage,
  BridgeMessageKind,
  BridgeResponse,
  bridgeFailure,
  decodeBridgeMessage,
} from "../bridge.zs";
import {
  ApplicationContext,
} from "../service-lifecycle-contract.zs";
import { zapp_deliver_response_from_z } from "zapp_router.h";
import objc from "std/objc";
import { Once, OnceLifetime } from "std/sync";
import { TaskControl, TaskScope } from "std/async";
import { Map } from "std/collections";
import { thread } from "std/thread";
import {
  PendingRequests,
  createPendingRequests,
} from "../pending-requests.zs";
import {
  WindowBackend,
  WindowCreateOperation,
  WindowManager,
  WindowOptions,
  WindowOperation,
  WindowTitleOperation,
} from "../window.zs";
import { routeWindowBridgeMessage } from "../window-bridge.zs";

class DesktopMessageHandler on thread.main
  implements native.WKScriptMessageHandler {
  readonly windowId: i32;

  function receive(
    in controller: native.WKUserContentController,
    in message: native.WKScriptMessage
  ): void as "userContentController:didReceiveScriptMessage:" {
    const body = message.body;
    if (body instanceof native.NSString) {
      const text: String = body;
      zapp_route_message_owned(move text, this.windowId);
      return;
    }
    const failure = bridgeFailure(
      0,
      "INVALID_MESSAGE",
      "WebView message body must be a string"
    );
    zapp_deliver_response_from_z(
      failure.payload,
      0,
      false,
      this.windowId
    );
  }
}

class MacOSWindowRuntime on thread.main {
  readonly id: String;
  readonly nativeId: i32;
  readonly window: native.NSWindow;
  readonly webView: native.WKWebView;
  readonly contentController: native.WKUserContentController;
  readonly configuration: native.WKWebViewConfiguration;
  readonly registrationOwner: native.ZAppDesktopRegistrationOwner;
  readonly registration: objc.Registration;
  readonly pendingRequests: PendingRequests;
}

enum WindowMessageRoute {
  framework BridgeResponse,
  service BridgeMessage,
}

class MacOSApplicationRuntime {
  readonly name: String;
  readonly permissions: ApplicationPermissions;
  readonly services: AsyncServices;
  readonly updates: TaskScope;
  readonly windowManager: WindowManager on thread.main;
  nativeWindows: Map<i32, MacOSWindowRuntime> on thread.main;
  nextNativeWindowId: i32 on thread.main;

  function createWindow(
    inout this,
    in id: String,
    in options: WindowOptions
  ): void throws WindowError on thread.main {
    for (const profile of options.inject) {
      if (native.zapp_desktop_has_injection_profile(profile) == 0) {
        throw WindowError({
          id: copy id,
          message: `unknown webview inject profile "${profile}"`,
        });
      }
    }
    const nativeId = this.nextNativeWindowId;
    this.nextNativeWindowId = this.nextNativeWindowId + 1;
    const runtime = try createMacOSWindowRuntime(
      copy this.name,
      in id,
      nativeId,
      in options
    );
    this.nativeWindows.set(nativeId, runtime);
  }

  function closeWindow(
    inout this,
    nativeId: i32,
    in id: String
  ): void on thread.main {
    // Keep the Z-owned AppKit graph alive until NSApplication.run has fully
    // unwound its autorelease pools. The native registry stops routing to the
    // closed window immediately; releasing this graph from windowWillClose
    // would tear it down while AppKit is still closing it.
    this.windowManager.__closedNative(in id);
  }

  function beginRequest(
    inout this,
    windowId: i32,
    id: u64
  ): u64 on thread.main {
    const found = this.nativeWindows.remove(windowId);
    return match (found) {
      some(value) => {
        let window = value;
        const generation = window.pendingRequests.begin(id);
        this.nativeWindows.set(windowId, window);
        select generation;
      }
      none => 0;
    };
  }

  function attachRequest(
    inout this,
    windowId: i32,
    id: u64,
    control: TaskControl
  ): void on thread.main {
    const found = this.nativeWindows.remove(windowId);
    match (found) {
      some(value) => {
        let window = value;
        window.pendingRequests.attach(id, control);
        this.nativeWindows.set(windowId, window);
      }
      none => {}
    }
  }

  function finishRequest(
    inout this,
    windowId: i32,
    id: u64,
    generation: u64
  ): void on thread.main {
    const found = this.nativeWindows.remove(windowId);
    match (found) {
      some(value) => {
        let window = value;
        window.pendingRequests.finish(id, generation);
        this.nativeWindows.set(windowId, window);
      }
      none => {}
    }
  }

  function cancelRequest(
    inout this,
    windowId: i32,
    id: u64
  ): boolean on thread.main {
    const found = this.nativeWindows.remove(windowId);
    return match (found) {
      some(value) => {
        let window = value;
        const cancelled = window.pendingRequests.cancel(id);
        this.nativeWindows.set(windowId, window);
        select cancelled;
      }
      none => false;
    };
  }
}

const application = Once<MacOSApplicationRuntime>();

export async function runMacOSApplication(
  config: PreparedApplication,
  updates: TaskScope
): i32 throws ApplicationError on thread.main {
  let windows = config.windows;
  const registeredWindows = windows.all();
  if (registeredWindows.length == 0) {
    throw ApplicationError.window(WindowError({
      id: "",
      message: "a macOS desktop application requires a registered window in this tier",
    }));
  }
  const prepared = native.zapp_desktop_prepare();
  if (prepared != 0) {
    throw ApplicationError.platform(PlatformError({
      code: prepared,
      message: "could not prepare the macOS application runtime",
    }));
  }
  const context = ApplicationContext({
    metadata: ApplicationMetadata({
      name: copy config.metadata.name,
      identifier: copy config.metadata.identifier,
      version: copy config.metadata.version,
    }),
  });
  const lifetime = initializeMacOSApplicationRuntime(
    copy config.metadata.name,
    config.permissions,
    config.services,
    updates,
    windows
  );
  const realized = attempt windows.__start(macOSWindowBackend(), true);
  match (realized) {
    success => {}
    failure(windowError) => {
      windows.__stop();
      native.zapp_desktop_abort();
      throw ApplicationError.window(windowError);
    }
  }
  const started = attempt config.lifecycles.start(in context);
  match (started) {
    success => {}
    failure(startError) => {
      windows.__stop();
      native.zapp_desktop_abort();
      throw ApplicationError.lifecycle(startError);
    }
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
): void throws WindowError on thread.main {
  const current = application.get();
  try current.createWindow(in id, in options);
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
      const failure = bridgeFailure(
        0,
        "INVALID_MESSAGE",
        copy error.message
      );
      zapp_deliver_response_from_z(
        failure.payload,
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
      async move (): void => cancelPendingRequest(windowId, cancellationId)
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
      async move (): void => attachPendingRequest(windowId, requestId, control)
    );
    if (!attachment.accepted) return;
  }
  if (!accepted) {
    const failure = bridgeFailure(
      0,
      "APPLICATION_CLOSING",
      "Application is closing"
    );
    zapp_deliver_response_from_z(
      failure.payload,
      0,
      false,
      windowId
    );
  }
}

function attachPendingRequest(
  windowId: i32,
  id: u64,
  control: TaskControl
): void on thread.main {
  const current = application.get();
  current.attachRequest(windowId, id, control);
}

async function routeScheduledMessageAndDeliver(
  message: BridgeMessage,
  services: AsyncServices,
  windowId: i32,
  requestId: u64,
  tracked: boolean
): void on thread.main {
  let generation: u64 = 0;
  if (tracked) generation = beginPendingRequest(windowId, requestId);
  const delivered = await routeFrameworkOrServiceMessageAndDeliver(
    move message,
    services,
    windowId,
    requestId,
    generation,
    tracked
  );
  if (!delivered) return;
}

async function routeFrameworkOrServiceMessageAndDeliver(
  message: BridgeMessage,
  services: AsyncServices,
  windowId: i32,
  requestId: u64,
  generation: u64,
  tracked: boolean
): boolean on thread.main {
  const current = application.get();
  let windows = current.windowManager;
  const route = selectWindowMessageRoute(move message, inout windows);
  match (route) {
    framework(response) => {
      if (tracked) finishPendingRequest(windowId, requestId, generation);
      deliverResponse(in response, windowId);
      return true;
    }
    service(forwarded) => return await routeMessageAndDeliver(
      move forwarded,
      services,
      windowId,
      requestId,
      generation,
      tracked
    );
  }
}

function selectWindowMessageRoute(
  message: BridgeMessage,
  inout windows: WindowManager
): WindowMessageRoute on thread.main {
  const current = application.get();
  const permissions = current.permissions;
  const routed = routeWindowBridgeMessage(
    in message,
    in permissions,
    inout windows
  );
  return match (routed) {
    some(response) => WindowMessageRoute.framework(response);
    none => WindowMessageRoute.service(move message);
  };
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
  if (tracked) finishPendingRequest(windowId, requestId, generation);
  return match (routed) {
    some(response) => {
      deliverResponse(in response, windowId);
      select true;
    }
    none => false;
  };
}

function beginPendingRequest(
  windowId: i32,
  id: u64
): u64 on thread.main {
  const current = application.get();
  return current.beginRequest(windowId, id);
}

function finishPendingRequest(
  windowId: i32,
  id: u64,
  generation: u64
): void on thread.main {
  const current = application.get();
  current.finishRequest(windowId, id, generation);
}

function cancelPendingRequest(
  windowId: i32,
  id: u64
): void on thread.main {
  const current = application.get();
  current.cancelRequest(windowId, id);
}

export c function zapp_window_closed_owned(
  windowId: String,
  nativeId: i32
): void {
  const current = application.get();
  const updates = current.updates;
  const cleanup = updates.schedule(
    thread.main,
    async move (): void => closeNativeWindow(move windowId, nativeId)
  );
  if (!cleanup.accepted) return;
}

function closeNativeWindow(
  windowId: String,
  nativeId: i32
): void on thread.main {
  const current = application.get();
  current.closeWindow(nativeId, in windowId);
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

function createMacOSWindowRuntime(
  name: String,
  in id: String,
  nativeId: i32,
  in options: WindowOptions
): MacOSWindowRuntime throws WindowError on thread.main {
  const contentController = native.WKUserContentController.alloc().init();
  const registrationOwner = native.ZAppDesktopRegistrationOwner.alloc()
    .initWithContentController(contentController);
  const handler = new DesktopMessageHandler({ windowId: nativeId });
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
  window.releasedWhenClosed = false;
  const title = options.title.byteLength == 0
    ? copy name
    : copy options.title;
  const logicalURL = copy options.url;
  window.title = move title;
  window.contentView = webView;
  const configured = native.zapp_desktop_window_configure(
    id,
    nativeId,
    logicalURL,
    options.visible
  );
  if (configured != 0) {
    throw WindowError({
      id: copy id,
      message: `could not configure native window (status ${configured})`,
    });
  }
  native.ZAppDesktopBridge.attachWindow(
    window,
    nativeId: nativeId,
    webView: webView,
    contentController: contentController,
    visible: options.visible
  );
  for (const profile of options.inject) {
    const selected = native.zapp_desktop_window_select_injection_profile(
      id,
      profile
    );
    if (selected != 0) {
      native.zapp_desktop_window_discard(id);
      throw WindowError({
        id: copy id,
        message: `could not select webview inject profile "${profile}"`,
      });
    }
  }
  const started = native.zapp_desktop_window_start(id);
  if (started != 0) {
    native.zapp_desktop_window_discard(id);
    throw WindowError({
      id: copy id,
      message: `could not realize native window (status ${started})`,
    });
  }

  return new MacOSWindowRuntime({
    id: copy id,
    nativeId,
    window,
    webView,
    contentController,
    configuration,
    registrationOwner,
    registration,
    pendingRequests: createPendingRequests(),
  });
}

function initializeMacOSApplicationRuntime(
  name: String,
  permissions: ApplicationPermissions,
  services: AsyncServices,
  updates: TaskScope,
  windowManager: WindowManager
): OnceLifetime<MacOSApplicationRuntime> on thread.main {
  const value = new MacOSApplicationRuntime({
    name: move name,
    permissions,
    services: move services,
    updates,
    windowManager,
    nativeWindows: Map<i32, MacOSWindowRuntime>(),
    nextNativeWindowId: 1,
  });
  return application.initialize(move value);
}
