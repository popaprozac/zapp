import { expect, test } from "bun:test";
import { createContext, runInContext } from "node:vm";
import { bundleWebviewBootstrapRaw } from "../bootstrap/codegen";
import { bindRelatedDocumentLifetime } from "./related-window-lifetime";
import { RelatedWindowInvalidatedError } from "./window-errors";

const source = await bundleWebviewBootstrapRaw();
function realm() {
  const posts: string[] = [];
  const timers = new Map<number, () => void>();
  const domListeners = new Set<() => void>();
  const document = {
    head: null as object | null,
    body: null as object | null,
    addEventListener(name: string, listener: () => void) { if (name === "DOMContentLoaded") domListeners.add(listener); },
    removeEventListener(name: string, listener: () => void) { if (name === "DOMContentLoaded") domListeners.delete(listener); },
  };
  let nextTimer = 0;
  const context = createContext({
    console, crypto, document,
    setTimeout(callback: () => void) { const id = ++nextTimer; timers.set(id, callback); return id; },
    clearTimeout(id: number) { timers.delete(id); },
    postNative(message: string) { posts.push(message); },
  });
  runInContext(`
    globalThis.window = globalThis;
    window.addEventListener = () => {};
    window.webkit = { messageHandlers: { zapp: { postMessage: postNative } } };
    globalThis[Symbol.for('zapp.bootstrapConfig')] = { permissions: { platform: 'ios' } };
    globalThis[Symbol.for('zapp.documentTransport')] = 1;
  `, context, { timeout: 1000 });
  runInContext(source, context, { timeout: 1000 });
  const bridge = runInContext("globalThis[Symbol.for('zapp.bridge')]", context);
  const nonce = posts[0]!.slice("@hello\n".length);
  return { bridge, posts, nonce, timers, context, document, domListeners };
}

test("related document calls wait for DOM presence and native activation", async () => {
  const page = realm();
  const result = page.bridge.invoke("notes.list", {}, { timeout: 0 });
  expect(page.bridge._bindDocument(page.nonce, "7", true)).toBe(true);
  expect(page.posts).toEqual([`@hello\n${page.nonce}`]);
  expect(page.bridge._documentShellReady(page.nonce, "7")).toBe(false);
  expect(page.bridge._activateDocument(page.nonce, "7")).toBe(false);
  page.document.head = {};
  for (const ready of [...page.domListeners]) ready();
  expect(page.posts).toHaveLength(1);
  page.document.body = {};
  for (const ready of [...page.domListeners]) ready();
  expect(page.posts).toEqual([`@hello\n${page.nonce}`, `@ready\n7\n${page.nonce}`]);
  expect(page.domListeners.size).toBe(0);
  expect(page.bridge._documentShellReady(page.nonce, "7")).toBe(true);
  expect(page.bridge._activateDocument("0".repeat(32), "7")).toBe(false);
  expect(page.bridge._activateDocument(page.nonce, "6")).toBe(false);
  expect(page.bridge._onDocumentInvokeResult("7", 1, true, "99")).toBe(false);
  expect(page.bridge._activateDocument(page.nonce, "7")).toBe(true);
  expect(page.posts.at(-1)).toContain('"m":"notes.list"');
  const dispatched = page.posts.length;
  page.bridge._activateDocument(page.nonce, "7");
  expect(page.posts).toHaveLength(dispatched);
  page.bridge._onDocumentInvokeResult("7", 1, true, "42");
  expect(await result).toBe(42);
});

test("retirement before child activation removes readiness listeners and pending work", async () => {
  for (const domReady of [false, true]) {
    const page = realm();
    if (domReady) { page.document.head = {}; page.document.body = {}; }
    const result = page.bridge.invoke("notes.save", {}, { timeout: 1000 }).catch((e: Error) => e);
    page.bridge._bindDocument(page.nonce, "12", true);
    page.bridge._dispose(new Error("owner retired"));
    page.document.head = {}; page.document.body = {};
    for (const ready of [...page.domListeners]) ready();
    expect(page.bridge._activateDocument(page.nonce, "12")).toBe(false);
    expect(page.posts.some(message => message.includes('"m":"notes.save"'))).toBe(false);
    expect(page.domListeners.size).toBe(0);
    expect(page.timers.size).toBe(0);
    expect((await result).message).toBe("owner retired");
  }
});

