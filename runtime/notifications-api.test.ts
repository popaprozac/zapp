import { expect, test } from "bun:test";
import { Application } from "./application-api";
import {
  NotificationError,
  NotificationPermission,
} from "./notifications-api";
import { errorFromBridgePayload } from "./errors";

const BRIDGE_KEY = Symbol.for("zapp.bridge");
const CONFIG_KEY = Symbol.for("zapp.bootstrapConfig");

test("Application notifications use typed permission and delivery routes", async () => {
  const previousBridge = (globalThis as any)[BRIDGE_KEY];
  const previousConfig = (globalThis as any)[CONFIG_KEY];
  const invokes: Array<{ method: string; args: Record<string, unknown> }> = [];
  (globalThis as any)[CONFIG_KEY] = {
    permissions: { platform: "macos", active: true, allow: ["notifications"] },
  };
  (globalThis as any)[BRIDGE_KEY] = {
    on() { return () => {}; },
    invoke(method: string, args: Record<string, unknown>) {
      invokes.push({ method, args });
      const value = method === "__zapp:notifications:show"
        ? "notification-1"
        : "granted";
      const result = Promise.resolve(value) as Promise<unknown> & { cancel(): void };
      result.cancel = () => {};
      return result;
    },
    emit() {},
  };

  try {
    const notifications = Application.current().notifications;
    expect(await notifications.permissionStatus()).toBe(
      NotificationPermission.Granted,
    );
    expect(await notifications.requestPermission()).toBe(
      NotificationPermission.Granted,
    );
    expect(await notifications.show({
      title: "Z Notes",
      body: "Saved",
    })).toBe("notification-1");
    expect(invokes).toEqual([
      { method: "__zapp:notifications:permission-status", args: {} },
      { method: "__zapp:notifications:request-permission", args: {} },
      {
        method: "__zapp:notifications:show",
        args: { title: "Z Notes", body: "Saved" },
      },
    ]);
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previousBridge;
    (globalThis as any)[CONFIG_KEY] = previousConfig;
  }
});

test("notification access is denied before reaching native Z", async () => {
  const previousConfig = (globalThis as any)[CONFIG_KEY];
  (globalThis as any)[CONFIG_KEY] = {
    permissions: { platform: "macos", active: true, allow: [] },
  };
  try {
    await expect(
      Application.current().notifications.permissionStatus(),
    ).rejects.toMatchObject({
      code: "PERMISSION_DENIED",
      permission: "notifications",
    });
  } finally {
    (globalThis as any)[CONFIG_KEY] = previousConfig;
  }
});

test("native notification failures restore a focused error", () => {
  const error = errorFromBridgePayload(JSON.stringify({
    code: "NOTIFICATION_ERROR",
    message: "notification center rejected the request",
    operation: "show",
  }));
  expect(error).toBeInstanceOf(NotificationError);
  expect(error).toMatchObject({
    code: "NOTIFICATION_ERROR",
    operation: "show",
  });
});
