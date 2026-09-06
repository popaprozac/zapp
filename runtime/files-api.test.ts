import { expect, test } from "bun:test";
import { Application } from "./application-api";
import { FileError } from "./files-api";
import { errorFromBridgePayload } from "./errors";

const BRIDGE_KEY = Symbol.for("zapp.bridge");
const CONFIG_KEY = Symbol.for("zapp.bootstrapConfig");

test("Application files route checked UTF-8 operations through native Z", async () => {
  const previousBridge = (globalThis as any)[BRIDGE_KEY];
  const previousConfig = (globalThis as any)[CONFIG_KEY];
  const invokes: Array<{ method: string; args: Record<string, unknown> }> = [];
  (globalThis as any)[CONFIG_KEY] = {
    permissions: {
      platform: "macos",
      active: true,
      allow: ["fs:read", "fs:write"],
    },
  };
  (globalThis as any)[BRIDGE_KEY] = {
    on() { return () => {}; },
    invoke(method: string, args: Record<string, unknown>) {
      invokes.push({ method, args });
      const value = method.endsWith("read-text") ? "hello from Z" : null;
      const result = Promise.resolve(value) as Promise<unknown> & { cancel(): void };
      result.cancel = () => {};
      return result;
    },
    emit() {},
  };

  try {
    const source = await Application.current().files.readText("$resources/note.txt");
    await Application.current().files.writeText("$userData/note.txt", source);
    expect(source).toBe("hello from Z");
    expect(invokes).toEqual([
      {
        method: "__zapp:files:read-text",
        args: { path: "$resources/note.txt" },
      },
      {
        method: "__zapp:files:write-text",
        args: { path: "$userData/note.txt", contents: "hello from Z" },
      },
    ]);
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previousBridge;
    (globalThis as any)[CONFIG_KEY] = previousConfig;
  }
});

test("file access is denied before an undeclared request reaches native Z", async () => {
  const previousConfig = (globalThis as any)[CONFIG_KEY];
  (globalThis as any)[CONFIG_KEY] = {
    permissions: { platform: "macos", active: true, allow: ["fs:read"] },
  };
  try {
    await expect(
      Application.current().files.writeText("$userData/note.txt", "denied"),
    ).rejects.toMatchObject({
      code: "PERMISSION_DENIED",
      permission: "fs:write",
    });
  } finally {
    (globalThis as any)[CONFIG_KEY] = previousConfig;
  }
});

test("native file failures restore operation and path", () => {
  const error = errorFromBridgePayload(JSON.stringify({
    code: "FILE_ERROR",
    message: "could not decode UTF-8",
    operation: "readText",
    path: "$resources/invalid.txt",
  }));
  expect(error).toBeInstanceOf(FileError);
  expect(error).toMatchObject({
    code: "FILE_ERROR",
    operation: "readText",
    path: "$resources/invalid.txt",
  });
});
