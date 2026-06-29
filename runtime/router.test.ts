/**
 * Tests for the router handle: createWindowHandle(...).router, Window.get,
 * Window.all, and ROUTE_CHANGED event wiring.
 *
 * Uses a mock bridge installed on globalThis[Symbol.for("zapp.bridge")]
 * so tests run without a real native layer (same pattern as worker.test.ts).
 */
import { describe, expect, test, beforeEach } from "bun:test";
import { createWindowHandle, Window } from "./window";
import { WindowEvent, eventName } from "./events";

const BRIDGE_KEY = Symbol.for("zapp.bridge");

interface MockBridge {
  posts: string[];
  listeners: Record<string, Array<(data: unknown) => void>>;
  invokes: Array<{ method: string; args: Record<string, unknown> }>;
  invokeResult: unknown;
  on(name: string, handler: (data: unknown) => void): () => void;
  emit(name: string, payload?: Record<string, unknown>): void;
  invoke(method: string, args?: Record<string, unknown>): Promise<unknown>;
  post(msg: string): void;
  // fire is test-only: dispatch an event to all listeners
  fire(name: string, payload: unknown): void;
}

let mock: MockBridge;

beforeEach(() => {
  mock = {
    posts: [],
    listeners: {},
    invokes: [],
    invokeResult: undefined,
    on(name, handler) {
      if (!this.listeners[name]) this.listeners[name] = [];
      this.listeners[name].push(handler);
      return () => {
        this.listeners[name] = (this.listeners[name] || []).filter((h) => h !== handler);
      };
    },
    emit() {},
    invoke(method, args) {
      this.invokes.push({ method, args: args ?? {} });
      return Promise.resolve(this.invokeResult);
    },
    post(msg) {
      this.posts.push(msg);
    },
    fire(name, payload) {
      for (const h of this.listeners[name] || []) {
        try { h(payload); } catch {}
      }
    },
  };
  (globalThis as any)[BRIDGE_KEY] = mock;
});

// ── createWindowHandle tests ──────────────────────────────────────────────────

describe("router handle ops post correct wire messages", () => {
  test("push(string) posts router:push with url only", () => {
    const win = createWindowHandle("win-1");
    win.router.push("/a");
    expect(mock.posts.length).toBe(1);
    const msg = JSON.parse(mock.posts[0]);
    expect(msg).toEqual({ t: 4, m: "router:push", a: { windowId: "win-1", url: "/a" } });
  });

  test("push({url}) posts router:push with url", () => {
    const win = createWindowHandle("win-2");
    win.router.push({ url: "/b" });
    const msg = JSON.parse(mock.posts[0]);
    expect(msg.t).toBe(4);
    expect(msg.m).toBe("router:push");
    expect(msg.a).toEqual({ windowId: "win-2", url: "/b" });
  });

  test("push({url, params}) includes params in the payload", () => {
    const win = createWindowHandle("win-3");
    win.router.push({ url: "/d", params: { id: 42 } });
    const msg = JSON.parse(mock.posts[0]);
    expect(msg.a).toEqual({ windowId: "win-3", url: "/d", params: { id: 42 } });
  });

  test("push({url, title}) includes title in the payload", () => {
    const win = createWindowHandle("win-t");
    win.router.push({ url: "/x", title: "Home" });
    const msg = JSON.parse(mock.posts[0]);
    expect(msg.a.title).toBe("Home");
  });

  test("pop() posts router:pop", () => {
    const win = createWindowHandle("win-4");
    win.router.pop();
    const msg = JSON.parse(mock.posts[0]);
    expect(msg).toEqual({ t: 4, m: "router:pop", a: { windowId: "win-4" } });
  });

  test("forward() posts router:forward", () => {
    const win = createWindowHandle("win-5");
    win.router.forward();
    const msg = JSON.parse(mock.posts[0]);
    expect(msg).toEqual({ t: 4, m: "router:forward", a: { windowId: "win-5" } });
  });

  test("replace(string) posts router:replace with url only", () => {
    const win = createWindowHandle("win-6");
    win.router.replace("/z");
    const msg = JSON.parse(mock.posts[0]);
    expect(msg).toEqual({ t: 4, m: "router:replace", a: { windowId: "win-6", url: "/z" } });
  });

  test("replace({url, params}) includes params", () => {
    const win = createWindowHandle("win-7");
    win.router.replace({ url: "/z", params: { q: "hi" } });
    const msg = JSON.parse(mock.posts[0]);
    expect(msg.a).toEqual({ windowId: "win-7", url: "/z", params: { q: "hi" } });
  });

  test("popToRoot() posts router:popToRoot", () => {
    const win = createWindowHandle("win-8");
    win.router.popToRoot();
    const msg = JSON.parse(mock.posts[0]);
    expect(msg).toEqual({ t: 4, m: "router:popToRoot", a: { windowId: "win-8" } });
  });
});

