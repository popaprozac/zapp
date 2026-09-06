import { expect, test } from "bun:test";
import { Application } from "./application-api";

const BRIDGE_KEY = Symbol.for("zapp.bridge");
const CONFIG_KEY = Symbol.for("zapp.bootstrapConfig");

test("focused dialogs map cancellation and selected paths without exposing grants", async () => {
  const previousBridge = (globalThis as any)[BRIDGE_KEY];
  const previousConfig = (globalThis as any)[CONFIG_KEY];
  const invokes: Array<{ method: string; args: Record<string, unknown> }> = [];
  let response: unknown = { cancelled: false, paths: ["/tmp/report.txt"] };
  (globalThis as any)[CONFIG_KEY] = {
    permissions: { platform: "macos", active: true, allow: ["dialog"] },
  };
  (globalThis as any)[BRIDGE_KEY] = {
    on() { return () => {}; },
    invoke(method: string, args: Record<string, unknown>) {
      invokes.push({ method, args });
      const result = Promise.resolve(response) as Promise<unknown> & { cancel(): void };
      result.cancel = () => {};
      return result;
    },
    emit() {},
  };

  try {
    expect(await Application.current().dialogs.openFile({ title: "Report" }))
      .toBe("/tmp/report.txt");
    expect(invokes[0]).toEqual({
      method: "__dialog:open",
      args: {
        title: "Report",
        multiple: false,
        directory: false,
      },
    });

    response = { cancelled: false, paths: ["/tmp/a", "/tmp/b"] };
    expect(await Application.current().dialogs.openFiles()).toEqual([
      "/tmp/a",
      "/tmp/b",
    ]);

    response = { cancelled: true };
    expect(await Application.current().dialogs.openDirectory()).toBeNull();
    expect(await Application.current().dialogs.saveFile()).toBeNull();
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previousBridge;
    (globalThis as any)[CONFIG_KEY] = previousConfig;
  }
});

test("focused dialogs reject missing dialog permission before native dispatch", async () => {
  const previousConfig = (globalThis as any)[CONFIG_KEY];
  (globalThis as any)[CONFIG_KEY] = {
    permissions: { platform: "macos", active: true, allow: [] },
  };
  try {
    await expect(Application.current().dialogs.openFile()).rejects.toMatchObject({
      code: "PERMISSION_DENIED",
      permission: "dialog",
    });
  } finally {
    (globalThis as any)[CONFIG_KEY] = previousConfig;
  }
});
