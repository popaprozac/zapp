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
  ShellError,
  ShellManager,
  ShellOperation,
} from "./shell.zs";

readonly struct FrontendOpenExternal {
  url: String;
}

readonly struct ShellBridgeError {
  code: String;
  message: String;
  operation: String;
  url: String;
}

internal type ShellExternalURLPolicy = (
  in profile: String,
  in url: String
) => boolean on thread.main;

export enum ShellBridgeRoute {
  response BridgeResponse,
  unhandled,
}

function shellOperationName(operation: ShellOperation): String {
  return match (operation) {
    openExternal => "openExternal";
  };
}

function shellFailure(
  id: u64,
  in error: ShellError
): BridgeResponse {
  const payload = ShellBridgeError({
    code: "SHELL_ERROR",
    message: copy error.message,
    operation: shellOperationName(error.operation),
    url: copy error.url,
  });
  return BridgeResponse({
    id,
    ok: false,
    payload: json.encode(in payload),
  });
}

function shellPolicyFailure(
  id: u64,
  in profile: String,
  in url: String
): BridgeResponse {
  const error = ShellError({
    operation: ShellOperation.openExternal,
    url: copy url,
    message: `window navigation profile "${profile}" does not allow opening "${url}" externally`,
  });
  return shellFailure(id, in error);
}

export function routeShellBridgeMessage(
  in message: BridgeMessage,
  in permissions: ApplicationPermissions,
  capabilities: CapabilitySelection,
  in navigationProfile: String,
  policy: ShellExternalURLPolicy,
  shell: ShellManager
): ShellBridgeRoute on thread.main {
  if (
    message.kind != BridgeMessageKind.invoke
    || message.method != "__zapp:shell:open-external"
  ) return ShellBridgeRoute.unhandled;
  if (!permissions.shellOpen) {
    return ShellBridgeRoute.response(bridgePermissionFailure(
      message.id,
      "shell:open"
    ));
  }
  if (!capabilities.allowsPermission("shell:open")) {
    return ShellBridgeRoute.response(bridgeCapabilityFailure(
      message.id,
      "shell:open"
    ));
  }
  const decoded = attempt json.decode<FrontendOpenExternal>(
    in message.arguments
  );
  const input = match (decoded) {
    success(value) => value;
    failure(error) => return ShellBridgeRoute.response(shellFailure(
      message.id,
      in ShellError({
        operation: ShellOperation.openExternal,
        url: "",
        message: `invalid external URL request: ${error.message}`,
      })
    ));
  };
  if (!policy(in navigationProfile, in input.url)) {
    return ShellBridgeRoute.response(shellPolicyFailure(
      message.id,
      in navigationProfile,
      in input.url
    ));
  }
  const opened = attempt shell.openExternal(in input.url);
  return match (opened) {
    success => ShellBridgeRoute.response(bridgeSuccess(message.id, "null"));
    failure(error) => ShellBridgeRoute.response(shellFailure(
      message.id,
      in error
    ));
  };
}
