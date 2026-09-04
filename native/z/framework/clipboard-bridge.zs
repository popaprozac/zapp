import json from "std/json";
import { thread } from "std/thread";
import { CapabilitySelection } from "./application-capabilities.zs";
import { ApplicationPermissions } from "./application-permissions.zs";
import {
  BridgeMessage,
  BridgeMessageKind,
  BridgeResponse,
  bridgeCapabilityFailure,
  bridgePermissionFailure,
  bridgeSuccess,
} from "./bridge.zs";
import {
  ClipboardError,
  ClipboardManager,
  ClipboardOperation,
} from "./clipboard.zs";

readonly struct FrontendClipboardText {
  text: String;
}

readonly struct ClipboardBridgeError {
  code: String;
  message: String;
  operation: String;
}

export enum ClipboardBridgeRoute {
  response BridgeResponse,
  unhandled,
}

function clipboardOperationName(operation: ClipboardOperation): String {
  return match (operation) {
    readText => "readText";
    writeText => "writeText";
    clear => "clear";
  };
}

function clipboardFailure(
  id: u64,
  in error: ClipboardError
): BridgeResponse {
  const payload = ClipboardBridgeError({
    code: "CLIPBOARD_ERROR",
    message: copy error.message,
    operation: clipboardOperationName(error.operation),
  });
  return BridgeResponse({
    id,
    ok: false,
    payload: json.encode(in payload),
  });
}

function readClipboardText(
  in message: BridgeMessage,
  clipboard: ClipboardManager
): BridgeResponse on thread.main {
  const read = attempt clipboard.readText();
  match (read) {
    failure(error) => return clipboardFailure(message.id, in error);
    success(value) => {
      match (value) {
        some(text) => {
          const payload = json.JsonValue.string(move text);
          return bridgeSuccess(message.id, json.stringify(in payload));
        }
        none => return bridgeSuccess(message.id, "null");
      }
    }
  }
}

function writeClipboardText(
  in message: BridgeMessage,
  clipboard: ClipboardManager
): BridgeResponse on thread.main {
  const decoded = attempt json.decode<FrontendClipboardText>(
    in message.arguments
  );
  return match (decoded) {
    failure(error) => {
      const invalid = ClipboardError({
        operation: ClipboardOperation.writeText,
        message: `invalid clipboard text: ${error.message}`,
      });
      select clipboardFailure(message.id, in invalid);
    }
    success(input) => {
      const written = attempt clipboard.writeText(in input.text);
      select match (written) {
        success => bridgeSuccess(message.id, "null");
        failure(error) => clipboardFailure(message.id, in error);
      };
    }
  };
}

function clearClipboard(
  in message: BridgeMessage,
  clipboard: ClipboardManager
): BridgeResponse on thread.main {
  const cleared = attempt clipboard.clear();
  return match (cleared) {
    success => bridgeSuccess(message.id, "null");
    failure(error) => clipboardFailure(message.id, in error);
  };
}

function isClipboardMethod(in method: String): boolean {
  return method == "__zapp:clipboard:read-text"
    || method == "__zapp:clipboard:write-text"
    || method == "__zapp:clipboard:clear";
}

function requiredClipboardPermission(in method: String): String {
  if (method == "__zapp:clipboard:read-text") return "clipboard:read";
  return "clipboard:write";
}

export function routeClipboardBridgeMessage(
  in message: BridgeMessage,
  in permissions: ApplicationPermissions,
  capabilities: CapabilitySelection,
  clipboard: ClipboardManager
): ClipboardBridgeRoute on thread.main {
  if (message.kind != BridgeMessageKind.invoke) {
    return ClipboardBridgeRoute.unhandled;
  }
  if (!isClipboardMethod(in message.method)) {
    return ClipboardBridgeRoute.unhandled;
  }
  const permission = requiredClipboardPermission(in message.method);
  if (
    permission == "clipboard:read"
    && !permissions.clipboardRead
  ) {
    return ClipboardBridgeRoute.response(bridgePermissionFailure(
      message.id,
      move permission
    ));
  }
  if (
    permission == "clipboard:write"
    && !permissions.clipboardWrite
  ) {
    return ClipboardBridgeRoute.response(bridgePermissionFailure(
      message.id,
      move permission
    ));
  }
  if (!capabilities.allowsPermission(in permission)) {
    return ClipboardBridgeRoute.response(bridgeCapabilityFailure(
      message.id,
      move permission
    ));
  }
  if (message.method == "__zapp:clipboard:read-text") {
    return ClipboardBridgeRoute.response(readClipboardText(
      in message,
      clipboard
    ));
  }
  if (message.method == "__zapp:clipboard:write-text") {
    return ClipboardBridgeRoute.response(writeClipboardText(
      in message,
      clipboard
    ));
  }
  return ClipboardBridgeRoute.response(clearClipboard(
    in message,
    clipboard
  ));
}
