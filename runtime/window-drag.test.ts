import { expect, test } from "bun:test";
import { createContext, runInContext } from "node:vm";
import { createWindowDragGesture, resolveWindowDrag, windowDragPath } from "../bootstrap/window-drag";
import { bundleWebviewBootstrapRaw } from "../bootstrap/codegen";

function element(tag = "div", attrs: Record<string, string> = {}, css = "", editable = false): Element {
  return {
    nodeType: 1, localName: tag, parentNode: null,
    isContentEditable: editable,
    tabIndex: attrs.tabindex === undefined ? -1 : Number(attrs.tabindex),
    hasAttribute: (key: string) => Object.hasOwn(attrs, key),
    getAttribute: (key: string) => attrs[key] ?? null,
    ownerDocument: { defaultView: { getComputedStyle: () => ({ getPropertyValue: () => css }) } },
  } as unknown as Element;
}

const titlebar = () => element("header", { "data-zapp-titlebar": "" });
const handle = () => element("div", { "data-zapp-drag-region": "" });

test("native queries consume only a fresh, matching trusted down", () => {
  let now = 100;
  const gesture = createWindowDragGesture(() => now);
  const event = (path: Element[], extra: object = {}) => ({ isTrusted: true, button: 0,
    ctrlKey: false, clientX: 20.5, clientY: 30.5, detail: 1, composedPath: () => path, ...extra }) as unknown as MouseEvent;
  expect(gesture.take(20.5, 30.5, 1)).toBe(-1);
  gesture.record(event([handle()], { isTrusted: false }));
  expect(gesture.take(20.5, 30.5, 1)).toBe(-1);
  for (const extra of [{ button: 2 }, { ctrlKey: true }]) {
    gesture.record(event([titlebar()], extra));
    expect(gesture.take(20.5, 30.5, 1)).toBe(-1);
  }
  gesture.record(event([handle()]));
  expect(gesture.take(50, 30.5, 1)).toBe(-1);
  expect(gesture.take(20.5, 30.5, 2)).toBe(-1);
  expect(gesture.take(20.5, 30.5, 1)).toBe(1);
  expect(gesture.take(20.5, 30.5, 1)).toBe(-1);
  gesture.record(event([titlebar()]));
  now += 501;
  expect(gesture.take(20.5, 30.5, 1)).toBe(0);
  gesture.record(event([titlebar()]));
  gesture.clear();
  expect(gesture.take(20.5, 30.5, 1)).toBe(-1);
});

test("release stops dragging but allows a completed titlebar double-click; DOM changes reject", () => {
  const gesture = createWindowDragGesture(() => 100);
  const record = (path: Element[], detail = 1) => gesture.record({ isTrusted: true,
    button: 0, ctrlKey: false, clientX: 0, clientY: 0, detail, composedPath: () => path } as unknown as MouseEvent);
  record([handle()]); gesture.release();
  expect(gesture.take(0, 0, 1)).toBe(0);
  record([handle()], 2); gesture.release();
  expect(gesture.take(0, 0, 2)).toBe(0);
  record([titlebar()], 2); gesture.release();
  expect(gesture.take(0, 0, 2)).toBe(2);
  const node = titlebar(); record([node]);
  (node as any).isConnected = false;
  expect(gesture.take(0, 0, 1)).toBe(0);
  record([element("button"), titlebar()], 2);
  expect(gesture.take(0, 0, 2)).toBe(0);
});

test("titlebar, move-only, inherited CSS, and unmarked content remain distinct", () => {
  expect(resolveWindowDrag([])).toBe("none");
  expect(resolveWindowDrag([element()])).toBe("none");
  expect(resolveWindowDrag([element(), titlebar()])).toBe("titlebar");
  expect(resolveWindowDrag([element(), handle()])).toBe("move");
  expect(resolveWindowDrag([element("span", {}, " drag "), titlebar()])).toBe("titlebar");
  expect(resolveWindowDrag([element("span", {}, "drag"), element("body", {}, "drag")])).toBe("move");
  expect(resolveWindowDrag([handle(), titlebar()])).toBe("move");
  expect(resolveWindowDrag([titlebar(), handle()])).toBe("titlebar");
});

