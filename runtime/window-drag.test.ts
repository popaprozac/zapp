import { expect, test } from "bun:test";
import { createContext, runInContext } from "node:vm";
import { resolveWindowDrag, windowDragPath } from "../bootstrap/window-drag";
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
