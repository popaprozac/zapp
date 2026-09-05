/** Focused frontend API for application-owned system notifications. */

import { getBridge } from "./bridge";
import { NotificationError } from "./notification-errors";
import { ensurePermission } from "./permissions";

export { NotificationError } from "./notification-errors";
export type {
  NotificationErrorPayload,
  NotificationOperation,
} from "./notification-errors";

export const NotificationPermission = Object.freeze({
  NotDetermined: "notDetermined",
  Denied: "denied",
  Granted: "granted",
  Provisional: "provisional",
} as const);

export type NotificationPermission =
  typeof NotificationPermission[keyof typeof NotificationPermission];

export interface NotificationOptions {
  id?: string;
  title: string;
  subtitle?: string;
  body?: string;
}

export interface NotificationManager {
  /** Read the operating system's current notification authorization state. */
  permissionStatus(): Promise<NotificationPermission>;
  /** Ask the operating system for notification authorization. */
  requestPermission(): Promise<NotificationPermission>;
  /** Deliver one text notification and return its stable identifier. */
  show(options: NotificationOptions): Promise<string>;
}

function permissionResult(value: unknown): NotificationPermission {
  if (
    value === NotificationPermission.NotDetermined
    || value === NotificationPermission.Denied
    || value === NotificationPermission.Granted
    || value === NotificationPermission.Provisional
  ) return value;
  throw new NotificationError({
    operation: "permissionStatus",
    message: "native Zapp returned an invalid notification permission state",
  });
}

function identifierResult(value: unknown): string {
  if (typeof value === "string" && value.length > 0) return value;
  throw new NotificationError({
    operation: "show",
    message: "native Zapp returned an invalid notification identifier",
  });
}

/** Stable notification manager used by the focused Application facade. */
export const applicationNotifications: NotificationManager = {
  async permissionStatus(): Promise<NotificationPermission> {
    ensurePermission("notifications");
    return permissionResult(await getBridge().invoke(
      "__zapp:notifications:permission-status",
      {},
    ));
  },

  async requestPermission(): Promise<NotificationPermission> {
    ensurePermission("notifications");
    return permissionResult(await getBridge().invoke(
      "__zapp:notifications:request-permission",
      {},
    ));
  },

  async show(options: NotificationOptions): Promise<string> {
    ensurePermission("notifications");
    return identifierResult(await getBridge().invoke(
      "__zapp:notifications:show",
      {
        id: options.id,
        title: options.title,
        subtitle: options.subtitle,
        body: options.body,
      },
    ));
  },
};
