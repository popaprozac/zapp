import { afterEach, expect, test } from "bun:test";
import { createRelatedWindow, RelatedWindowEvent, RelatedWindowInvalidatedError, WindowEvent } from "./window-api";
import { createRelatedWindowBinding } from "./related-window";
import { styleDOM } from "./related-window-dom.test";

const keys = [Symbol.for("zapp.bridge"), Symbol.for("zapp.windowId"), Symbol.for("zapp.bootstrapConfig"), "window"];
const original = keys.map(key => Object.getOwnPropertyDescriptor(globalThis, key));
afterEach(() => keys.forEach((key, i) => {
  if (original[i]) Object.defineProperty(globalThis, key, original[i]!);
  else Reflect.deleteProperty(globalThis, key);
}));

function fixture() {
  const dom = styleDOM();
  const calls: string[] = [], childPosts: any[] = [], disposed: Error[] = [];
  const listeners = new Map<string, (value: any) => void>();
  let created = () => {}, invalidated = (_reason: string) => {};
  let observing = false;
  const prepared = { windowId: "related-2", nativeId: 2, documentToken: "18446744073709551615", address: "zapp://app/.zapp/related.html?creation=18446744073709551615" };
  const childBridge = {
    post(message: string) { childPosts.push(JSON.parse(message)); },
    invoke: async (method: string) => { calls.push(`child:${method}`); return { commandId: "" }; },
    on(name: string, listener: (value: any) => void) { listeners.set(name, listener); return () => listeners.delete(name); },
    _dispose(error: Error) { disposed.push(error); listeners.clear(); },
  };
  const child: any = { closed: false, document: dom.document("zapp://app/.zapp/related.html"),
    [Symbol.for("zapp.bridge")]: childBridge, [Symbol.for("zapp.windowId")]: prepared.windowId };
  const owner: any = {
    invoke: async (method: string) => { calls.push(method); return method === "__window:prepare-related" ? prepared : null; },
    _observeRelatedDocument(id: string, token: string, notify: typeof invalidated, ready: typeof created) {
      expect([id, token]).toEqual([prepared.windowId, prepared.documentToken]);
      calls.push("observe"); observing = true; created = ready; invalidated = notify;
      return () => { calls.push("detach"); observing = false; };
    },
    post() { throw new Error("related controls used owner bridge"); },
  };
  const browser: any = { document: dom.document("zapp://app/index.html"), location: { href: "zapp://app/index.html" }, open(address: string) {
    expect(observing).toBe(true); expect(address).toBe(prepared.address);
    calls.push("open"); queueMicrotask(() => created()); return child;
  } };
  (globalThis as any).window = browser;
  (globalThis as any)[keys[0]!] = owner;
  (globalThis as any)[keys[1]!] = "owner";
  (globalThis as any)[keys[2]!] = { permissions: { platform: "macos", active: false, allow: [] } };
  return { owner, browser, child, childBridge, calls, childPosts, listeners, disposed, prepared, dom,
    ready: () => created(), invalidate: (reason = "Closed") => invalidated(reason), isObserving: () => observing };
}

