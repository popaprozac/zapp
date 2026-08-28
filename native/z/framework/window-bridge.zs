import json from "std/json";
import { thread } from "std/thread";
import {
  BridgeMessage,
  BridgeMessageKind,
  BridgeResponse,
  bridgeFailure,
  bridgePermissionFailure,
  bridgeSuccess,
} from "./bridge.zs";
import { ApplicationPermissions } from "./application-permissions.zs";
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

readonly struct FrontendWindowList {
  ids: Array<String>;
}

function rejectsTrustedInjection(in source: String): boolean {
  const parsed = attempt json.parse(in source);
  match (parsed) {
    success(value) => {
      match (in value) {
        object(fields) => return fields.has("inject");
        _ => return false;
      }
    }
    failure(_) => return false;
  }
}

function createWindow(
  in message: BridgeMessage,
  in permissions: ApplicationPermissions,
  inout windows: WindowManager
): BridgeResponse on thread.main {
  if (!permissions.windowCreate) {
    return bridgePermissionFailure(message.id, "window:create");
  }
  if (rejectsTrustedInjection(in message.arguments)) {
    return bridgeFailure(
      message.id,
      "INVALID_ARGUMENTS",
      "INVALID_WINDOW_OPTIONS: inject is native application policy"
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
      }));
      select match (created) {
        success(window) => {
          const result = FrontendWindowCreated({
            windowId: copy window.id,
          });
          const payload: String = json.encode(in result);
          select bridgeSuccess(message.id, move payload);
        }
        failure(error) => bridgeFailure(
          message.id,
          "WINDOW_ERROR",
          `WINDOW_ERROR: ${error.message}`
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

export function routeWindowBridgeMessage(
  in message: BridgeMessage,
  in permissions: ApplicationPermissions,
  inout windows: WindowManager
): Option<BridgeResponse> on thread.main {
  if (message.kind != BridgeMessageKind.invoke) return Option.none;
  if (message.method == "__window:create") {
    return Option.some(createWindow(
      in message,
      in permissions,
      inout windows
    ));
  }
  if (message.method == "__zapp:windows-list") {
    return Option.some(listWindows(in message, in windows));
  }
  return Option.none;
}
