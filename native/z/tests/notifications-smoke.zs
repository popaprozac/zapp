import { thread } from "std/thread";
import {
  NotificationBackend,
  NotificationError,
  NotificationOptions,
  NotificationPermission,
  NotificationPermissionOperation,
  NotificationShowOperation,
  createNotificationManager,
} from "../framework/notifications.zs";

async function publishPermission(
): NotificationPermission throws NotificationError on thread.main {
  return NotificationPermission.granted;
}

async function publishNotification(
  options: NotificationOptions
): String throws NotificationError on thread.main {
  const identifier: String = "notification-1";
  return identifier;
}

async function main(): i32 throws NotificationError on thread.main {
  let notifications = createNotificationManager();
  const permissionStatus: NotificationPermissionOperation = async () =>
    attempt await publishPermission();
  const requestPermission: NotificationPermissionOperation = async () =>
    attempt await publishPermission();
  const show: NotificationShowOperation = async (options) =>
    attempt await publishNotification(move options);
  notifications.start(NotificationBackend({
    permissionStatus,
    requestPermission,
    show,
  }));
  const current = try await notifications.permissionStatus();
  if (current != NotificationPermission.granted) return 1;
  const requested = try await notifications.requestPermission();
  if (requested != NotificationPermission.granted) return 2;
  const identifier = try await notifications.show(NotificationOptions({
    title: "Z Notes",
    body: Option.some("Saved"),
  }));
  notifications.stop();
  if (identifier != "notification-1") return 3;
  return 0;
}