test("a pending gesture cannot follow a reparented or reassigned hit path", () => {
  const gesture = createWindowDragGesture(() => 100);
  const child = element(), header = titlebar();
  const record = () => gesture.record({ isTrusted: true, button: 0, ctrlKey: false,
    clientX: 1, clientY: 2, detail: 1, composedPath: () => [child, header] } as unknown as MouseEvent);
  (child as any).parentNode = header;
  record();
  (child as any).parentNode = element("button");
  expect(gesture.take(1, 2, 1)).toBe(0);
  (child as any).assignedSlot = header;
  record();
  (child as any).assignedSlot = element("slot");
  expect(gesture.take(1, 2, 1)).toBe(0);
});

test("document-bound gestures require activation and retire with their document", async () => {
  const listeners = new Map<string, Array<(event: Event) => void>>();
  const posts: string[] = [];
  const listen = (name: string, fn: (event: Event) => void) => {
    const callbacks = listeners.get(name) ?? []; callbacks.push(fn); listeners.set(name, callbacks);
  };
  const context = createContext({ console, crypto, performance: { now: () => 100 },
    document: { head: {}, body: {}, addEventListener: listen, removeEventListener() {} },
    setTimeout, clearTimeout, postNative: (message: string) => posts.push(message), listen,
  });
  runInContext(`globalThis.window=globalThis;window.addEventListener=listen;
    window.webkit={messageHandlers:{zapp:{postMessage:postNative}}};
    globalThis[Symbol.for('zapp.documentTransport')]=1;`, context);
  runInContext(await bundleWebviewBootstrapRaw(), context, { timeout: 1000 });
  const bridge = runInContext("globalThis[Symbol.for('zapp.bridge')]", context);
  const nonce = posts[0]!.slice("@hello\n".length);
  const down = () => { for (const listener of listeners.get("mousedown") ?? []) listener({
    isTrusted: true, button: 0, ctrlKey: false, clientX: 1, clientY: 2, detail: 1,
    composedPath: () => [titlebar()],
  } as unknown as MouseEvent); };
  down();
  expect(bridge._takeWindowDrag("1", 1, 2, 1)).toBe(0);
  expect(bridge._bindDocument(nonce, "1", true)).toBe(true);
  down();
  expect(bridge._takeWindowDrag("1", 1, 2, 1)).toBe(0);
  expect(bridge._activateDocument(nonce, "1")).toBe(true);
  expect(bridge._takeWindowDrag("1", 1, 2, 1)).toBe(-1); // no pre-activation snapshot
  down();
  expect(bridge._takeWindowDrag("old", 1, 2, 1)).toBe(0);
  expect(bridge._takeWindowDrag("1", 1, 2, 1)).toBe(2);
  expect(bridge._takeWindowDrag("1", 1, 2, 1)).toBe(-1);
  for (const event of ["blur", "pagehide"]) {
    down();
    for (const listener of listeners.get(event) ?? []) listener({} as Event);
    expect(bridge._takeWindowDrag("1", 1, 2, 1)).toBe(-1);
  }
  down();
  expect(bridge._bindDocument(nonce, "2")).toBe(true);
  expect(bridge._takeWindowDrag("1", 1, 2, 1)).toBe(0);
  expect(bridge._takeWindowDrag("2", 1, 2, 1)).toBe(-1);
  down(); bridge._dispose(new Error("closed"));
  expect(bridge._takeWindowDrag("2", 1, 2, 1)).toBe(0);
  down();
  expect(bridge._takeWindowDrag("2", 1, 2, 1)).toBe(0);
  expect(posts.some(message => message.includes('"m":"setDragRegion"'))).toBe(false);
});

test("interactive controls beat both inherited CSS and explicit drag markers", () => {
  const cases: Array<[string, Record<string, string>, boolean?]> = [
    ["button", {}], ["input", {}], ["select", {}], ["textarea", {}],
    ["button", { disabled: "" }], ["label", {}], ["summary", {}],
    ["a", { href: "/notes" }], ["area", { href: "/notes" }],
    ["video", { controls: "" }], ["audio", { controls: "" }],
    ["div", { role: "button" }], ["div", { role: "slider" }],
    ["div", { role: "custom textbox" }], ["div", { tabindex: "0" }],
    ["div", {}, true], ["iframe", {}], ["object", {}], ["embed", {}],
  ];
  for (const [tag, attrs, editable] of cases) {
    const control = element(tag, { ...attrs, "data-zapp-drag-region": "" }, "drag", editable);
    expect(resolveWindowDrag([control, titlebar()])).toBe("none");
    // A marked icon must not escape the interactive ancestor's exclusion.
    expect(resolveWindowDrag([element("svg", { "data-zapp-titlebar": "" }, "drag"), control, handle()])).toBe("none");
  }
  expect(resolveWindowDrag([element("a"), titlebar()])).toBe("titlebar");
  expect(resolveWindowDrag([element("div", { tabindex: "-1" }), titlebar()])).toBe("titlebar");
});

