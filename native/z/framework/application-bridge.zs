import { thread } from "std/thread";
import { ApplicationQuitOperation } from "./application-events.zs";
import { ApplicationPermissions } from "./application-permissions.zs";
import { CapabilitySelection } from "./application-capabilities.zs";
import {
  BridgeMessage,
  BridgeMessageKind,
  BridgeResponse,
  bridgeCapabilityFailure,
  bridgeFailure,
  bridgePermissionFailure,
} from "./bridge.zs";

internal enum ApplicationBridgeRoute {
  response BridgeResponse,
  handled,
  unhandled,
}

// One-way requests only. Neither an arbitrary payload nor a fabricated
// "force" flag can bypass native subscribers or the originating profile.
internal function routeApplicationBridgeMessage(
  in message: BridgeMessage,
  in permissions: ApplicationPermissions,
  capabilities: CapabilitySelection,
  requestQuit: ApplicationQuitOperation
): ApplicationBridgeRoute on thread.main {
  if (message.method != "__zapp:application:quit") {
    return ApplicationBridgeRoute.unhandled;
  }
  if (
    message.kind != BridgeMessageKind.action
    && message.kind != BridgeMessageKind.emit
  ) {
    return ApplicationBridgeRoute.response(bridgeFailure(
      message.id,
      "INVALID_MESSAGE",
      "application quit is a one-way request, not an invocation"
    ));
  }
  if (!permissions.applicationQuit) {
    return ApplicationBridgeRoute.response(bridgePermissionFailure(
      message.id,
      "application:quit"
    ));
  }
  if (!capabilities.allowsPermission("application:quit")) {
    return ApplicationBridgeRoute.response(bridgeCapabilityFailure(
      message.id,
      "application:quit"
    ));
  }
  requestQuit();
  return ApplicationBridgeRoute.handled;
}
