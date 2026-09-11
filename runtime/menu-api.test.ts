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

test("failed menu replacement preserves callbacks and bridge replacement retires them", async () => {
  const previousBridge = (globalThis as any)[BRIDGE_KEY];
  const previousWindowId = (globalThis as any)[WINDOW_ID_KEY];
  const makeBridge = () => {
    const callbacks: Array<(payload: unknown) => void> = [];
    const calls: Array<{ method: string; args: Record<string, unknown> }> = [];
    let rejectSet = false;
    return {
      callbacks, calls,
      rejectNextSet() { rejectSet = true; },
      on(_name: string, callback: (payload: unknown) => void) {
        callbacks.push(callback);
        // Deliberately keep a queued callback to check stale-bridge rejection.
        return () => {};
      },
      async invoke(method: string, args: Record<string, unknown>) {
        calls.push({ method, args });
        if (rejectSet && method === "__zapp:menu:set") {
          rejectSet = false;
          throw new Error("replacement rejected");
        }
        return null;
      },
      emit() {},
    };
  };
  const first = makeBridge();
  const second = makeBridge();
  (globalThis as any)[BRIDGE_KEY] = first;
  (globalThis as any)[WINDOW_ID_KEY] = "win-presentation";
  try {
    let invoked = 0;
    const command = new Command({ label: "Shared", action: () => { invoked++; } });
    await Application.current().menu.set([{ command }]);
    const original = first.calls[0].args;
    const id = (original.items as any[])[0].commandId;
    first.rejectNextSet();
    await expect(Application.current().menu.set([])).rejects.toThrow("replacement rejected");
    first.callbacks[0]({ ownerToken: original.ownerToken, commandId: id });
    expect(invoked).toBe(1);

    (globalThis as any)[BRIDGE_KEY] = second;
    await command.setEnabled(false);
    expect(command.enabled).toBe(false);
    expect(second.calls).toEqual([]); // Never send an old token to a new bridge.
    await Application.current().menu.set([{ command }]);
    const replacement = second.calls[0].args;
    first.callbacks[0]({ ownerToken: replacement.ownerToken, commandId: id });
    expect(invoked).toBe(1);
    second.callbacks[0]({ ownerToken: original.ownerToken, commandId: id });
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
  expect(manifest.exports["./clipboard"]).toBe("./clipboard-public.ts");
  expect(manifest.exports["./files"]).toBe("./files-public.ts");
  expect(manifest.exports["./menu"]).toBe("./menu-public.ts");
  const publicFiles = await import("./files-public");
  expect(Object.keys(publicFiles)).toEqual(["FileError"]);
  const publicMenu = await import("./menu-public");
  expect(Object.keys(publicMenu).sort()).toEqual([
    "Command",
    "CommandState",
    "MenuError",
    "MenuRole",
  ]);
});