test("no-drag excludes the entire subtree; nested positive markers cannot opt back in", () => {
  expect(resolveWindowDrag([element("span", {}, "no-drag"), titlebar()])).toBe("none");
  expect(resolveWindowDrag([handle(), element("section", {}, "no-drag"), titlebar()])).toBe("none");
  expect(resolveWindowDrag([element("span", {}, "drag"), titlebar(), element("body", {}, "no-drag")])).toBe("none");
});

test("composed paths include SVG, shadow hosts, and body without realm instanceof checks", () => {
  const icon = element("path"), button = element("button"), host = titlebar(), body = element("body");
  const event = { composedPath: () => [icon, button, { nodeType: 11 }, host, body, { nodeType: 9 }, {}] } as unknown as Event;
  expect(windowDragPath(event)).toEqual([icon, button, host, body]);
  expect(resolveWindowDrag(windowDragPath(event))).toBe("none");
  const bodyRegion = element("body", { "data-zapp-titlebar": "" });
  expect(resolveWindowDrag([icon, bodyRegion])).toBe("titlebar");
});

test("fallback paths traverse text nodes and shadow hosts", () => {
  const host = titlebar(), child = element();
  (child as any).parentNode = { nodeType: 11, host };
  const event = { target: { nodeType: 3, parentNode: child }, composedPath: () => [] } as unknown as Event;
  expect(windowDragPath(event)).toEqual([child, host]);
  expect(resolveWindowDrag(windowDragPath(event))).toBe("titlebar");
});

test("detached or retired documents fail closed", () => {
  const node = titlebar();
  (node as any).isConnected = false;
  expect(resolveWindowDrag([node])).toBe("none");
  expect(resolveWindowDrag([titlebar()], () => { throw new Error("retired realm"); })).toBe("none");
});

test("bundled bootstrap refreshes at mouse-down and clears on exit/blur/page retirement", async () => {
  const listeners = new Map<string, Array<(event: Event) => void>>();
  const posts: any[] = [];
  const listen = (name: string, fn: (event: Event) => void) => {
    const callbacks = listeners.get(name) ?? []; callbacks.push(fn); listeners.set(name, callbacks);
  };
  const context = createContext({ console, crypto,
    document: { addEventListener: listen, removeEventListener() {} },
    setTimeout, clearTimeout,
    postNative: (message: string) => posts.push(JSON.parse(message)),
    listen,
  });
  runInContext(`globalThis.window=globalThis;window.addEventListener=listen;
    window.webkit={messageHandlers:{zapp:{postMessage:postNative}}};`, context);
  runInContext(await bundleWebviewBootstrapRaw(), context, { timeout: 1000 });
  const dispatch = (name: string, path: Element[] = []) => {
    const event = { composedPath: () => path } as unknown as Event;
    for (const listener of listeners.get(name) ?? []) listener(event);
  };
  const state = () => posts.filter((entry) => entry.m === "setDragRegion").at(-1)?.a;
  dispatch("mousemove", [element(), titlebar()]);
  expect(state()).toEqual({ drag: true, titlebar: true });
  const count = posts.length;
  dispatch("mousemove", [element(), titlebar()]);
  expect(posts.length).toBe(count); // no chatter for unchanged legacy state
  dispatch("mousedown", [element("svg"), element("button", {}, "drag"), titlebar()]);
  expect(state()).toEqual({ drag: false, titlebar: false });
  for (const reset of ["mouseleave", "blur", "pagehide"]) {
    dispatch("mousemove", [handle()]);
    expect(state()).toEqual({ drag: true, titlebar: false });
    dispatch(reset);
    expect(state()).toEqual({ drag: false, titlebar: false });
  }
});
