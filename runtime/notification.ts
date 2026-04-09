/**
 * Notification — native notifications with action buttons.
 * Requires: app bundle + code signing (handled by `zapp dev` and `zapp package`).
 *
 * @example
 * ```ts
 * import { Notification } from "@zappdev/runtime";
 *
 * await Notification.requestPermission();
 * await Notification.registerCategory({
 *   id: "message",
 *   actions: [{ id: "reply", title: "Reply" }, { id: "delete", title: "Delete", destructive: true }],
 *   hasReplyField: true,
 * });
 * await Notification.show({ title: "New Message", body: "Hello!", categoryId: "message" });
 * Notification.on("response", (r) => console.log(r.actionId, r.userText));
 * ```
 */

import { getBridge } from "./bridge";
import { Events } from "./events";

export interface NotificationAction {
  id: string;
  title: string;
  destructive?: boolean;
}

export interface NotificationCategory {
  id: string;
  actions: NotificationAction[];
  hasReplyField?: boolean;
  replyPlaceholder?: string;
  replyButtonTitle?: string;
}

export interface NotificationOptions {
  title: string;
  subtitle?: string;
  body?: string;
  /** Sound: "default", "none", or custom sound name. */
  sound?: "default" | "none" | string;
  /** Thread ID for grouping related notifications together. */
  threadId?: string;
  /** Category ID for action buttons (must register category first). */
  categoryId?: string;
  /** Arbitrary user data (returned in response). */
  data?: Record<string, unknown>;
  /** File path or file:// URL for an image/audio/video attachment. */
  attachment?: string;
  /**
   * Explicit notification ID. If provided, can be used to:
   * - Update the notification later with Notification.update()
   * - Remove it with Notification.removeDelivered()
   * If omitted, a UUID is auto-generated.
   */
  id?: string;
}

export interface ScheduleOptions extends NotificationOptions {
  trigger: { seconds: number } | { year?: number; month?: number; day?: number; hour?: number; minute?: number };
}

export interface NotificationResponse {
  id: string;
  actionId: string;    // "DEFAULT" for plain click, or action button ID
  categoryId?: string;
  userText?: string;   // if reply field was used
}

export type PermissionStatus = "granted" | "denied" | "not-determined" | "provisional";

export const Notification = {
  async requestPermission(): Promise<PermissionStatus> {
    const result = await getBridge().invoke("__notif:requestPermission") as { status: string };
    return result.status as PermissionStatus;
  },

  async getPermissionStatus(): Promise<PermissionStatus> {
    const result = await getBridge().invoke("__notif:getPermission") as { status: string };
    return result.status as PermissionStatus;
  },

  async show(options: NotificationOptions): Promise<string> {
    const result = await getBridge().invoke("__notif:show", options as any) as { id: string };
    return result.id;
  },

  async schedule(options: ScheduleOptions): Promise<string> {
    const result = await getBridge().invoke("__notif:schedule", options as any) as { id: string };
    return result.id;
  },

  async registerCategory(category: NotificationCategory): Promise<void> {
    await getBridge().invoke("__notif:registerCategory", category as any);
  },

  async removeCategory(id: string): Promise<void> {
    await getBridge().invoke("__notif:removeCategory", { id } as any);
  },

  async cancel(id: string): Promise<void> {
    await getBridge().invoke("__notif:cancel", { id } as any);
  },

  async cancelAll(): Promise<void> {
    await getBridge().invoke("__notif:cancelAll");
  },

  /** Remove a specific delivered notification from notification center. */
  async removeDelivered(id: string): Promise<void> {
    await getBridge().invoke("__notif:removeDelivered", { id } as any);
  },

  /** Remove all delivered notifications from notification center. */
  async removeAllDelivered(): Promise<void> {
    await getBridge().invoke("__notif:removeAllDelivered");
  },

  /**
   * Update an existing notification's content (replaces by ID).
   * The notification must have been shown with an explicit `id`.
   */
  async update(id: string, options: Partial<NotificationOptions>): Promise<void> {
    await getBridge().invoke("__notif:update", { id, ...options } as any);
  },

  on(event: "click" | "action" | "response", handler: ((response: NotificationResponse) => void) | ((notificationId: string, actionId?: string) => void)): () => void {
    if (event === "response") {
      // Unified handler — fires for both clicks and actions
      const offClick = Events.on("__notif:click", (payload: any) => {
        const data = typeof payload === "string" ? JSON.parse(payload) : payload;
        handler({ id: data.id, actionId: "DEFAULT" } as NotificationResponse);
      });
      const offAction = Events.on("__notif:action", (payload: any) => {
        const data = typeof payload === "string" ? JSON.parse(payload) : payload;
        handler({
          id: data.id,
          actionId: data.action,
          userText: data.userText,
        } as NotificationResponse);
      });
      return () => { offClick(); offAction(); };
    }

    // Legacy click/action handlers
    const eventName = event === "click" ? "__notif:click" : "__notif:action";
    return Events.on(eventName, (payload: any) => {
      const data = typeof payload === "string" ? JSON.parse(payload) : payload;
      handler(data.id, data.action);
    });
  },
};
