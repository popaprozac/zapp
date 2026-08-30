import native from "zapp_desktop.h";
import Foundation from "Foundation/Foundation.h";
import WebKit from "WebKit/WebKit.h";
import { WindowError } from "../../application-error.zs";
import { ApplicationPermissions } from "../../application-permissions.zs";
import {
  ApplicationCapabilities,
  CapabilitySelection,
} from "../../application-capabilities.zs";
import {
  authorizeServiceInvocation,
  routeDecodedMessageWithServicesAsync,
} from "../../async-bridge.zs";
import { AsyncServices } from "../../async-services.zs";
import {
  BridgeMessage,
  BridgeMessageKind,
  BridgeResponse,
  bridgeFailure,
  decodeBridgeMessage,
} from "../../bridge.zs";
import { zapp_deliver_response_from_z } from "zapp_router.h";
import objc from "std/objc";
import { Once, OnceLifetime } from "std/sync";
import { TaskControl, TaskScope } from "std/async";
import { Map } from "std/collections";
import { thread } from "std/thread";
import {
  PendingRequests,
  createPendingRequests,
} from "../../pending-requests.zs";
import {
  WindowManager,
  WindowOptions,
} from "../../window.zs";
import { routeWindowBridgeMessage } from "../../window-bridge.zs";
import { createDesktopAssetSchemeHandler } from "./scheme-handler.zs";
import { DesktopNavigationDelegate, createDesktopNavigationDelegate,
  resolveLogicalURL } from "./navigation.zs";
import { installWebViewScripts, webViewInjectionProfileExists
} from "./webview-injections.zs";
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
  readonly schemeHandler: objc.Adapter<WebKit.WKURLSchemeHandler>;
  readonly navigationDelegate: objc.Adapter<WebKit.WKNavigationDelegate>;
  readonly registration: objc.Registration;
  readonly pendingRequests: PendingRequests;
  readonly capabilitySelection: CapabilitySelection;
}

enum WindowMessageRoute {
  framework BridgeResponse,
  service BridgeMessage,
}

internal class MacOSApplicationRuntime {
  readonly name: String;
  readonly permissions: ApplicationPermissions;
  readonly capabilities: ApplicationCapabilities;
  readonly services: AsyncServices;
  readonly updates: TaskScope;
  readonly eventUpdates: TaskScope;
  readonly windowManager: WindowManager on thread.main;
  nativeWindows: Map<i32, MacOSWindowRuntime> on thread.main;
  nextNativeWindowId: i32 on thread.main;

  function createWindow(
    inout this,
    in id: String,
    in options: WindowOptions
  ): void throws WindowError on thread.main {
    for (const profile of options.capabilities) {
      if (!this.capabilities.hasProfile(profile)) {
        throw WindowError({
          id: copy id,
          message: `unknown window capability profile "${profile}"`,
        });
      }
    }
    const selected = this.capabilities.resolveProfiles(in options.capabilities);
    match (selected) {
      some(selection) => {
        try this.createResolvedWindow(in id, in options, selection);
        return;
      }
      none => throw WindowError({
        id: copy id,
        message: "could not resolve window capability profiles",
      });
    }
  }

