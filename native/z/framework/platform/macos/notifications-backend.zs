import { thread } from "std/thread";
import native from "zapp_user_notifications.h";
import {
  NotificationBackend,
  NotificationError,
  NotificationOperation,
  NotificationOptions,
  NotificationPermission,
  NotificationPermissionOperation,
  NotificationShowOperation,
} from "../../notifications.zs";

function notificationError(
  operation: NotificationOperation,
  error: native.NSError
): NotificationError {
  const message: String = error.localizedDescription;
  return NotificationError({ operation, message: move message });
}

function macOSPermission(
  status: native.UNAuthorizationStatus
): NotificationPermission {
  if (status == native.UNAuthorizationStatusDenied) {
    return NotificationPermission.denied;
  }
  if (status == native.UNAuthorizationStatusAuthorized) {
    return NotificationPermission.granted;
  }
  if (status == native.UNAuthorizationStatusProvisional) {
    return NotificationPermission.provisional;
  }
  return NotificationPermission.notDetermined;
}

async function macOSPermissionStatus(
): NotificationPermission throws NotificationError on thread.main {
  const center = native.UNUserNotificationCenter.currentNotificationCenter();
  const settings = await center.getNotificationSettingsWithCompletionHandler();
  return macOSPermission(settings.authorizationStatus);
}

function macOSAuthorizationOptions(): native.UNAuthorizationOptions {
  return native.UNAuthorizationOptionAlert
    | native.UNAuthorizationOptionSound;
}

function permissionAfterRequest(granted: boolean): NotificationPermission {
  if (granted) return NotificationPermission.granted;
  return NotificationPermission.denied;
}

async function macOSRequestPermission(
): NotificationPermission throws NotificationError on thread.main {
  const center = native.UNUserNotificationCenter.currentNotificationCenter();
  const requested = attempt await center.requestAuthorizationWithOptions(
    macOSAuthorizationOptions()
  );
  return match (requested) {
    success(granted) => permissionAfterRequest(granted);
    failure(error) => throw notificationError(
      NotificationOperation.requestPermission,
      error
    );
  };
}

function notificationIdentifier(in options: NotificationOptions): String {
  return match (in options.id) {
    some(identifier) => copy identifier;
    none => {
      const uuid = native.NSUUID.UUID();
      const identifier: String = uuid.UUIDString;
      select identifier;
    }
  };
}

function notificationContent(
  in options: NotificationOptions
): native.UNMutableNotificationContent {
  const content = native.UNMutableNotificationContent.alloc().init();
  content.title = options.title;
  match (in options.subtitle) {
    some(subtitle) => content.subtitle = subtitle;
    none => {}
  }
  match (in options.body) {
    some(body) => content.body = body;
    none => {}
  }
  return content;
}

function notificationRequest(
  in options: NotificationOptions,
  in identifier: String
): native.UNNotificationRequest {
  const content = notificationContent(in options);
  return native.UNNotificationRequest.requestWithIdentifier(
    in identifier,
    content: content,
    trigger: null
  );
}

async function macOSShowNotification(
  options: NotificationOptions
): String throws NotificationError on thread.main {
  const identifier = notificationIdentifier(in options);
  const request = notificationRequest(in options, in identifier);
  const center = native.UNUserNotificationCenter.currentNotificationCenter();
  const added = attempt await center.addNotificationRequest(request);
  match (added) {
    success => return identifier;
    failure(error) => throw notificationError(
      NotificationOperation.show,
      error
    );
  }
}

internal function macOSNotificationBackend(
): NotificationBackend on thread.main {
  const permissionStatus: NotificationPermissionOperation = async () =>
    attempt await macOSPermissionStatus();
  const requestPermission: NotificationPermissionOperation = async () =>
    attempt await macOSRequestPermission();
  const show: NotificationShowOperation = async (options) =>
    attempt await macOSShowNotification(move options);
  return NotificationBackend({ permissionStatus, requestPermission, show });
}