test("public factory observes before open, publishes after activation, and uses the child's bridge", async () => {
  const f = fixture();
  const child = await createRelatedWindow({ title: "Inspector", width: 400 });
  expect(f.calls).toEqual(["__window:prepare-related", "observe", "open", "__window:publish-related"]);
  expect(child.document).toBe(f.child.document);
  expect(Object.getOwnPropertyDescriptor(child, "document")?.writable).toBe(false);
  child.setTitle("Child"); child.focus();
  expect(f.childPosts.map(value => value.m)).toEqual(["setTitle", "focus"]);
  let focused = 0;
  const subscription = child.subscribe(WindowEvent.FOCUS, () => focused++);
  f.listeners.get("window:focus")?.({ windowId: "owner" });
  f.listeners.get("window:focus")?.({ windowId: child.id });
  expect(focused).toBe(1); subscription.unsubscribe();
  await child.showContextMenu([], { x: 10, y: 10 });
  expect(f.calls.at(-1)).toBe("child:__zapp:menu:popup");
  let retired = 0;
  child.subscribe(RelatedWindowEvent.INVALIDATED, () => retired++);
  f.invalidate(); expect(retired).toBe(0);
  expect(() => child.focus()).toThrow(RelatedWindowInvalidatedError);
  expect(() => child.subscribe(WindowEvent.FOCUS, () => {})).toThrow(RelatedWindowInvalidatedError);
  await expect(child.showContextMenu([], { x: 1, y: 1 })).rejects.toBeInstanceOf(RelatedWindowInvalidatedError);
  await Promise.resolve(); expect(retired).toBe(1);
  child.subscribe(RelatedWindowEvent.INVALIDATED, () => retired++);
  await Promise.resolve(); expect(retired).toBe(2);
  expect(f.disposed).toHaveLength(1);
  expect(f.dom.observers()).toBe(0);
});

test("blocked opening awaits rollback and detaches its observer before rejection", async () => {
  const f = fixture(); f.browser.open = () => null;
  let release!: () => void;
  const invoke = f.owner.invoke;
  f.owner.invoke = async (method: string) => {
    const value = await invoke(method);
    if (method === "__window:abort-related") await new Promise<void>(resolve => release = resolve);
    return value;
  };
  let settled = false;
  const pending = createRelatedWindow().catch(error => { settled = true; return error; });
  for (let i = 0; i < 8; i++) await Promise.resolve();
  expect(f.calls).toContain("__window:abort-related"); expect(settled).toBe(false); expect(f.isObserving()).toBe(false);
  release(); expect((await pending).code).toBe("WINDOW_ERROR");
});

test("retirement before or during publication never exposes a handle", async () => {
  for (const phase of ["open", "publish"] as const) {
    const f = fixture();
    if (phase === "open") f.browser.open = () => { f.invalidate(); f.ready(); return f.child; };
    else {
      const invoke = f.owner.invoke;
      f.owner.invoke = async (method: string) => { const value = await invoke(method); if (method === "__window:publish-related") f.invalidate(); return value; };
    }
    await expect(createRelatedWindow()).rejects.toBeInstanceOf(RelatedWindowInvalidatedError);
    expect(f.calls.at(-1)).toBe("__window:abort-related"); expect(f.isObserving()).toBe(false);
  }
});

test("malformed shell/bridge fails closed and rolls back", async () => {
  for (const failure of ["origin", "path", "bridge", "document"] as const) {
    const f = fixture();
    if (failure === "origin") f.prepared.address = "zapp://other/.zapp/related.html?creation=1";
    if (failure === "path") f.prepared.address = "zapp://app/entry.js";
    if (failure === "bridge") f.child[Symbol.for("zapp.bridge")] = f.owner;
    if (failure === "document") f.child.document.body = null;
    await expect(createRelatedWindow()).rejects.toMatchObject({ code: "WINDOW_ERROR" });
    expect(f.calls.at(-1)).toBe("__window:abort-related");
  }
});

test("unapproved options and invalid dimensions do not allocate native resources", async () => {
  for (const options of [{ url: "/other" }, { inject: ["base"] }, { width: 0 }, { width: 1.5 }, { height: Infinity }, { title: 2 },
    { styles: "inherit" }, { visible: 0 }, { theme: null }, { theme: { attributes: ["onclick"] } },
    { theme: { attributes: ["id"] } }, { theme: { classes: ["two tokens"] } }, { theme: { variables: ["color"] } }]) {
    const f = fixture(); await expect(createRelatedWindow(options as any)).rejects.toBeInstanceOf(TypeError);
    expect(f.calls).toHaveLength(0);
  }
});

