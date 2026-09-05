import json from "std/json";
import { thread } from "std/thread";
import { CapabilitySelection } from "./application-capabilities.zs";
import { ApplicationPermissions } from "./application-permissions.zs";
import {
  BridgeMessage,
  BridgeMessageKind,
  BridgeResponse,
  bridgeCapabilityFailure,
  bridgeFailure,
  bridgePermissionFailure,
  bridgeSuccess,
} from "./bridge.zs";
import {
  NotificationError,
  NotificationManager,
  NotificationOperation,
  NotificationOptions,
  NotificationPermission,
} from "./notifications.zs";

readonly struct FrontendNotificationOptions {
  id: String = "";
  title: String;
  subtitle: String = "";
  body: String = "";
}

readonly struct NotificationBridgeError {
  code: String;
  message: String;
  operation: String;
}

export enum NotificationBridgeRoute {
  response BridgeResponse,
  unhandled BridgeMessage,
}

function notificationOperationName(operation: NotificationOperation): String {
  return match (operation) {
    permissionStatus => "permissionStatus";
    requestPermission => "requestPermission";
    show => "show";
  };
}

function notificationPermissionName(
  permission: NotificationPermission
): String {
  return match (permission) {
    notDetermined => "notDetermined";
    denied => "denied";
    granted => "granted";
    provisional => "provisional";
  };
}

function notificationFailure(
  id: u64,
  in error: NotificationError
): BridgeResponse {
  const payload = NotificationBridgeError({
    code: "NOTIFICATION_ERROR",
    message: copy error.message,
    operation: notificationOperationName(error.operation),
  });
  return BridgeResponse({
    id,
    ok: false,
    payload: json.encode(in payload),
  });
}

function notificationPermissionSuccess(
  id: u64,
  permission: NotificationPermission
): BridgeResponse {
  const payload = json.JsonValue.string(notificationPermissionName(permission));
  return bridgeSuccess(id, json.stringify(in payload));
}

function notificationShowSuccess(
  id: u64,
  identifier: String
): BridgeResponse {
  const payload = json.JsonValue.string(move identifier);
  return bridgeSuccess(id, json.stringify(in payload));
}

function notificationOptions(
  value: FrontendNotificationOptions
): NotificationOptions {
  const { id, title, subtitle, body } = move value;
  return NotificationOptions({
    id: optionalNotificationText(move id),
    title: move title,
    subtitle: optionalNotificationText(move subtitle),
    body: optionalNotificationText(move body),
  });
}

function optionalNotificationText(value: String): Option<String> {
  if (value.byteLength == 0) return Option<String>.none;
  return Option.some(move value);
}

async function notificationPermissionStatus(
  message: BridgeMessage,
  notifications: NotificationManager
): NotificationBridgeRoute on thread.main {
  const status = attempt await notifications.permissionStatus();
  const response = match (status) {
    success(permission) => notificationPermissionSuccess(
      message.id,
      permission
    );
    failure(error) => notificationFailure(message.id, in error);
  };
  return NotificationBridgeRoute.response(move response);
}

async function requestNotificationPermission(
  message: BridgeMessage,
  notifications: NotificationManager
): NotificationBridgeRoute on thread.main {
  const status = attempt await notifications.requestPermission();
  const response = match (status) {
    success(permission) => notificationPermissionSuccess(
      message.id,
      permission
    );
    failure(error) => notificationFailure(message.id, in error);
  };
  return NotificationBridgeRoute.response(move response);
}

async function showNotification(
  message: BridgeMessage,
  notifications: NotificationManager
): NotificationBridgeRoute on thread.main {
  const decoded = attempt json.decode<FrontendNotificationOptions>(
    in message.arguments
  );
  const options = match (decoded) {
    success(value) => notificationOptions(move value);
    failure(error) => return NotificationBridgeRoute.response(bridgeFailure(
      message.id,
      "INVALID_NOTIFICATION",
      `invalid notification options: ${error.message}`
    ));
  };
  const shown = attempt await notifications.show(move options);
  const response = match (shown) {
    success(identifier) => notificationShowSuccess(
      message.id,
      move identifier
    );
    failure(error) => notificationFailure(message.id, in error);
  };
  return NotificationBridgeRoute.response(move response);
}

function isNotificationMethod(in method: String): boolean {
  return method == "__zapp:notifications:permission-status"
    || method == "__zapp:notifications:request-permission"
    || method == "__zapp:notifications:show";
}

export async function routeNotificationBridgeMessage(
  message: BridgeMessage,
  in permissions: ApplicationPermissions,
  capabilities: CapabilitySelection,
  notifications: NotificationManager
): NotificationBridgeRoute on thread.main {
  if (message.kind != BridgeMessageKind.invoke) {
    return NotificationBridgeRoute.unhandled(move message);
  }
  if (!isNotificationMethod(in message.method)) {
    return NotificationBridgeRoute.unhandled(move message);
  }
  if (!permissions.notifications) {
    return NotificationBridgeRoute.response(bridgePermissionFailure(
      message.id,
      "notifications"
    ));
  }
  if (!capabilities.allowsPermission("notifications")) {
    return NotificationBridgeRoute.response(bridgeCapabilityFailure(
      message.id,
      "notifications"
    ));
  }
  if (message.method == "__zapp:notifications:permission-status") {
    return await notificationPermissionStatus(move message, notifications);
  }
  if (message.method == "__zapp:notifications:request-permission") {
    return await requestNotificationPermission(move message, notifications);
  }
  return await showNotification(move message, notifications);
}
