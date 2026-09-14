import { RelatedDocumentIdentity, RelatedDocumentRequest } from "../../related-documents.zs";
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
import { ShellManager } from "../../shell.zs";
import {
  ClipboardBridgeRoute,
  routeClipboardBridgeMessage,
} from "../../clipboard-bridge.zs";
import {
  ShellBridgeRoute,
  ShellExternalURLPolicy,
  routeShellBridgeMessage,
} from "../../shell-bridge.zs";
import {
  NotificationBridgeRoute,
  routeNotificationBridgeMessage,
} from "../../notifications-bridge.zs";
import {
  isFileBridgeMessage,
  routeFileBridgeMessage,
} from "../../files-bridge.zs";
import {
  FrontendMenuCommandDispatch,
  MenuBridgeRoute,
  routeMenuBridgeMessage,
  routeContextMenuBridgeMessage,
} from "../../menu-bridge.zs";
import { showMacOSFrontendContextMenu } from "./context-menu-backend.zs";
import { WindowContextMenuOperation } from "../../window.zs";
import { currentMacOSApplication } from "./application-runtime.zs";
import { navigationProfileAllowsExternalURL } from "./navigation-policy.zs";
import { requestMacOSHostQuit } from "./application-host.zs";
import { ApplicationQuitOperation } from "../../application-events.zs";
import {
  ApplicationBridgeRoute,
  routeApplicationBridgeMessage,
} from "../../application-bridge.zs";

enum WindowMessageRoute {
  framework BridgeResponse,
  handled,
  service BridgeMessage,
}

internal function routeMessageOnMain(
  message: String,
  document: RelatedDocumentIdentity
): void on thread.main {
  const current = currentMacOSApplication();
  const documents = current.windows.documents;
  if (!documents.isReady(in document)) return;
  const updates = current.updates;
  const decoded = attempt decodeBridgeMessage(in message);
  const bridgeMessage = match (decoded) {
    success(value) => value;
    failure(error) => {
      const failure = bridgeFailure(0, "INVALID_MESSAGE", copy error.message);
      deliverResponse(in failure, document);
      return;
    }
  };
  if (bridgeMessage.kind == BridgeMessageKind.cancel) {
    documents.cancelRequest(in document, bridgeMessage.id);
    return;
  }
  const tracked = bridgeMessage.kind == BridgeMessageKind.invoke;
  const requestId = bridgeMessage.id;
  let request = RelatedDocumentRequest({ document: copy document, id: requestId, generation: 0 });
  if (tracked) {
    const started = match (documents.beginRequest(in document, requestId)) {
      some(ticket) => ticket;
      none => return;
    };
    request = started;
  }
  const services = current.services;
  const control = updates.schedule(
    thread.main,
    async move (): void => await routeScheduledMessageAndDeliver(move bridgeMessage, services, request, tracked)
  );
  if (tracked) documents.attachRequest(in request, control);
  if (!control.accepted) {
    const failure = bridgeFailure(requestId, "APPLICATION_CLOSING", "Application is closing");
    finishAndDeliverResponse(in failure, in request, tracked);
  }
}

async function routeScheduledMessageAndDeliver(
  message: BridgeMessage,
  services: AsyncServices,
  request: RelatedDocumentRequest,
  tracked: boolean
): void on thread.main {
  const delivered = await routeFrameworkOrServiceMessageAndDeliver(move message, services, request, tracked);
  if (!delivered) return;
}