test("styles and snapshotted theme precede publication; only native options cross the bridge", async () => {
  const f = fixture();
  const style = f.browser.document.createElement("style"); style.textContent = "main{color:red}";
  f.browser.document.head.append(style);
  f.browser.document.documentElement.setAttribute("data-theme", "dark");
  const theme = { attributes: ["data-theme"] };
  const invoke = f.owner.invoke;
  f.owner.invoke = async (method: string, options: any) => {
    if (method === "__window:prepare-related") {
      expect(options.visible).toBe(false); expect(options.styles).toBeUndefined(); expect(options.theme).toBeUndefined();
      theme.attributes[0] = "data-other";
    }
    if (method === "__window:publish-related") {
      expect(f.child.document.head.querySelectorAll("style")).toHaveLength(1);
      expect(f.child.document.documentElement.getAttribute("data-theme")).toBe("dark");
    }
    return invoke(method);
  };
  const child = await createRelatedWindow({ visible: false, theme });
  child.show(); expect(f.childPosts.at(-1).m).toBe("show");
  f.invalidate(); expect(f.dom.observers()).toBe(0);
  expect(f.child.document.head.children).toHaveLength(0);
});

test("independent styles do not attach an observer or require supported owner CSS", async () => {
  const f = fixture();
  const style = f.browser.document.createElement("style"); style.textContent = 'main{background:image("unsupported")}';
  f.browser.document.head.append(style);
  await createRelatedWindow({ styles: "independent" });
  expect(f.dom.observers()).toBe(0); f.invalidate();
});

test("independent styles can still select a live theme without copying sheets", async () => {
  const f = fixture();
  const style = f.browser.document.createElement("style"); style.textContent = 'main{background:image("unsupported")}';
  f.browser.document.head.append(style);
  f.browser.document.documentElement.setAttribute("data-theme", "dark");
  await createRelatedWindow({ styles: "independent", theme: { attributes: ["data-theme"] } });
  expect(f.child.document.head.querySelectorAll("style")).toHaveLength(0);
  expect(f.child.document.documentElement.getAttribute("data-theme")).toBe("dark");
  expect(f.dom.observers()).toBe(1);
  f.browser.document.documentElement.setAttribute("data-theme", "light"); f.dom.flush();
  expect(f.child.document.documentElement.getAttribute("data-theme")).toBe("light");
  f.invalidate(); expect(f.dom.observers()).toBe(0);
});

test("theme setup failure also releases already-attached shared styles", async () => {
  const f = fixture();
  const style = f.browser.document.createElement("style"); style.textContent = "main{color:red}";
  f.browser.document.head.append(style);
  f.browser.document.documentElement.style.setProperty("--art", 'image("unsupported")');
  await expect(createRelatedWindow({ theme: { variables: ["--art"] } })).rejects.toMatchObject({ code: "WINDOW_ERROR" });
  expect(f.calls).not.toContain("__window:publish-related");
  expect(f.calls.at(-1)).toBe("__window:abort-related");
  expect(f.child.document.head.children).toHaveLength(0); expect(f.dom.observers()).toBe(0);
});

test("styling setup failure rolls back without publication or observer retention", async () => {
  const f = fixture();
  const style = f.browser.document.createElement("style"); style.textContent = 'main{background:image("unsupported")}';
  f.browser.document.head.append(style);
  await expect(createRelatedWindow()).rejects.toMatchObject({ code: "WINDOW_ERROR" });
  expect(f.calls).not.toContain("__window:publish-related");
  expect(f.calls.at(-1)).toBe("__window:abort-related"); expect(f.dom.observers()).toBe(0);
});

test("missing activation is bounded and awaits native rollback", async () => {
  const f = fixture(); f.browser.open = () => f.child;
  await expect(createRelatedWindowBinding({}, 1)).rejects.toMatchObject({ code: "WINDOW_ERROR" });
  expect(f.calls.at(-1)).toBe("__window:abort-related"); expect(f.isObserving()).toBe(false);
});