  function createResolvedWindow(
    inout this,
    in id: String,
    in options: WindowOptions,
    selectedCapabilities: CapabilitySelection
  ): void throws WindowError on thread.main {
    for (const profile of options.inject) {
      if (!webViewInjectionProfileExists(profile)) {
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
      in options,
      selectedCapabilities
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
    this.windowManager.closedNative(in id);
  }

  function focusWindow(inout this, in id: String): void on thread.main {
    this.windowManager.focusedNative(in id);
  }

  function blurWindow(inout this, in id: String): void on thread.main {
    this.windowManager.blurredNative(in id);
  }

  function resizeWindow(
    inout this,
    in id: String,
    width: u32,
    height: u32
  ): void on thread.main {
    this.windowManager.resizedNative(in id, width, height);
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

  function showWindow(in id: String): void on thread.main {
    for (const entry of this.nativeWindows) {
      if (entry.value.id == id) {
        entry.value.window.makeKeyAndOrderFront(null);
        return;
      }
    }
  }

  function hideWindow(in id: String): void on thread.main {
    for (const entry of this.nativeWindows) {
      if (entry.value.id == id) {
        entry.value.window.orderOut(null);
        return;
      }
    }
  }

  function requestWindowClose(in id: String): void on thread.main {
    for (const entry of this.nativeWindows) {
      if (entry.value.id == id) {
        entry.value.window.close();
        return;
      }
    }
  }

  function setWindowTitle(
    in id: String,
    in title: String
  ): void on thread.main {
    for (const entry of this.nativeWindows) {
      if (entry.value.id == id) {
        entry.value.window.title = title;
        return;
      }
    }
  }

  function capabilitiesForWindow(
    windowId: i32
  ): Option<CapabilitySelection> on thread.main {
    const found = this.nativeWindows.get(windowId);
    return match (in found) {
      some(window) => Option.some(window.capabilitySelection);
      none => Option.none;
    };
  }
}

const application = Once<MacOSApplicationRuntime>();

internal function currentMacOSApplication(): MacOSApplicationRuntime {
  return application.get();
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
  const route = selectWindowMessageRoute(
    move message,
    windowId,
    inout windows
  );
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
  windowId: i32,
  inout windows: WindowManager
): WindowMessageRoute on thread.main {
  const current = application.get();
  const permissions = current.permissions;
  const selected = current.capabilitiesForWindow(windowId);
  match (selected) {
    some(capabilities) => return selectWindowMessageRouteWithCapabilities(
      move message,
      in permissions,
      capabilities,
      inout windows
    );
    none => return WindowMessageRoute.framework(bridgeFailure(
      message.id,
      "INVALID_WINDOW",
      "unknown originating window"
    ));
  }
}

function selectWindowMessageRouteWithCapabilities(
  message: BridgeMessage,
  in permissions: ApplicationPermissions,
  selectedCapabilities: CapabilitySelection,
  inout windows: WindowManager
): WindowMessageRoute on thread.main {
  const routed = routeWindowBridgeMessage(
    in message,
    in permissions,
    selectedCapabilities,
    inout windows
  );
  return match (routed) {
    some(response) => WindowMessageRoute.framework(response);
    none => {
      const denied = authorizeServiceInvocation(
        in message,
        selectedCapabilities
      );
      match (denied) {
        some(response) => return WindowMessageRoute.framework(response);
        none => {}
      }
      select WindowMessageRoute.service(move message);
    }
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
  in options: WindowOptions,
  capabilitySelection: CapabilitySelection
): MacOSWindowRuntime throws WindowError on thread.main {
  const contentController = native.WKUserContentController.alloc().init();
  const handler = new DesktopMessageHandler({ windowId: nativeId });
  const handlerName = native.NSString.alloc().initWithUTF8String("zapp");
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
  const configuration = native.WKWebViewConfiguration.alloc().init();
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
  const configured = native.zapp_desktop_window_configure(
    id,
    nativeId
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
    contentController: contentController
  );
  const started = native.zapp_desktop_window_start(id);
  if (started != 0) {
    native.zapp_desktop_window_discard(id);
    throw WindowError({
      id: copy id,
      message: `could not realize native window (status ${started})`,
    });
  }
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
    registration,
    pendingRequests: createPendingRequests(),
    capabilitySelection,
  });
}

internal function initializeMacOSApplicationRuntime(
  name: String,
  permissions: ApplicationPermissions,
  capabilities: ApplicationCapabilities,
  services: AsyncServices,
  updates: TaskScope,
  eventUpdates: TaskScope,
  windowManager: WindowManager
): OnceLifetime<MacOSApplicationRuntime> on thread.main {
  const value = new MacOSApplicationRuntime({
    name: move name,
    permissions,
    capabilities,
    services: move services,
    updates,
    eventUpdates,
    windowManager,
    nativeWindows: Map<i32, MacOSWindowRuntime>(),
    nextNativeWindowId: 1,
  });
  return application.initialize(move value);
}
