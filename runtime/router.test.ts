/**
 * Tests for the router handle: createWindowHandle(...).router, Window.get,
 * Window.all, and ROUTE_CHANGED event wiring.
 *
 * Uses a mock bridge installed on globalThis[Symbol.for("zapp.bridge")]
 * so tests run without a real native layer (same pattern as worker.test.ts).
 */
import { describe, expect, test, beforeEach, afterEach } from "bun:test";
import {
  createWindow,
  createWindowHandle,
  currentWindow,
  Window,
} from "./window";
import { WindowEvent, eventName } from "./events";
import { PermissionDeniedError } from "./errors";

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

// Listener store shared across per-test mock instances. window.ts wires its
// one-shot global handlers (wireToolbarClicks etc.) on the bridge that is
// current at FIRST registration and never re-wires (module-scope flags), so a
// fresh listeners record per test would strand those handlers on a dead mock.
// Handlers self-filter by windowId; tests use unique ids, so sharing is safe.
const persistentListeners: Record<string, Array<(data: unknown) => void>> = {};

beforeEach(() => {
  mock = {
    posts: [],
    listeners: persistentListeners,
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

  test("push({url, navbar}) forwards navbar to the wire", () => {
    const win = createWindowHandle("win-8");
    win.router.push({ url: "/clean", navbar: { hidden: true } });
    const msg = JSON.parse(mock.posts[0]);
    expect(msg.m).toBe("router:push");
    expect(msg.a.navbar).toEqual({ hidden: true });
  });

  test("push({url, toolbar}) serializes toolbarJson (actions stripped) and forwards title", () => {
    const win = createWindowHandle("win-10");
    win.router.push({
      url: "/detail",
      title: "Detail",
      toolbar: [{ id: "d-share", icon: "sf:square.and.arrow.up", label: "Share", action: () => {} }],
    });
    const msg = JSON.parse(mock.posts[0]);
    expect(msg.m).toBe("router:push");
    expect(msg.a.title).toBe("Detail");
    expect(typeof msg.a.toolbarJson).toBe("string");
    const wire = JSON.parse(msg.a.toolbarJson);
    expect(wire.items.length).toBe(1);
    expect(wire.items[0].id).toBe("d-share");
    expect(wire.items[0].action).toBeUndefined();   // stripped
    expect(wire.style).toBeUndefined();             // push never sends style
  });

  test("push toolbar actions dispatch on window:toolbar-clicked", () => {
    let hits = 0;
    // wireToolbarClicks' handler builds an ActionContext via Window.current(),
    // which resolves the id from globalThis[Symbol.for("zapp.windowId")] — seed
    // it so the handler doesn't bail in the mock env.
    (globalThis as any)[Symbol.for("zapp.windowId")] = "win-11";
    const win = createWindowHandle("win-11");
    win.router.push({
      url: "/detail",
      toolbar: [{ id: "d-share", label: "Share", action: () => { hits++; } }],
    });
    // Fire the click exactly as native emits it (wireToolbarClicks subscribes
    // to eventName(WindowEvent.TOOLBAR_CLICKED) === "window:toolbar-clicked").
    mock.fire("window:toolbar-clicked", { windowId: "win-11", id: "d-share" });
    expect(hits).toBe(1);
    delete (globalThis as any)[Symbol.for("zapp.windowId")];
  });

  // #771 T8 review I2: purgeWindowToolbarActions used to delete every
  // "${windowId}:" key on a window-toolbar setItems/remove call, including
  // route-override actions registered by router.push — killing a displayed
  // route action's callback the moment the app touched its window toolbar.
  // Route-registered keys are now tagged at push time and spared by the purge.
  test("window.toolbar.setItems purge spares a route-registered push action", () => {
    let hits = 0;
    (globalThis as any)[Symbol.for("zapp.windowId")] = "win-12";
    const win = createWindowHandle("win-12");
    win.router.push({
      url: "/detail",
      toolbar: [{ id: "d-share", label: "Share", action: () => { hits++; } }],
    });
    // A window-toolbar setItems call purges the window's OWN registrations —
    // it must not also drop the still-displayed route override's action.
    win.toolbar.setItems([{ id: "settings", label: "Settings", action: () => {} }]);
    mock.fire("window:toolbar-clicked", { windowId: "win-12", id: "d-share" });
    expect(hits).toBe(1);
    delete (globalThis as any)[Symbol.for("zapp.windowId")];
  });

  // #771 T8 round-2 review: plain-button toolbarActions keys are NOT route-
  // scoped ("${windowId}:${id}" is the app-declared id verbatim) — unlike the
  // pull-down menu ids fixed above (I3 round 2 folds `url` into the menu-id
  // base). Two sibling routes reusing the same button id silently share ONE
  // toolbarActions entry (last-push-wins). router.push now tracks each key's
  // registering url as provenance and warns when a DIFFERENT route
  // re-registers an already-tagged key — but the SAME route re-pushing its
  // own id stays silent, and the overwrite behavior itself is unchanged.
  test("router.push warns when a DIFFERENT sibling route reuses a plain button action id (silent on same-route repeat; last-push-wins unchanged)", () => {
    const warnings: string[] = [];
    const origWarn = console.warn;
    console.warn = (msg: string) => { warnings.push(String(msg)); };
    let hitsA = 0;
    let hitsB = 0;
    try {
      (globalThis as any)[Symbol.for("zapp.windowId")] = "win-13";
      const win = createWindowHandle("win-13");

      win.router.push({ url: "/a", toolbar: [{ id: "share", label: "Share", action: () => { hitsA++; } }] });
      expect(warnings.length).toBe(0); // first registration of this key — nothing to compare against

      win.router.push({ url: "/a", toolbar: [{ id: "share", label: "Share", action: () => { hitsA++; } }] });
      expect(warnings.length).toBe(0); // same route re-pushing its own id — no warn

      win.router.push({ url: "/b", toolbar: [{ id: "share", label: "Share", action: () => { hitsB++; } }] });
      expect(warnings.length).toBe(1); // a DIFFERENT route now claims the same key — warn
      expect(warnings[0]).toMatch(/^\[zapp\] toolbar: route action id "share"/);
      expect(warnings[0]).toContain("/a");
      expect(warnings[0]).toContain("/b");
      expect(warnings[0]).toContain("last-push-wins");
      expect(warnings[0]).toContain("distinct ids");

      // No behavior change beyond the warn: the shared key still last-push-wins.
      mock.fire("window:toolbar-clicked", { windowId: "win-13", id: "share" });
      expect(hitsA).toBe(0);
      expect(hitsB).toBe(1);
    } finally {
      console.warn = origWarn;
      delete (globalThis as any)[Symbol.for("zapp.windowId")];
    }
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

describe("WindowHandle.subscribe", () => {
  const EVENT = eventName(WindowEvent.FOCUS);

  test("delivers only this window's events", () => {
    const win = createWindowHandle("win-subscribe");
    const calls: unknown[] = [];
    win.subscribe(WindowEvent.FOCUS, (payload) => calls.push(payload));

    mock.fire(EVENT, { windowId: "win-other" });
    mock.fire(EVENT, { windowId: "win-subscribe" });

    expect(calls).toEqual([{ windowId: "win-subscribe" }]);
  });

  test("unsubscribe is explicit and idempotent", () => {
    const win = createWindowHandle("win-unsubscribe");
    let calls = 0;
    const subscription = win.subscribe(WindowEvent.FOCUS, () => { calls += 1; });

    mock.fire(EVENT, { windowId: "win-unsubscribe" });
    subscription.unsubscribe();
    subscription.unsubscribe();
    mock.fire(EVENT, { windowId: "win-unsubscribe" });

    expect(calls).toBe(1);
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

describe("focused window imports", () => {
  const WID = Symbol.for("zapp.windowId");

  afterEach(() => {
    delete (globalThis as any)[WID];
  });

  test("currentWindow returns the current identity-bearing handle", () => {
    (globalThis as any)[WID] = "win-focused";
    expect(currentWindow().id).toBe("win-focused");
  });

  test("createWindow invokes the narrow framework-owned factory", async () => {
    mock.invokeResult = { windowId: "win-created" };
    const created = await createWindow({
      title: "Diagnostics",
      url: "/diagnostics",
      width: 480,
      height: 320,
    });
    expect(created.id).toBe("win-created");
    expect(mock.invokes.find((invoke) => invoke.method === "__window:create")).toEqual({
      method: "__window:create",
      args: {
        title: "Diagnostics",
        url: "/diagnostics",
        width: 480,
        height: 320,
      },
    });
  });

  test("createWindow fails locally with the public descriptive error class", async () => {
    const key = Symbol.for("zapp.bootstrapConfig");
    const previous = (globalThis as any)[key];
    (globalThis as any)[key] = {
      permissions: { platform: "macos", active: true, allow: [] },
    };
    try {
      await expect(createWindow({ title: "Denied" }))
        .rejects.toBeInstanceOf(PermissionDeniedError);
      expect(mock.invokes.some((invoke) => invoke.method === "__window:create"))
        .toBe(false);
    } finally {
      if (previous === undefined) delete (globalThis as any)[key];
      else (globalThis as any)[key] = previous;
    }
  });
});

// ── ROUTE_CHANGED wire name ───────────────────────────────────────────────────

test("ROUTE_CHANGED maps to the window:route-changed wire name", () => {
  expect(eventName(WindowEvent.ROUTE_CHANGED)).toBe("window:route-changed");
});

// ── M-c: async seed must not clobber a ROUTE_CHANGED that arrived first ────────
describe("router seed vs event race (M-c)", () => {
  const EVENT = eventName(WindowEvent.ROUTE_CHANGED);

  test("a ROUTE_CHANGED before the seed resolves wins over the stale seed", async () => {
    // The seed invoke resolves to a STALE snapshot (root):
    mock.invokeResult = { url: "/", params: null, canGoBack: false, canGoForward: false };
    const win = createWindowHandle("win-mc");
    // A push lands (event) before the async seed promise resolves:
    mock.fire(EVENT, { windowId: "win-mc", url: "/fresh", params: null, canGoBack: true, canGoForward: false });
    // Flush the seed's .then microtask(s):
    await Promise.resolve(); await Promise.resolve();
    expect(win.router.url).toBe("/fresh");        // event value retained
    expect(win.router.canGoBack).toBe(true);      // NOT clobbered back to false
  });
});

// ── M-a: seed invoke fires once per window ────────────────────────────────────
test("__router:state seed invoke fires once per window (M-a)", () => {
  createWindowHandle("win-once");
  createWindowHandle("win-once");
  createWindowHandle("win-once");
  const seeds = mock.invokes.filter((i) => i.method === "__router:state" && i.args.windowId === "win-once");
  expect(seeds.length).toBe(1);
});

// ── router.current(): async authoritative read ────────────────────────────────
test("router.current() resolves the native snapshot and updates the cache", async () => {
  mock.invokeResult = { url: "/deep", params: { a: 1 }, canGoBack: true, canGoForward: false };
  const win = createWindowHandle("win-cur");
  const snap = await win.router.current();
  expect(snap.url).toBe("/deep");
  expect(snap.canGoBack).toBe(true);
  expect(win.router.url).toBe("/deep"); // cache updated too
});

// ── iOS: Window.create non-sheet falls back to router.push ─────────────────────
describe("Window.create iOS single-window fallback", () => {
  const BC = Symbol.for("zapp.bootstrapConfig");
  const WID = Symbol.for("zapp.windowId");
  afterEach(() => {
    delete (globalThis as any)[BC];
    delete (globalThis as any)[WID];
  });

  test("create({url,title}) on iOS posts router:push and returns the current window", async () => {
    // Mirror platform.test.ts's bootstrapConfig shape for os=ios:
    (globalThis as any)[BC] = { permissions: { platform: "ios" } };
    (globalThis as any)[WID] = "win-iose";
    const w = await Window.create({ url: "/detail", title: "Detail" });
    const pushMsg = mock.posts.map((p) => JSON.parse(p)).find((m) => m.m === "router:push");
    expect(pushMsg).toEqual({ t: 4, m: "router:push", a: { windowId: "win-iose", url: "/detail", title: "Detail" } });
    expect(w.id).toBe("win-iose");
    expect(mock.invokes.some((i) => i.method === "__window:create")).toBe(false);
  });

  test("create({title}) with no url on iOS does NOT push", async () => {
    (globalThis as any)[BC] = { permissions: { platform: "ios" } };
    (globalThis as any)[WID] = "win-iose2";
    const before = mock.posts.length;
    await Window.create({ title: "X" });
    const pushed = mock.posts.slice(before).map((p) => JSON.parse(p)).some((m) => m.m === "router:push");
    expect(pushed).toBe(false);
  });
});
