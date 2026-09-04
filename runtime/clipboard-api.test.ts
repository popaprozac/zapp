import { expect, test } from "bun:test";
import { Application } from "./application-api";
import { ClipboardError } from "./clipboard-api";
import { errorFromBridgePayload } from "./errors";

const BRIDGE_KEY = Symbol.for("zapp.bridge");
const CONFIG_KEY = Symbol.for("zapp.bootstrapConfig");

test("Application clipboard routes text operations through checked permissions", async () => {
  const previousBridge = (globalThis as any)[BRIDGE_KEY];
  const previousConfig = (globalThis as any)[CONFIG_KEY];
  const invokes: Array<{ method: string; args: Record<string, unknown> }> = [];
  (globalThis as any)[CONFIG_KEY] = {
    permissions: {
      platform: "macos",
      active: true,
      allow: ["clipboard:read", "clipboard:write"],
    },
  };
  (globalThis as any)[BRIDGE_KEY] = {
    on() { return () => {}; },
    invoke(method: string, args: Record<string, unknown>) {
      invokes.push({ method, args });
      const value = method === "__zapp:clipboard:read-text" ? "Z Notes" : null;
      const result = Promise.resolve(value) as Promise<unknown> & { cancel(): void };
      result.cancel = () => {};
      return result;
    },
    emit() {},
  };

  try {
    expect(await Application.current().clipboard.readText()).toBe("Z Notes");
    await Application.current().clipboard.writeText("Draft");
    await Application.current().clipboard.clear();
    expect(invokes).toEqual([
      { method: "__zapp:clipboard:read-text", args: {} },
      { method: "__zapp:clipboard:write-text", args: { text: "Draft" } },
      { method: "__zapp:clipboard:clear", args: {} },
    ]);
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previousBridge;
    (globalThis as any)[CONFIG_KEY] = previousConfig;
  }
});

test("clipboard access is denied before an undeclared request reaches native Z", async () => {
  const previousConfig = (globalThis as any)[CONFIG_KEY];
  (globalThis as any)[CONFIG_KEY] = {
    permissions: { platform: "macos", active: true, allow: [] },
  };
  try {
    await expect(Application.current().clipboard.readText()).rejects.toMatchObject({
      code: "PERMISSION_DENIED",
      permission: "clipboard:read",
    });
  } finally {
    (globalThis as any)[CONFIG_KEY] = previousConfig;
  }
});

test("native clipboard failures restore a focused error", () => {
  const error = errorFromBridgePayload(JSON.stringify({
    code: "CLIPBOARD_ERROR",
    message: "pasteboard rejected text",
    operation: "writeText",
  }));
  expect(error).toBeInstanceOf(ClipboardError);
  expect(error).toMatchObject({
    code: "CLIPBOARD_ERROR",
    operation: "writeText",
  });
});