async function routeFrameworkOrServiceMessageAndDeliver(
  message: BridgeMessage,
  services: AsyncServices,
  request: RelatedDocumentRequest,
  tracked: boolean
): boolean on thread.main {
  const current = currentMacOSApplication();
  const permissions = current.permissions;
  const notifications = current.notifications;
  const selected = current.windows.documents.capabilitiesFor(in request.document);
  const capabilities = match (selected) {
    some(value) => value;
    none => {
      if (tracked) finishPendingRequest(in request);
      // The document is no longer authorized; do not target its replacement.
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
    request,
    tracked
  );
  return delivered;
}

async function routeAfterNotificationMessageAndDeliver(
  route: NotificationBridgeRoute,
  services: AsyncServices,
  request: RelatedDocumentRequest,
  tracked: boolean
): boolean on thread.main {
  const current = currentMacOSApplication();
  const forwarded = match (route) {
    response(value) => {
      finishAndDeliverResponse(in value, in request, tracked);
      return true;
    }
    unhandled(value) => value;
  };
  if (isFileBridgeMessage(in forwarded)) {
    return await routeFileMessageAndDeliver(
      move forwarded,
      request,
      tracked
    );
  }
  return await routeWindowOrServiceMessageAndDeliver(
    move forwarded,
    services,
    request,
    tracked
  );
}

async function routeFileMessageAndDeliver(
  message: BridgeMessage,
  request: RelatedDocumentRequest,
  tracked: boolean
): boolean on thread.main {
  const current = currentMacOSApplication();
  const selected = current.windows.documents.capabilitiesFor(in request.document);
  const capabilities = match (selected) {
    some(value) => value;
    none => {
      if (tracked) finishPendingRequest(in request);
      // The document is no longer authorized; do not target its replacement.
      return true;
    }
  };
  const permissions = current.permissions;
  const files = current.files;
  const response = await routeFileBridgeMessage(
    move message,
    in permissions,
    capabilities,
    files
  );
  finishAndDeliverResponse(in response, in request, tracked);
  return true;
}

async function routeWindowOrServiceMessageAndDeliver(
  message: BridgeMessage,
  services: AsyncServices,
  request: RelatedDocumentRequest,
  tracked: boolean
): boolean on thread.main {
  const current = currentMacOSApplication();
  let windows = current.windowManager;
  const windowRoute = selectWindowMessageRoute(
    move message,
    request,
    inout windows
  );
  match (windowRoute) {
    framework(response) => {
      finishAndDeliverResponse(in response, in request, tracked);
      return true;
    }
    handled => { if (tracked) finishPendingRequest(in request); return true; }
    service(forwarded) => return await routeMessageAndDeliver(
      move forwarded,
      services,
      request,
      tracked
    );
  }
}

function selectWindowMessageRoute(
  message: BridgeMessage,
  request: RelatedDocumentRequest,
  inout windows: WindowManager
): WindowMessageRoute on thread.main {
  const current = currentMacOSApplication();
  const permissions = current.permissions;
  const selected = current.windows.documents.capabilitiesFor(in request.document);
  const workers = current.applicationWorkers;
  const menu = current.menu;
  const clipboard = current.clipboard;
  const shell = current.shell;
  const windowId = request.document.windowId;
  const logicalId = current.windows.logicalWindowId(windowId);
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
        shell,
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
  shell: ShellManager,
  menu: ApplicationMenu,
  inout windows: WindowManager
): WindowMessageRoute on thread.main {
  const quit: ApplicationQuitOperation = requestMacOSHostQuit;
  const applicationRoute = routeApplicationBridgeMessage(
    in message,
    in permissions,
    selectedCapabilities,
    quit
  );
  match (applicationRoute) {
    response(value) => return WindowMessageRoute.framework(value);
    handled => return WindowMessageRoute.handled;
    unhandled => {}
  }
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
  const ownerOptions = windows.options(in logicalWindowId);
  const navigationProfile = match (ownerOptions) {
    some(options) => copy options.navigation;
    none => return WindowMessageRoute.framework(bridgeFailure(
      message.id,
      "INVALID_WINDOW",
      "unknown originating window"
    ));
  };
  const externalURLPolicy: ShellExternalURLPolicy =
    navigationProfileAllowsExternalURL;
  const shellRoute = routeShellBridgeMessage(
    in message,
    in permissions,
    selectedCapabilities,
    in navigationProfile,
    externalURLPolicy,
    shell
  );
  match (shellRoute) {
    response(value) => return WindowMessageRoute.framework(value);
    unhandled => {}
  }
  const dispatch: FrontendMenuCommandDispatch = deliverFrontendMenuCommand;
  const showContextMenu: WindowContextMenuOperation = showMacOSFrontendContextMenu;
  const popupRoute = routeContextMenuBridgeMessage(
    in message, in permissions, selectedCapabilities, nativeWindowId,
    in logicalWindowId, menu, showContextMenu
  );
  match (popupRoute) {
    response(value) => return WindowMessageRoute.framework(value);
    unhandled => {}
  }
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
  current.windows.deliverMenuCommand(
    nativeWindowId,
    in ownerToken,
    in commandId
  );
}

async function routeMessageAndDeliver(
  message: BridgeMessage,
  services: AsyncServices,
  request: RelatedDocumentRequest,
  tracked: boolean
): boolean {
  const routed = await routeDecodedMessageWithServicesAsync(
    move message,
    services
  );
  const delivered = await on thread.main finishAndDeliverRoutedResponse(
    move routed,
    request,
    tracked
  );
  return delivered;
}

async function finishAndDeliverRoutedResponse(
  routed: Option<BridgeResponse>,
  request: RelatedDocumentRequest,
  tracked: boolean
): boolean on thread.main {
  return match (routed) {
    some(response) => {
      finishAndDeliverResponse(in response, in request, tracked);
      select true;
    }
    none => { if (tracked) finishPendingRequest(in request); select false; }
  };
}

function finishPendingRequest(in request: RelatedDocumentRequest): boolean on thread.main {
  const current = currentMacOSApplication();
  return current.windows.documents.finishRequest(in request);
}

function finishAndDeliverResponse(
  in response: BridgeResponse,
  in request: RelatedDocumentRequest,
  tracked: boolean
): void on thread.main {
  if (tracked && !finishPendingRequest(in request)) return;
  deliverResponse(in response, copy request.document);
}

internal function deliverResponse(
  in response: BridgeResponse,
  document: RelatedDocumentIdentity
): void on thread.main {
  const current = currentMacOSApplication();
  current.windows.deliverResponse(in response, document);
}
