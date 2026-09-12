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
  expect(WindowEvent).toEqual({
    FOCUS: 1,
    BLUR: 2,
    RESIZE: 3,
    NAVIGATION_REQUESTED: 4,
    MINIMIZED: 5,
    UNMINIMIZED: 6,
    MAXIMIZED: 7,
    UNMAXIMIZED: 8,
    FULLSCREEN_ENTERED: 9,
    FULLSCREEN_EXITED: 10,
  });
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
    const navigation: WindowEventSubscription = window.subscribe(
      WindowEvent.NAVIGATION_REQUESTED,
      (payload) => {
        void payload.url;
        void payload.mainFrame;
        void payload.allowedByProfile;
        void payload.cancelled;
      },
    );
    focused.unsubscribe();
    resized.unsubscribe();
    navigation.unsubscribe();
  };
  expect(typeof compile).toBe("function");
});

test("frontend navigation events are observational typed decisions", () => {
  const listeners: Record<string, Array<(value: unknown) => void>> = {};
  const previousBridge = (globalThis as any)[BRIDGE_KEY];
  const previousWindowId = (globalThis as any)[WINDOW_ID_KEY];
  (globalThis as any)[BRIDGE_KEY] = {
    on(name: string, handler: (value: unknown) => void) {
      (listeners[name] ??= []).push(handler);
      return () => {};
    },
    invoke() { return Promise.resolve(undefined); },
    emit() {},
    post() {},
  };
  (globalThis as any)[WINDOW_ID_KEY] = "win-navigation";

  try {
    let observed: unknown;
    currentWindow().subscribe(WindowEvent.NAVIGATION_REQUESTED, (event) => {
      observed = event;
    });
    for (const handler of listeners["window:navigation-requested"] ?? []) {
      handler({
        windowId: "win-navigation",
        url: "https://docs.z-language.com/",
        mainFrame: false,
        allowedByProfile: true,
        cancelled: true,
        ignored: "not projected",
      });
    }
    expect(observed).toEqual({
      windowId: "win-navigation",
      url: "https://docs.z-language.com/",
      mainFrame: false,
      allowedByProfile: true,
      cancelled: true,
    });
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previousBridge;
    (globalThis as any)[WINDOW_ID_KEY] = previousWindowId;
  }
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
    window.focus();
    window.minimize();
    window.unminimize();
    window.maximize();
    window.unmaximize();
    window.setFullscreen(true);
    window.setFullscreen(false);
    window.setTitle("Focused");
    window.close();
    expect(posted.map((message) => JSON.parse(message))).toEqual([
      { t: 4, m: "show", a: { windowId: "win-actions" } },
      { t: 4, m: "hide", a: { windowId: "win-actions" } },
      { t: 4, m: "focus", a: { windowId: "win-actions" } },
      { t: 4, m: "minimize", a: { windowId: "win-actions" } },
      { t: 4, m: "unminimize", a: { windowId: "win-actions" } },
      { t: 4, m: "maximize", a: { windowId: "win-actions" } },
      { t: 4, m: "unmaximize", a: { windowId: "win-actions" } },
      { t: 4, m: "setFullscreen", a: { windowId: "win-actions", fullscreen: true } },
      { t: 4, m: "setFullscreen", a: { windowId: "win-actions", fullscreen: false } },
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

test("minimization subscriptions observe native transitions only and dispose independently", () => {
  const previousBridge = (globalThis as any)[BRIDGE_KEY];
  const previousWindowId = (globalThis as any)[WINDOW_ID_KEY];
  const listeners = new Map<string, Set<(value: unknown) => void>>();
  (globalThis as any)[BRIDGE_KEY] = {
    on(name: string, handler: (value: unknown) => void) {
      const group = listeners.get(name) ?? new Set();
      group.add(handler); listeners.set(name, group);
      return () => group.delete(handler);
    },
    post() {},
    emit() {},
  };
  (globalThis as any)[WINDOW_ID_KEY] = "win-events";
  const deliver = (name: string, value: unknown) => {
    for (const receive of listeners.get(name) ?? []) receive(value);
  };
  try {
    const window = currentWindow();
    const first: unknown[] = [];
    const second: unknown[] = [];
    const restored: unknown[] = [];
    const a = window.subscribe(WindowEvent.MINIMIZED, (event) => first.push(event));
    const b = window.subscribe(WindowEvent.MINIMIZED, (event) => second.push(event));
    const c = window.subscribe(WindowEvent.UNMINIMIZED, (event) => restored.push(event));
    window.minimize(); window.unminimize(); window.focus();
    expect(first).toEqual([]);
    expect(restored).toEqual([]);
    deliver("window:minimized", null);
    deliver("window:minimized", { windowId: "another-window" });
    expect(first).toEqual([]);
    deliver("window:minimized", { windowId: "win-events", ignored: true });
    a.unsubscribe(); a.unsubscribe();
    deliver("window:minimized", { windowId: "win-events" });
    deliver("window:unminimized", { windowId: "win-events", ignored: true });
    expect(first).toEqual([{ windowId: "win-events" }]);
    expect(second).toEqual([{ windowId: "win-events" }, { windowId: "win-events" }]);
    expect(restored).toEqual([{ windowId: "win-events" }]);
    b.unsubscribe(); c.unsubscribe();
    expect([...listeners.values()].every((group) => group.size === 0)).toBe(true);
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previousBridge;
    (globalThis as any)[WINDOW_ID_KEY] = previousWindowId;
  }
});

test("presentation events wait for native delivery, filter identity, and unsubscribe", () => {
  const previousBridge = (globalThis as any)[BRIDGE_KEY];
  const previousWindowId = (globalThis as any)[WINDOW_ID_KEY];
  const listeners = new Map<string, Set<(value: unknown) => void>>();
  (globalThis as any)[BRIDGE_KEY] = {
    on(name: string, receive: (value: unknown) => void) {
      const group = listeners.get(name) ?? new Set();
      group.add(receive);
      listeners.set(name, group);
      return () => group.delete(receive);
    },
    post() {},
  };
  (globalThis as any)[WINDOW_ID_KEY] = "presentation";
  try {
    const window = currentWindow();
    const events: unknown[] = [];
    const subscriptions = [
      window.subscribe(WindowEvent.MAXIMIZED, e => events.push(["maximized", e])),
      window.subscribe(WindowEvent.UNMAXIMIZED, e => events.push(["unmaximized", e])),
      window.subscribe(WindowEvent.FULLSCREEN_ENTERED, e => events.push(["fullscreen-entered", e])),
      window.subscribe(WindowEvent.FULLSCREEN_EXITED, e => events.push(["fullscreen-exited", e])),
    ];
    window.maximize(); window.unmaximize(); window.setFullscreen(true); window.setFullscreen(false);
    expect(events).toEqual([]);
    const names = ["maximized", "unmaximized", "fullscreen-entered", "fullscreen-exited"];
    for (const name of names) {
      for (const receive of listeners.get(`window:${name}`) ?? []) {
        receive(null);
        receive({ windowId: "other" });
        receive({ windowId: "presentation", ignored: true });
      }
    }
    expect(events).toEqual(names.map(name => [name, { windowId: "presentation" }]));
    for (const subscription of subscriptions) {
      subscription.unsubscribe(); subscription.unsubscribe();
    }
    expect([...listeners.values()].every(group => group.size === 0)).toBe(true);
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previousBridge;
    (globalThis as any)[WINDOW_ID_KEY] = previousWindowId;
  }
});

test("window controls preserve the bridge emit fallback without invoking services", () => {
  const previousBridge = (globalThis as any)[BRIDGE_KEY];
  const previousWindowId = (globalThis as any)[WINDOW_ID_KEY];
  const emitted: unknown[] = [];
  (globalThis as any)[BRIDGE_KEY] = {
    emit(name: string, args: unknown) { emitted.push([name, args]); },
    invoke() { throw new Error("window controls are requests, not service invocations"); },
  };
  (globalThis as any)[WINDOW_ID_KEY] = "win-fallback";
  try {
    const window = currentWindow();
    window.focus(); window.minimize(); window.unminimize();
    window.maximize(); window.unmaximize(); window.setFullscreen(false);
    expect(emitted).toEqual([
      ["__window_action:focus", { windowId: "win-fallback" }],
      ["__window_action:minimize", { windowId: "win-fallback" }],
      ["__window_action:unminimize", { windowId: "win-fallback" }],
      ["__window_action:maximize", { windowId: "win-fallback" }],
      ["__window_action:unmaximize", { windowId: "win-fallback" }],
      ["__window_action:setFullscreen", { windowId: "win-fallback", fullscreen: false }],
    ]);
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previousBridge;
    (globalThis as any)[WINDOW_ID_KEY] = previousWindowId;
  }
});
