import { expect, test } from "bun:test";
import { createContext, runInContext } from "node:vm";
import { bundleWebviewBootstrapRaw } from "../bootstrap/codegen";

const source = await bundleWebviewBootstrapRaw();
function realm() {
  const posts: string[] = [];
  const timers = new Map<number, () => void>();
  let nextTimer = 0;
  const context = createContext({
    console, crypto,
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
  return { bridge, posts, nonce, timers, context };
}

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
