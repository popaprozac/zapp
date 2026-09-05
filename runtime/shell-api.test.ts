import { expect, test } from "bun:test";
import { Application } from "./application-api";
import { ShellError } from "./shell-api";
import { errorFromBridgePayload } from "./errors";

const BRIDGE_KEY = Symbol.for("zapp.bridge");
const CONFIG_KEY = Symbol.for("zapp.bootstrapConfig");

test("Application shell routes explicit external URLs through the checked bridge", async () => {
  const previousBridge = (globalThis as any)[BRIDGE_KEY];
  const previousConfig = (globalThis as any)[CONFIG_KEY];
  const invokes: Array<{ method: string; args: Record<string, unknown> }> = [];
  (globalThis as any)[CONFIG_KEY] = {
    permissions: {
      platform: "macos",
      active: true,
      allow: ["shell:open", "shell:reveal", "shell:trash"],
    },
  };
  (globalThis as any)[BRIDGE_KEY] = {
    on() { return () => {}; },
    invoke(method: string, args: Record<string, unknown>) {
      invokes.push({ method, args });
      const result = Promise.resolve(null) as Promise<unknown> & { cancel(): void };
      result.cancel = () => {};
      return result;
    },
    emit() {},
  };

  try {
    await Application.current().shell.openExternal("https://z-language.com");
    await Application.current().shell.openPath("$userData/report.txt");
    await Application.current().shell.reveal("$userData/report.txt");
    await Application.current().shell.trash("$userData/report.txt");
    expect(invokes).toEqual([
      {
        method: "__zapp:shell:open-external",
        args: { url: "https://z-language.com" },
      },
      {
        method: "__zapp:shell:open-path",
        args: { path: "$userData/report.txt" },
      },
      {
        method: "__zapp:shell:reveal",
        args: { path: "$userData/report.txt" },
      },
      {
        method: "__zapp:shell:trash",
        args: { path: "$userData/report.txt" },
      },
    ]);
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previousBridge;
    (globalThis as any)[CONFIG_KEY] = previousConfig;
  }
});

test("shell access is denied before an undeclared request reaches native Z", async () => {
  const previousConfig = (globalThis as any)[CONFIG_KEY];
  (globalThis as any)[CONFIG_KEY] = {
    permissions: { platform: "macos", active: true, allow: [] },
  };
  try {
    await expect(
      Application.current().shell.openExternal("https://z-language.com"),
    ).rejects.toMatchObject({
      code: "PERMISSION_DENIED",
      permission: "shell:open",
    });
  } finally {
    (globalThis as any)[CONFIG_KEY] = previousConfig;
  }
});

test("native shell failures restore the focused target and operation", () => {
  const error = errorFromBridgePayload(JSON.stringify({
    code: "SHELL_ERROR",
    message: "window profile denied the URL",
    operation: "openExternal",
    target: "file:///tmp/denied",
  }));
  expect(error).toBeInstanceOf(ShellError);
  expect(error).toMatchObject({
    code: "SHELL_ERROR",
    operation: "openExternal",
    target: "file:///tmp/denied",
  });
});
