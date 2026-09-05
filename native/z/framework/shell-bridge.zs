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

readonly struct FrontendShellPath {
  path: String;
}

readonly struct ShellBridgeError {
  code: String;
  message: String;
  operation: String;
  target: String;
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
    openPath => "openPath";
    reveal => "reveal";
    trash => "trash";
  };
}

function shellPermissionName(operation: ShellOperation): String {
  return match (operation) {
    openExternal => "shell:open";
    openPath => "shell:open";
    reveal => "shell:reveal";
    trash => "shell:trash";
  };
}

function applicationAllowsShellOperation(
  operation: ShellOperation,
  in permissions: ApplicationPermissions
): boolean {
  return match (operation) {
    openExternal => permissions.shellOpen;
    openPath => permissions.shellOpen;
    reveal => permissions.shellReveal;
    trash => permissions.shellTrash;
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
    target: copy error.target,
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
    target: copy url,
    message: `window navigation profile "${profile}" does not allow opening "${url}" externally`,
  });
  return shellFailure(id, in error);
}

function performShellPathOperation(
  operation: ShellOperation,
  in path: String,
  shell: ShellManager
): void throws ShellError on thread.main {
  match (operation) {
    openPath => try shell.openPath(in path);
    reveal => try shell.reveal(in path);
    trash => try shell.trash(in path);
    openExternal => throw ShellError({
      operation,
      target: copy path,
      message: "an external URL cannot be handled as a filesystem path",
    });
  }
}

function routeShellPathMessage(
  in message: BridgeMessage,
  operation: ShellOperation,
  shell: ShellManager
): ShellBridgeRoute on thread.main {
  const decoded = attempt json.decode<FrontendShellPath>(in message.arguments);
  const input = match (decoded) {
    success(value) => value;
    failure(error) => {
      const invalid = ShellError({
        operation,
        target: "",
        message: `invalid shell path request: ${error.message}`,
      });
      return ShellBridgeRoute.response(shellFailure(message.id, in invalid));
    }
  };
  const operated = attempt performShellPathOperation(
    operation,
    in input.path,
    shell
  );
  return match (operated) {
    success => ShellBridgeRoute.response(bridgeSuccess(message.id, "null"));
    failure(error) => ShellBridgeRoute.response(shellFailure(
      message.id,
      in error
    ));
  };
}

export function routeShellBridgeMessage(
  in message: BridgeMessage,
  in permissions: ApplicationPermissions,
  capabilities: CapabilitySelection,
  in navigationProfile: String,
  policy: ShellExternalURLPolicy,
  shell: ShellManager
): ShellBridgeRoute on thread.main {
  if (message.kind != BridgeMessageKind.invoke) {
    return ShellBridgeRoute.unhandled;
  }
  let operation = ShellOperation.openExternal;
  if (message.method == "__zapp:shell:open-external") {
    operation = ShellOperation.openExternal;
  } else if (message.method == "__zapp:shell:open-path") {
    operation = ShellOperation.openPath;
  } else if (message.method == "__zapp:shell:reveal") {
    operation = ShellOperation.reveal;
  } else if (message.method == "__zapp:shell:trash") {
    operation = ShellOperation.trash;
  } else {
    return ShellBridgeRoute.unhandled;
  }
  const permission = shellPermissionName(operation);
  if (!applicationAllowsShellOperation(operation, in permissions)) {
    return ShellBridgeRoute.response(bridgePermissionFailure(
      message.id,
      move permission
    ));
  }
  if (!capabilities.allowsPermission(in permission)) {
    return ShellBridgeRoute.response(bridgeCapabilityFailure(
      message.id,
      move permission
    ));
  }
  if (operation != ShellOperation.openExternal) {
    return routeShellPathMessage(in message, operation, shell);
  }
  const decoded = attempt json.decode<FrontendOpenExternal>(
    in message.arguments
  );
  const input = match (decoded) {
    success(value) => value;
    failure(error) => {
      const invalid = ShellError({
        operation: ShellOperation.openExternal,
        target: "",
        message: `invalid external URL request: ${error.message}`,
      });
      return ShellBridgeRoute.response(shellFailure(message.id, in invalid));
    }
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