test("cancelled or timed-out child calls never start when native activation arrives", async () => {
  for (const timedOut of [false, true]) {
    const page = realm();
    page.document.head = {}; page.document.body = {};
    const invocation = page.bridge.invoke("notes.save", {}, { timeout: 1000 });
    const result = invocation.catch((error: Error) => error);
    page.bridge._bindDocument(page.nonce, "13", true);
    if (timedOut) for (const timeout of [...page.timers.values()]) timeout();
    else invocation.cancel();
    expect(page.bridge._bindDocument(page.nonce, "13", false)).toBe(false);
    expect(page.bridge._activateDocument(page.nonce, "13")).toBe(true);
    expect(page.posts.some(message => message.includes('"m":"notes.save"'))).toBe(false);
    // The rejection belongs to the child's realm, not this test's Error class.
    expect((await result).message).toBe(timedOut ? "Timeout" : "Cancelled");
    page.bridge._dispose(new Error("done"));
    expect(page.timers.size).toBe(0);
  }
});

test("document handshake queues startup calls and acknowledges before dispatch", async () => {
  const page = realm();
  const result = page.bridge.invoke("notes.list", {}, { timeout: 0 });
  expect(page.posts).toEqual([`@hello\n${page.nonce}`]);
  expect(page.bridge._bindDocument("0".repeat(32), "7")).toBe(false);
  expect(page.bridge._bindDocument(page.nonce, "0")).toBe(false);
  expect(page.bridge._bindDocument(page.nonce, "7")).toBe(true);
  expect(page.posts[1]).toBe(`@ready\n7\n${page.nonce}`);
  expect(page.posts[2]).toStartWith("@7\n");
  expect(page.posts.at(-1)).toContain('"m":"notes.list"');
  expect(page.bridge._onDocumentInvokeResult("6", 1, true, "99")).toBe(false);
  expect(page.bridge._onDocumentInvokeResult("7", 1, true, "42")).toBe(true);
  expect(await result).toBe(42);
});

test("a queued reply cannot resolve a replacement realm's reused request id", async () => {
  const old = realm(), fresh = realm();
  old.bridge._bindDocument(old.nonce, "10");
  fresh.bridge._bindDocument(fresh.nonce, "11");
  const previous = old.bridge.invoke("notes.list", {}, { timeout: 0 }).catch((e: Error) => e);
  const result = fresh.bridge.invoke("notes.list", {}, { timeout: 0 });
  expect(fresh.bridge._bindDocument(old.nonce, "10")).toBe(false);
  const delivered = runInContext(`globalThis[Symbol.for('zapp.bridge')]._onDocumentInvokeResult('10',1,true,'99')`, fresh.context);
  expect(delivered).toBe(false);
  expect(fresh.bridge._onDocumentInvokeResult("11", 1, true, "42")).toBe(true);
  expect(await result).toBe(42);
  old.bridge._dispose(new Error("retired"));
  expect((await previous).message).toBe("retired");
});

test("cancellation and disposal before binding never dispatch the queued invoke", async () => {
  for (const dispose of [false, true]) {
    const page = realm();
    const invocation = page.bridge.invoke("notes.save", {}, { timeout: 1000 });
    const result = invocation.catch((e: Error) => e);
    if (dispose) page.bridge._dispose(new Error("closed"));
    else invocation.cancel();
    expect(page.bridge._bindDocument(page.nonce, "8")).toBe(!dispose);
    expect(page.posts.some(message => message.includes('"m":"notes.save"'))).toBe(false);
    expect(page.timers.size).toBe(0);
    expect(await result).toBeDefined();
  }
});

test("a restored realm cannot accept older token bindings or replies", async () => {
  const page = realm();
  page.bridge._bindDocument(page.nonce, "9");
  const previous = page.bridge.invoke("notes.list", {}, { timeout: 0 }).catch((e: Error) => e);
  expect(page.bridge._bindDocument(page.nonce, "10")).toBe(true);
  expect((await previous).message).toContain("replaced");
  expect(page.bridge._bindDocument(page.nonce, "9")).toBe(false);
  expect(page.bridge._onDocumentInvokeResult("9", 1, true, "99")).toBe(false);
  page.bridge._dispose(new Error("done"));
});

