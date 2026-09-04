import { expect, test } from "bun:test";
import * as menuAPI from "./menu-api";
import { Application } from "./application-api";
import {
  Command,
  MenuError,
  MenuRole,
  CommandState,
} from "./menu-api";

const BRIDGE_KEY = Symbol.for("zapp.bridge");
const WINDOW_ID_KEY = Symbol.for("zapp.windowId");

test("focused menu package exposes typed commands, roles, and errors", () => {
  expect(Object.keys(menuAPI).sort()).toEqual([
    "Command",
    "CommandState",
    "MenuError",
    "MenuRole",
    "applicationMenu",
  ]);
  expect(MenuRole).toMatchObject({
    Application: "application",
    Quit: "quit",
    Copy: "copy",
  });
  expect(new MenuError({ message: "invalid" }).code).toBe("MENU_ERROR");
});

test("failed native command updates leave local command state unchanged", async () => {
  const previousBridge = (globalThis as any)[BRIDGE_KEY];
  const previousWindowId = (globalThis as any)[WINDOW_ID_KEY];
  let rejectUpdates = false;
  (globalThis as any)[BRIDGE_KEY] = {
    on() { return () => {}; },
    invoke(method: string) {
      const result = (
        rejectUpdates && (
          method === "__zapp:menu:set-enabled"
          || method === "__zapp:menu:set-state"
        )
          ? Promise.reject(new Error("native update rejected"))
          : Promise.resolve(null)
      ) as Promise<unknown> & { cancel(): void };
      result.cancel = () => {};
      return result;
    },
    emit() {},
  };
  (globalThis as any)[WINDOW_ID_KEY] = "win-menu-transaction";

  try {
    const command = new Command({ label: "Save", action: () => {} });
    await Application.current().menu.set([{ command }]);
    rejectUpdates = true;
    expect(command.enabled).toBe(true);
    await expect(command.setEnabled(false)).rejects.toThrow("native update rejected");
    expect(command.enabled).toBe(true);
    expect(command.state).toBe(CommandState.Off);
    await expect(command.setState(CommandState.On)).rejects.toThrow(
      "native update rejected",
    );
    expect(command.state).toBe(CommandState.Off);
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previousBridge;
    (globalThis as any)[WINDOW_ID_KEY] = previousWindowId;
  }
});

test("Application menu owns opaque callbacks and ignores stale generations", async () => {
  const previousBridge = (globalThis as any)[BRIDGE_KEY];
  const previousWindowId = (globalThis as any)[WINDOW_ID_KEY];
  const listeners: Record<string, Array<(payload: unknown) => void>> = {};
  const invokes: Array<{ method: string; args: Record<string, unknown> }> = [];
  (globalThis as any)[BRIDGE_KEY] = {
    on(name: string, handler: (payload: unknown) => void) {
      (listeners[name] ??= []).push(handler);
      return () => {};
    },
    invoke(method: string, args: Record<string, unknown>) {
      invokes.push({ method, args });
      const result = Promise.resolve(null) as Promise<unknown> & { cancel(): void };
      result.cancel = () => {};
      return result;
    },
    emit() {},
  };
  (globalThis as any)[WINDOW_ID_KEY] = "win-menu";

  try {
    let invoked = 0;
    const shared = new Command({
      label: "New Note",
      shortcut: "Primary+N",
      state: CommandState.On,
      action: async ({ command }) => {
        expect(command).toBe(shared);
        invoked += 1;
      },
    });
    await Application.current().menu.set([
      { role: MenuRole.Application },
      {
        label: "File",
        items: [
          { command: shared },
          { command: shared },
          { type: "separator" },
          { label: "Inline", action: () => { invoked += 10; } },
        ],
      },
      { role: MenuRole.Edit },
      { role: MenuRole.Window },
    ]);

    const installed = invokes[0];
    expect(installed.method).toBe("__zapp:menu:set");
    const ownerToken = installed.args.ownerToken as string;
    const items = installed.args.items as any[];
    const commands = items[1].items;
    expect(commands[0].commandId).toBe(commands[1].commandId);
    expect(commands[0]).toMatchObject({
      kind: "command",
      label: "New Note",
      shortcut: "Primary+N",
      enabled: true,
      state: "on",
    });

    for (const handler of listeners["__zapp:menu-command"] ?? []) {
      handler({ ownerToken, commandId: commands[0].commandId });
    }
    await Promise.resolve();
    expect(invoked).toBe(1);

    await shared.setEnabled(false);
    expect(invokes.at(-1)).toEqual({
      method: "__zapp:menu:set-enabled",
      args: {
        ownerToken,
        commandId: commands[0].commandId,
        enabled: false,
      },
    });

    await shared.setState(CommandState.Mixed);
    expect(invokes.at(-1)).toEqual({
      method: "__zapp:menu:set-state",
      args: {
        ownerToken,
        commandId: commands[0].commandId,
        state: "mixed",
      },
    });
    expect(shared.state).toBe(CommandState.Mixed);

    await Application.current().menu.set([
      { label: "Replacement", action: () => { invoked += 100; } },
    ]);
    for (const handler of listeners["__zapp:menu-command"] ?? []) {
      handler({ ownerToken, commandId: commands[0].commandId });
    }
    await Promise.resolve();
    expect(invoked).toBe(1);
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previousBridge;
    (globalThis as any)[WINDOW_ID_KEY] = previousWindowId;
  }
});

test("package exports focused application and menu facades", async () => {
  const manifest = await Bun.file(
    new URL("./package.json", import.meta.url),
  ).json() as { exports: Record<string, string> };
  expect(manifest.exports["./application"]).toBe("./application-api.ts");
  expect(manifest.exports["./menu"]).toBe("./menu-public.ts");
  const publicMenu = await import("./menu-public");
  expect(Object.keys(publicMenu).sort()).toEqual([
    "Command",
    "CommandState",
    "MenuError",
    "MenuRole",
  ]);
});