// ── ROUTE_CHANGED event updates cached getters ────────────────────────────────

describe("ROUTE_CHANGED event updates router getters", () => {
  const EVENT = eventName(WindowEvent.ROUTE_CHANGED); // "window:route-changed"

  test("event for THIS windowId updates url/params/canGoBack/canGoForward", () => {
    const win = createWindowHandle("win-ev");
    // Initial defaults
    expect(win.router.url).toBe("");
    expect(win.router.params).toBeNull();
    expect(win.router.canGoBack).toBe(false);
    expect(win.router.canGoForward).toBe(false);

    mock.fire(EVENT, {
      windowId: "win-ev",
      url: "/page",
      params: { id: 7 },
      canGoBack: true,
      canGoForward: false,
      kind: "push",
    });

    expect(win.router.url).toBe("/page");
    expect(win.router.params).toEqual({ id: 7 });
    expect(win.router.canGoBack).toBe(true);
    expect(win.router.canGoForward).toBe(false);
  });

  test("event for a DIFFERENT windowId does NOT update this handle's state", () => {
    const win = createWindowHandle("win-mine");
    mock.fire(EVENT, {
      windowId: "win-OTHER",
      url: "/other",
      params: null,
      canGoBack: true,
      canGoForward: true,
      kind: "push",
    });
    // State unchanged
    expect(win.router.url).toBe("");
    expect(win.router.canGoBack).toBe(false);
  });

  test("on(handler) is called for THIS windowId and not for other windows", () => {
    const win = createWindowHandle("win-cb");
    const calls: unknown[] = [];
    win.router.on((p) => calls.push(p));

    mock.fire(EVENT, { windowId: "win-cb", url: "/x", params: null, canGoBack: false, canGoForward: false, kind: "push" });
    mock.fire(EVENT, { windowId: "win-OTHER", url: "/y", params: null, canGoBack: false, canGoForward: false, kind: "push" });

    expect(calls.length).toBe(1);
    expect((calls[0] as any).url).toBe("/x");
  });
});

// ── Seed invoke fires on handle construction ───────────────────────────────────

test("createWindowHandle issues __router:state seed invoke (best-effort)", () => {
  mock.invokeResult = undefined; // invoke resolves but we don't need to wait
  createWindowHandle("win-seed");
  // Should have issued one invoke for __router:state
  expect(mock.invokes.some((i) => i.method === "__router:state" && i.args.windowId === "win-seed")).toBe(true);
});

// ── Shared state between repeated handle constructions ────────────────────────

test("second createWindowHandle for same windowId shares cached state", () => {
  const a = createWindowHandle("win-shared");
  const b = createWindowHandle("win-shared");
  const EVENT = eventName(WindowEvent.ROUTE_CHANGED);
  mock.fire(EVENT, { windowId: "win-shared", url: "/new", params: null, canGoBack: false, canGoForward: false, kind: "push" });
  // Both handles see the same state
  expect(a.router.url).toBe("/new");
  expect(b.router.url).toBe("/new");
});

// ── Window.get ────────────────────────────────────────────────────────────────

describe("Window.get", () => {
  test("returns a handle with the given id", () => {
    const h = Window.get("win-9");
    expect(h.id).toBe("win-9");
  });

  test("router.push on Window.get handle targets that window", () => {
    const h = Window.get("win-9");
    h.router.push("/x");
    const msg = JSON.parse(mock.posts[0]);
    expect(msg.a.windowId).toBe("win-9");
    expect(msg.m).toBe("router:push");
  });
});

// ── Window.all ────────────────────────────────────────────────────────────────

describe("Window.all", () => {
  test("maps ids from __zapp:windows-list invoke to WindowHandles", async () => {
    mock.invokeResult = { ids: ["win-1", "win-2"] };
    const handles = await Window.all();
    expect(handles.length).toBe(2);
    expect(handles[0].id).toBe("win-1");
    expect(handles[1].id).toBe("win-2");
  });

  test("returns empty array when ids is empty", async () => {
    mock.invokeResult = { ids: [] };
    const handles = await Window.all();
    expect(handles).toEqual([]);
  });
});

// ── ROUTE_CHANGED wire name ───────────────────────────────────────────────────

test("ROUTE_CHANGED maps to the window:route-changed wire name", () => {
  expect(eventName(WindowEvent.ROUTE_CHANGED)).toBe("window:route-changed");
});
