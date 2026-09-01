import json from "std/json";
import { thread } from "std/thread";
import {
  BridgeMessage,
  BridgeMessageKind,
  BridgeResponse,
  bridgeCapabilityFailure,
  bridgeFailure,
  bridgePermissionFailure,
  bridgeSuccess,
} from "./bridge.zs";
import { ApplicationPermissions } from "./application-permissions.zs";
import { CapabilitySelection } from "./application-capabilities.zs";
import {
  WindowManager,
  WindowOptions,
} from "./window.zs";

// This is intentionally narrower than WindowOptions. Web content can request
// ordinary presentation details, but trusted injection profiles remain native
// application policy and never enter this decoded shape.
readonly struct FrontendWindowOptions {
  title: String = "";
  url: String = "/";
  width: u32 = 900;
  height: u32 = 640;
  visible: boolean = true;
  resizable: boolean = true;
}

readonly struct FrontendWindowCreated {
  windowId: String;
}

readonly struct FrontendWindowAction {
  windowId: String;
}

readonly struct FrontendWindowTitleAction {
  windowId: String;
  title: String;
}

readonly struct FrontendWindowList {
  ids: Array<String>;
}

export enum WindowBridgeRoute {
  response BridgeResponse,
  handled,
  unhandled,
}

readonly struct WindowBridgeError {
  code: String;
  message: String;
  operation: String;
}

function windowFailure(
  id: u64,
  operation: String,
  message: String
): BridgeResponse {
  const error = WindowBridgeError({
    code: "WINDOW_ERROR",
    message: move message,
    operation: move operation,
  });
  return BridgeResponse({ id, ok: false, payload: json.encode(in error) });
}

function rejectsTrustedWindowPolicy(in source: String): boolean {
  const parsed = attempt json.parse(in source);
  match (parsed) {
    success(value) => {
      match (in value) {
        object(fields) => return fields.has("inject") || fields.has("capabilities");
        _ => return false;
      }
    }
    failure(_) => return false;
  }
}

function createWindow(
  in message: BridgeMessage,
  in permissions: ApplicationPermissions,
  capabilities: CapabilitySelection,
  inout windows: WindowManager
): BridgeResponse on thread.main {
  if (!permissions.windowCreate) {
    return bridgePermissionFailure(message.id, "window:create");
  }
  if (!capabilities.allowsPermission("window:create")) {
    return bridgeCapabilityFailure(message.id, "window:create");
  }
  if (rejectsTrustedWindowPolicy(in message.arguments)) {
    return bridgeFailure(
      message.id,
      "INVALID_ARGUMENTS",
      "INVALID_WINDOW_OPTIONS: inject and capabilities are native application policy"
    );
  }

  const decoded = attempt json.decode<FrontendWindowOptions>(
    in message.arguments
  );
  return match (decoded) {
    failure(error) => bridgeFailure(
      message.id,
      "INVALID_ARGUMENTS",
      `INVALID_WINDOW_OPTIONS: ${error.message}`
    );
    success(options) => {
      const created = attempt windows.create(WindowOptions({
        title: copy options.title,
        url: copy options.url,
        width: options.width,
        height: options.height,
        visible: options.visible,
        resizable: options.resizable,
        capabilities: capabilities.copyNames(),
      }));
      select match (created) {
        success(window) => {
          const result = FrontendWindowCreated({
            windowId: copy window.id,
          });
          const payload: String = json.encode(in result);
          select bridgeSuccess(message.id, move payload);
        }
        failure(error) => windowFailure(
          message.id,
          "create",
          copy error.message
        );
      };
    }
  };
}

function listWindows(
  in message: BridgeMessage,
  in windows: WindowManager
): BridgeResponse on thread.main {
  const open = windows.all();
  let ids = Array<String>();
  for (const window of open) {
    ids.push(copy window.id);
  }
  const result = FrontendWindowList({ ids });
  const payload: String = json.encode(in result);
  return bridgeSuccess(message.id, move payload);
}

function routeWindowAction(
  in message: BridgeMessage,
  inout windows: WindowManager
): boolean on thread.main {
  if (message.method == "show") {
    const decoded = attempt json.decode<FrontendWindowAction>(
      in message.arguments
    );
    match (decoded) {
      success(action) => windows.show(in action.windowId);
      failure(_) => {}
    }
    return true;
  }
  if (message.method == "hide") {
    const decoded = attempt json.decode<FrontendWindowAction>(
      in message.arguments
    );
    match (decoded) {
      success(action) => windows.hide(in action.windowId);
      failure(_) => {}
    }
    return true;
  }
  if (message.method == "close") {
    const decoded = attempt json.decode<FrontendWindowAction>(
      in message.arguments
    );
    match (decoded) {
      success(action) => windows.close(in action.windowId);
      failure(_) => {}
    }
    return true;
  }
  if (message.method == "setTitle") {
    const decoded = attempt json.decode<FrontendWindowTitleAction>(
      in message.arguments
    );
    match (decoded) {
      success(action) => windows.setTitle(
        in action.windowId,
        copy action.title
      );
      failure(_) => {}
    }
    return true;
  }
  return false;
}

export function routeWindowBridgeMessage(
  in message: BridgeMessage,
  in permissions: ApplicationPermissions,
  capabilities: CapabilitySelection,
  inout windows: WindowManager
): WindowBridgeRoute on thread.main {
  if (message.kind == BridgeMessageKind.action) {
    if (routeWindowAction(in message, inout windows)) {
      return WindowBridgeRoute.handled;
    }
    return WindowBridgeRoute.unhandled;
  }
  if (message.kind != BridgeMessageKind.invoke) {
    return WindowBridgeRoute.unhandled;
  }
  if (message.method == "__window:create") {
    return WindowBridgeRoute.response(createWindow(
      in message,
      in permissions,
      capabilities,
      inout windows
    ));
  }
  if (message.method == "__zapp:windows-list") {
    return WindowBridgeRoute.response(listWindows(in message, in windows));
  }
  return WindowBridgeRoute.unhandled;
}
