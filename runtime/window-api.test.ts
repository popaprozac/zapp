import { expect, test } from "bun:test";
import * as windowAPI from "./window-api";
import {
  createWindow,
  currentWindow,
  WindowError,
  WindowEvent,
  type WindowEventSubscription,
  type WindowHandle,
} from "./window-api";

const BRIDGE_KEY = Symbol.for("zapp.bridge");
const WINDOW_ID_KEY = Symbol.for("zapp.windowId");

test("focused window package exports only composed runtime values", () => {
  expect(Object.keys(windowAPI).sort()).toEqual([
    "WindowError",
    "WindowEvent",
    "createWindow",
    "currentWindow",
  ]);
  expect(WindowEvent).toEqual({ FOCUS: 1, BLUR: 2, RESIZE: 3 });
  expect("Window" in windowAPI).toBe(false);
});

test("focused WindowHandle retains typed event payloads and subscriptions", () => {
  const compile = (window: WindowHandle) => {
    const focused: WindowEventSubscription = window.subscribe(
      WindowEvent.FOCUS,
      (payload) => void payload.windowId,
    );
    const resized: WindowEventSubscription = window.subscribe(
      WindowEvent.RESIZE,
      (payload) => {
        void payload.size.width;
        // @ts-expect-error Position belongs to a future movement/bounds API.
        void payload.position;
        // @ts-expect-error Delivery time is not part of the native event contract.
        void payload.timestamp;
      },
    );
    focused.unsubscribe();
    resized.unsubscribe();
  };
  expect(typeof compile).toBe("function");
});

test("focused subscriptions project exact Z-aligned event values", () => {
  const listeners: Record<string, Array<(value: unknown) => void>> = {};
  const previousBridge = (globalThis as any)[BRIDGE_KEY];
  const previousWindowId = (globalThis as any)[WINDOW_ID_KEY];
  (globalThis as any)[BRIDGE_KEY] = {
    on(name: string, handler: (value: unknown) => void) {
      (listeners[name] ??= []).push(handler);
      return () => {
        listeners[name] = (listeners[name] ?? []).filter((candidate) => candidate !== handler);
      };
    },
    invoke() { return Promise.resolve(undefined); },
    emit() {},
    post() {},
  };
  (globalThis as any)[WINDOW_ID_KEY] = "win-contract";

  try {
    const window = currentWindow();
    let observed: unknown;
    const subscription = window.subscribe(WindowEvent.RESIZE, (event) => {
      observed = event;
    });
    for (const handler of listeners["window:resize"] ?? []) {
      handler({
        windowId: "win-contract",
        timestamp: 1234,
        size: { width: 720, height: 460 },
        position: {},
      });
    }
    expect(observed).toEqual({
      windowId: "win-contract",
      size: { width: 720, height: 460 },
    });
    subscription.unsubscribe();
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previousBridge;
    (globalThis as any)[WINDOW_ID_KEY] = previousWindowId;
  }
});

test("focused handles send only narrow window actions", () => {
  const posted: string[] = [];
  const previousBridge = (globalThis as any)[BRIDGE_KEY];
  const previousWindowId = (globalThis as any)[WINDOW_ID_KEY];
  (globalThis as any)[BRIDGE_KEY] = {
    on() { return () => {}; },
    invoke() { return Promise.resolve(undefined); },
    emit() {},
    post(message: string) { posted.push(message); },
  };
  (globalThis as any)[WINDOW_ID_KEY] = "win-actions";

  try {
    const window = currentWindow();
    window.show();
    window.hide();
    window.setTitle("Focused");
    window.close();
    expect(posted.map((message) => JSON.parse(message))).toEqual([
      { t: 4, m: "show", a: { windowId: "win-actions" } },
      { t: 4, m: "hide", a: { windowId: "win-actions" } },
      {
        t: 4,
        m: "setTitle",
        a: { windowId: "win-actions", title: "Focused" },
      },
      { t: 4, m: "close", a: { windowId: "win-actions" } },
    ]);
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previousBridge;
    (globalThis as any)[WINDOW_ID_KEY] = previousWindowId;
  }
});

test("focused creation uses the checked bridge and validates its identity", async () => {
  const invokes: Array<{ method: string; args: unknown }> = [];
  const previousBridge = (globalThis as any)[BRIDGE_KEY];
  (globalThis as any)[BRIDGE_KEY] = {
    on() { return () => {}; },
    invoke(method: string, args: unknown) {
      invokes.push({ method, args });
      return Promise.resolve({ windowId: "win-created" });
    },
    emit() {},
  };

  try {
    const window = await createWindow({ title: "Diagnostics", width: 480 });
    expect(window.id).toBe("win-created");
    expect(invokes).toEqual([{
      method: "__window:create",
      args: { title: "Diagnostics", width: 480 },
    }]);

    (globalThis as any)[BRIDGE_KEY].invoke = () => Promise.resolve({});
    await expect(createWindow()).rejects.toBeInstanceOf(WindowError);
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previousBridge;
  }
});

test("package export resolves the focused window facade", async () => {
  const manifest = await Bun.file(
    new URL("./package.json", import.meta.url),
  ).json() as { exports: Record<string, string> };
  expect(manifest.exports["./window"]).toBe("./window-api.ts");
});
