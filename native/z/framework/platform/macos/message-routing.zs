import { ApplicationPermissions } from "../../application-permissions.zs";
import { CapabilitySelection } from "../../application-capabilities.zs";
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
import { TaskControl } from "std/async";
import { thread } from "std/thread";
import { WindowManager } from "../../window.zs";
import {
  WindowBridgeRoute,
  routeWindowBridgeMessage,
} from "../../window-bridge.zs";
import {
  ApplicationWorkerBridgeRoute,
  routeApplicationWorkerBridgeMessage,
} from "../../worker-bridge.zs";
import { ApplicationWorkers } from "../../worker/application-workers.zs";
import { ApplicationMenu } from "../../application-menu.zs";
import { ClipboardManager } from "../../clipboard.zs";
import {
  ClipboardBridgeRoute,
  routeClipboardBridgeMessage,
} from "../../clipboard-bridge.zs";
import {
  NotificationBridgeRoute,
  routeNotificationBridgeMessage,
} from "../../notifications-bridge.zs";
import {
  FrontendMenuCommandDispatch,
  MenuBridgeRoute,
  routeMenuBridgeMessage,
} from "../../menu-bridge.zs";
import { currentMacOSApplication } from "./application-runtime.zs";

enum WindowMessageRoute {
  framework BridgeResponse,
  handled,
  service BridgeMessage,
}

function deliverInvalidWindowResponse(
  messageId: u64,
  windowId: i32
): void on thread.main {
  const response = bridgeFailure(
    messageId,
    "INVALID_WINDOW",
    "unknown originating window"
  );
  deliverResponse(in response, windowId);
}

export c function zapp_route_message_owned(
  message: String,
  windowId: i32
): void {
  const current = currentMacOSApplication();
  const updates = current.updates;
  const routed = updates.schedule(
    thread.main,
    async move (): void => routeMessageOnMain(move message, windowId)
  );
  if (!routed.accepted) return;
}

internal function routeMessageOnMain(
  message: String,
  windowId: i32
): void on thread.main {
  const current = currentMacOSApplication();
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
      deliverResponse(in failure, windowId);
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
    deliverResponse(in failure, windowId);
  }
}

function attachPendingRequest(
  windowId: i32,
  id: u64,
  control: TaskControl
): void on thread.main {
  const current = currentMacOSApplication();
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
  const current = currentMacOSApplication();
  const permissions = current.permissions;
  const notifications = current.notifications;
  const selected = current.capabilitiesForWindow(windowId);
  const capabilities = match (selected) {
    some(value) => value;
    none => {
      if (tracked) finishPendingRequest(windowId, requestId, generation);
      deliverInvalidWindowResponse(message.id, windowId);
      return true;
    }
  };
  const notificationRoute = await routeNotificationBridgeMessage(
    move message,
    in permissions,
    capabilities,
    notifications
  );
  const delivered = await routeAfterNotificationMessageAndDeliver(
    move notificationRoute,
    services,
    windowId,
    requestId,
    generation,
    tracked
  );
  return delivered;
}

async function routeAfterNotificationMessageAndDeliver(
  route: NotificationBridgeRoute,
  services: AsyncServices,
  windowId: i32,
  requestId: u64,
  generation: u64,
  tracked: boolean
): boolean on thread.main {
  const current = currentMacOSApplication();
  const forwarded = match (route) {
    response(value) => {
      if (tracked) finishPendingRequest(windowId, requestId, generation);
      deliverResponse(in value, windowId);
      return true;
    }
    unhandled(value) => value;
  };
  let windows = current.windowManager;
  const windowRoute = selectWindowMessageRoute(
    move forwarded,
    windowId,
    inout windows
  );
  match (windowRoute) {
    framework(response) => {
      if (tracked) finishPendingRequest(windowId, requestId, generation);
      deliverResponse(in response, windowId);
      return true;
    }
    handled => return true;
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
  const current = currentMacOSApplication();
  const permissions = current.permissions;
  const selected = current.capabilitiesForWindow(windowId);
  const workers = current.applicationWorkers;
  const menu = current.menu;
  const clipboard = current.clipboard;
  const logicalId = current.logicalWindowId(windowId);
  match (selected) {
    some(capabilities) => match (logicalId) {
      some(windowName) => return selectWindowMessageRouteWithCapabilities(
        move message,
        in permissions,
        capabilities,
        workers,
        windowId,
        in windowName,
        clipboard,
        menu,
        inout windows
      );
      none => return WindowMessageRoute.framework(bridgeFailure(
        message.id,
        "INVALID_WINDOW",
        "unknown originating window"
      ));
    }
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
  workers: ApplicationWorkers,
  nativeWindowId: i32,
  in logicalWindowId: String,
  clipboard: ClipboardManager,
  menu: ApplicationMenu,
  inout windows: WindowManager
): WindowMessageRoute on thread.main {
  const clipboardRoute = routeClipboardBridgeMessage(
    in message,
    in permissions,
    selectedCapabilities,
    clipboard
  );
  match (clipboardRoute) {
    response(value) => return WindowMessageRoute.framework(value);
    unhandled => {}
  }
  const dispatch: FrontendMenuCommandDispatch = deliverFrontendMenuCommand;
  const menuRoute = routeMenuBridgeMessage(
    in message,
    in permissions,
    selectedCapabilities,
    nativeWindowId,
    in logicalWindowId,
    dispatch,
    menu
  );
  match (menuRoute) {
    response(value) => return WindowMessageRoute.framework(value);
    unhandled => {}
  }
  const routed = routeWindowBridgeMessage(
    in message,
    in permissions,
    in logicalWindowId,
    selectedCapabilities,
    inout windows
  );
  return match (routed) {
    response(value) => WindowMessageRoute.framework(value);
    handled => WindowMessageRoute.handled;
    unhandled => {
      const workerRoute = routeApplicationWorkerBridgeMessage(
        in message,
        selectedCapabilities,
        workers
      );
      match (workerRoute) {
        response(value) => return WindowMessageRoute.framework(value);
        unhandled => {}
      }
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

function deliverFrontendMenuCommand(
  nativeWindowId: i32,
  in ownerToken: String,
  in commandId: String
): void on thread.main {
  const current = currentMacOSApplication();
  current.deliverMenuCommand(
    nativeWindowId,
    in ownerToken,
    in commandId
  );
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
  const current = currentMacOSApplication();
  return current.beginRequest(windowId, id);
}

function finishPendingRequest(
  windowId: i32,
  id: u64,
  generation: u64
): void on thread.main {
  const current = currentMacOSApplication();
  current.finishRequest(windowId, id, generation);
}

function cancelPendingRequest(
  windowId: i32,
  id: u64
): void on thread.main {
  const current = currentMacOSApplication();
  current.cancelRequest(windowId, id);
}

internal function deliverResponse(
  in response: BridgeResponse,
  windowId: i32
): void on thread.main {
  const current = currentMacOSApplication();
  current.deliverResponse(in response, windowId);
}