test("document-bound retirement rejects child work before queued and late owner listeners", async () => {
  const owner = realm(), child = realm();
  owner.bridge._bindDocument(owner.nonce, "21");
  child.bridge._bindDocument(child.nonce, "22");
  const identity = { windowId: "related-2", documentToken: "22" };
  const life = bindRelatedDocumentLifetime(identity, child.bridge);
  let notices = 0;
  const stop = owner.bridge._observeRelatedDocument(identity.windowId, identity.documentToken, (reason: string) => {
    notices++;
    life.invalidate(identity, reason);
  });
  const held = child.bridge.invoke("notes.watch", {}, { timeout: 1000 }).catch((error: Error) => error);
  const ownWork = owner.bridge.invoke("notes.list", {}, { timeout: 0 });
  let early = 0, late = 0, suppressed = 0;
  life.subscribe(() => { early++; expect(() => life.assertActive()).toThrow(RelatedWindowInvalidatedError); });
  const cancelled = life.subscribe(() => { suppressed++; });
  expect(owner.bridge._onRelatedDocumentInvalidated("old-owner", identity.windowId, "22", "wrong owner")).toBe(false);
  expect(owner.bridge._onRelatedDocumentInvalidated("21", identity.windowId, "20", "old child")).toBe(false);
  expect(owner.bridge._onRelatedDocumentInvalidated("21", identity.windowId, "22", "closed")).toBe(true);
  expect(early).toBe(0);
  cancelled.unsubscribe();
  life.subscribe(() => { late++; }); // Terminal before the consumer continuation attaches.
  expect(late).toBe(0);
  expect(owner.bridge._onRelatedDocumentInvalidated("21", identity.windowId, "22", "duplicate")).toBe(false);
  const error = await held;
  expect(error).toBeInstanceOf(RelatedWindowInvalidatedError);
  expect(error).toMatchObject({ windowId: "related-2", reason: "closed" });
  expect([notices, early, late, suppressed]).toEqual([1, 1, 1, 0]);
  expect(child.timers.size).toBe(0);
  owner.bridge._onDocumentInvokeResult("21", 1, true, "42");
  expect(await ownWork).toBe(42);
  stop(); stop();
});

test("replacement tokens and realms isolate unsolicited related retirement", () => {
  const old = realm(), fresh = realm();
  old.bridge._bindDocument(old.nonce, "30");
  fresh.bridge._bindDocument(fresh.nonce, "40");
  let previous = 0, current = 0;
  old.bridge._observeRelatedDocument("related-2", "31", () => { previous++; });
  fresh.bridge._observeRelatedDocument("related-2", "41", () => { current++; });
  expect(fresh.bridge._onRelatedDocumentInvalidated("30", "related-2", "31", "queued old event")).toBe(false);
  expect(fresh.bridge._onRelatedDocumentInvalidated("40", "related-2", "31", "reused id")).toBe(false);
  expect(old.bridge._onRelatedDocumentInvalidated("30", "related-2", "31", "closed")).toBe(true);
  expect([previous, current]).toEqual([1, 0]);
  expect(fresh.bridge._onRelatedDocumentInvalidated("40", "related-2", "41", "closed")).toBe(true);
  expect(current).toBe(1);
});

test("owner rebind and disposal retire observers without allowing reentrant enrollment", () => {
  for (const rebind of [false, true]) {
    const page = realm();
    page.bridge._bindDocument(page.nonce, "50");
    const reasons: string[] = [];
    page.bridge._observeRelatedDocument("related-2", "51", (reason: string) => {
      reasons.push(reason);
      expect(() => page.bridge._observeRelatedDocument("other", "52", () => {})).toThrow();
    });
    if (rebind) page.bridge._bindDocument(page.nonce, "60");
    else page.bridge._dispose(new Error("gone"));
    expect(reasons).toHaveLength(1);
    expect(reasons[0]).toContain(rebind ? "replaced" : "retired");
    expect(page.bridge._onRelatedDocumentInvalidated("50", "related-2", "51", "late")).toBe(false);
  }
});

test("abandoned creation observation is removable without posting native messages", () => {
  const page = realm();
  expect(() => page.bridge._observeRelatedDocument("related-2", "1", () => {})).toThrow();
  page.bridge._bindDocument(page.nonce, "70");
  const posted = page.posts.length;
  for (const token of ["", "0", "NaN", 71]) {
    expect(() => page.bridge._observeRelatedDocument("related-2", token, () => {})).toThrow();
  }
  const notify = () => { throw new Error("detached observer ran"); };
  const stop = page.bridge._observeRelatedDocument("related-2", "71", notify);
  expect(() => page.bridge._observeRelatedDocument("related-2", "71", notify)).toThrow();
  stop(); stop();
  expect(page.bridge._onRelatedDocumentInvalidated("70", "related-2", "71", "closed")).toBe(false);
  expect(page.posts.length).toBe(posted);
});

test("observer and reporter failures cannot strand sibling retirement", () => {
  const page = realm();
  // Do not mutate the host console shared by the ordinary VM test setup.
  runInContext("console = { error() { throw new Error('reporter failed'); } }", page.context);
  page.bridge._bindDocument(page.nonce, "80");
  let retired = 0;
  page.bridge._observeRelatedDocument("first", "81", () => { throw new Error("observer failed"); });
  page.bridge._observeRelatedDocument("second", "82", () => { retired++; });
  expect(() => page.bridge._dispose(new Error("owner closed"))).not.toThrow();
  expect(retired).toBe(1);
  expect(page.bridge._onRelatedDocumentInvalidated("80", "second", "82", "late")).toBe(false);
});
