import { expect, test } from "bun:test";
import { currentWindow, createWindow } from "./window-api";
import { Command, applicationMenu, MenuRole } from "./menu-api";

test("context menu response owns exactly one action and preserves the application menu", async () => {
  const bridgeKey = Symbol.for("zapp.bridge");
  const windowKey = Symbol.for("zapp.windowId");
  const previousBridge = (globalThis as any)[bridgeKey];
  const previousWindow = (globalThis as any)[windowKey];
  const calls: any[] = [];
  let handler: (payload: any) => void = () => {};
  let resolvePopup: (value: any) => void = () => {};
  let rejectPopup: (error: Error) => void = () => {};
  (globalThis as any)[windowKey] = "origin";
  (globalThis as any)[bridgeKey] = {
    on(_name: string, action: typeof handler) { handler = action; return () => {}; },
    invoke(method: string, args: any, options: any) {
      calls.push({ method, args, options });
      if (method === "__zapp:menu:popup") {
        return new Promise((resolve, reject) => { resolvePopup = resolve; rejectPopup = reject; });
      }
      return Promise.resolve(method === "__window:create" ? { windowId: "other" } : null);
    },
  };
  try {
    let actions = 0;
    const command = new Command({ label: "Save", action: () => { actions++; } });
    await applicationMenu.set([{ command }]);
    const applicationToken = calls[0].args.ownerToken;
    const popup = currentWindow().showContextMenu([{ command }], { x: 10, y: 20 });
    const presentation = calls.at(-1);
    expect(presentation.options).toEqual({ timeout: 0 });
    expect(presentation.args.windowId).toBe("origin");
    handler({ ownerToken: presentation.args.ownerToken, commandId: command._id });
    expect(actions).toBe(0); // No out-of-band popup click delivery.
    await command.setState("on");
    expect(calls.slice(-2).map((call) => call.args.ownerToken)).toEqual([
      applicationToken, presentation.args.ownerToken,
    ]);
    resolvePopup({ commandId: command._id });
    await popup;
    expect(actions).toBe(1);
    handler({ ownerToken: presentation.args.ownerToken, commandId: command._id });
    expect(actions).toBe(1);
    handler({ ownerToken: applicationToken, commandId: command._id });
    expect(actions).toBe(2);
    const beforeUpdate = calls.length;
    await command.setEnabled(false);
    expect(calls.slice(beforeUpdate)).toHaveLength(1);
    expect(calls.at(-1).args.ownerToken).toBe(applicationToken);

    const dismissed = currentWindow().showContextMenu([{ command }], { x: 0, y: 0 });
    resolvePopup({ commandId: "" });
    await dismissed;
    expect(actions).toBe(2);

    const failed = currentWindow().showContextMenu([{ command }], { x: 0, y: 0 });
    rejectPopup(new Error("window closed"));
    await expect(failed).rejects.toThrow("window closed");
    const invalid = currentWindow().showContextMenu([{ command }], { x: 0, y: 0 });
    resolvePopup({ commandId: "foreign-command" });
    await expect(invalid).rejects.toThrow("unknown command");

    await expect(currentWindow().showContextMenu([{ command }], { x: NaN, y: 1 })).rejects.toThrow("finite");
    await expect(currentWindow().showContextMenu([{ role: MenuRole.Application }], { x: 1, y: 1 })).rejects.toThrow("commands");
    const other = await createWindow();
    await expect(other.showContextMenu([{ command }], { x: 1, y: 1 })).rejects.toThrow("originating");
  } finally {
    (globalThis as any)[bridgeKey] = previousBridge;
    (globalThis as any)[windowKey] = previousWindow;
  }
});

test("popup completion does not await the selected asynchronous action", async () => {
  const key = Symbol.for("zapp.bridge");
  const windowKey = Symbol.for("zapp.windowId");
  const previous = (globalThis as any)[key];
  const previousWindow = (globalThis as any)[windowKey];
  (globalThis as any)[windowKey] = "origin";
  (globalThis as any)[key] = {
    on() { return () => {}; },
    invoke(_method: string, args: any) { return Promise.resolve({ commandId: args.items[0].commandId }); },
  };
  try {
    let invoked = false;
    await currentWindow().showContextMenu([{
      label: "Work", action: () => { invoked = true; return new Promise(() => {}); },
    }], { x: 1, y: 1 });
    expect(invoked).toBe(true);
  } finally {
    (globalThis as any)[key] = previous;
    (globalThis as any)[windowKey] = previousWindow;
  }
});

test("a retiring popup does not fail an already queued command update", async () => {
  const key = Symbol.for("zapp.bridge");
  const windowKey = Symbol.for("zapp.windowId");
  const previous = (globalThis as any)[key];
  const previousWindow = (globalThis as any)[windowKey];
  let dismiss: (value: unknown) => void = () => {};
  let retireUpdate: (error: Error) => void = () => {};
  (globalThis as any)[windowKey] = "origin";
  (globalThis as any)[key] = {
    on() { return () => {}; },
    invoke(method: string) {
      if (method === "__zapp:menu:popup") return new Promise((resolve) => { dismiss = resolve; });
      return new Promise((_resolve, reject) => { retireUpdate = reject; });
    },
  };
  try {
    const command = new Command({ label: "Save", action: () => {} });
    const popup = currentWindow().showContextMenu([{ command }], { x: 1, y: 1 });
    const update = command.setState("on");
    dismiss({ commandId: "" });
    await popup;
    retireUpdate(new Error("frontend menu registration is no longer active"));
    await update;
    expect(command.state).toBe("on");
  } finally {
    (globalThis as any)[key] = previous;
    (globalThis as any)[windowKey] = previousWindow;
  }
});
