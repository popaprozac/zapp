import { expect, test } from "bun:test";
import { createContext, runInContext } from "node:vm";
import { bundleWebviewBootstrapRaw } from "../bootstrap/codegen";
import { bindRelatedDocumentLifetime } from "./related-window-lifetime";
import { RelatedWindowInvalidatedError } from "./window-errors";

const source = await bundleWebviewBootstrapRaw();
const identity = { windowId: "child", documentToken: "document-1" };

function realm() {
  const posts: any[] = [];
  const timers = new Map<number, () => void>();
  let nextTimer = 0;
  let posting: ((message: any) => void) | undefined;
  const context = createContext({
    console,
    setTimeout(callback: () => void) { const id = ++nextTimer; timers.set(id, callback); return id; },
    clearTimeout(id: number) { timers.delete(id); },
    postNative(source: string) { const message = JSON.parse(source); posts.push(message); posting?.(message); },
  });
  runInContext(`
    globalThis.window = globalThis;
    window.addEventListener = () => {};
    window.webkit = { messageHandlers: { zapp: { postMessage: postNative } } };
    globalThis[Symbol.for('zapp.bootstrapConfig')] = { permissions: { platform: 'ios' } };
  `, context, { timeout: 1000 });
  runInContext(source, context, { timeout: 1000 });
  const bridge = runInContext("globalThis[Symbol.for('zapp.bridge')]", context);
  posts.length = 0;
  return { bridge, posts, timers, onPost(callback: (message: any) => void) { posting = callback; } };
}

test("real child transport rejects retained cross-realm requests and releases resources", async () => {
  const child = realm();
  const sibling = realm();
  const life = bindRelatedDocumentLifetime(identity, child.bridge);
  let added = 0, removed = 0;
  const signal = { aborted: false, addEventListener() { added++; }, removeEventListener() { removed++; } };
  const first = child.bridge.invoke("notes.load", {}, { signal, timeout: 1000 });
  const ownerObserved = first.catch((error: unknown) => error);
  const siblingObserve = runInContext("promise => promise.catch(error => error)", createContext({}), { timeout: 1000 });
  const siblingObserved = siblingObserve(first);
  const noDeadline = child.bridge.invoke("notes.watch", {}, { timeout: 0 }).catch((error: unknown) => error);
  const syncWait = child.bridge.syncWait("legacy-wait", 1000).catch((error: unknown) => error);
  const siblingRequest = sibling.bridge.invoke("notes.load", {}, { timeout: 0 });
  expect(first instanceof Promise).toBe(false);
  expect(child.timers.size).toBe(2);
  expect(added).toBe(1);
  const sent = child.posts.length;
  life.invalidate(identity, "The child document closed.");
  const error = await ownerObserved;
  expect(error).toBeInstanceOf(RelatedWindowInvalidatedError);
  expect(await siblingObserved).toBe(error);
  expect(await noDeadline).toBe(error);
  expect(await syncWait).toBe(error);
  expect(removed).toBe(1);
  expect(child.timers.size).toBe(0);
  expect(child.posts.length).toBe(sent); // Native teardown owns cancellation.
  first.cancel();
  child.bridge._onInvokeResult(1, true, "42");
  expect(child.posts.length).toBe(sent);
  await expect(child.bridge.invoke("notes.load")).rejects.toBe(error);
  await expect(child.bridge.syncWait("late")).rejects.toBe(error);
  sibling.bridge._onInvokeResult(1, true, "42");
  expect(await siblingRequest).toBe(42);
});

test("retired bridges cannot publish, subscribe, create workers, or deliver stale events", async () => {
  const child = realm();
  const life = bindRelatedDocumentLifetime(identity, child.bridge);
  let events = 0;
  const unsubscribe = child.bridge.on("window:focus", () => { events++; });
  const worker = child.bridge.createWorker("worker.js");
  child.bridge._workers[worker].onmessage = () => { events++; };
  child.bridge._onEvent("window:focus", "{}");
  expect(events).toBe(1);
  life.invalidate(identity, "closed");
  const sent = child.posts.length;
  child.bridge.emit("event");
  child.bridge.post("{}");
  child.bridge.postToWorker(worker, 42);
  child.bridge.terminateWorker(worker);
  child.bridge.syncNotify("key");
  child.bridge.on("window:focus", () => { events++; })();
  unsubscribe();
  child.bridge._onEvent("window:focus", "{}");
  child.bridge._onWorkerMessage(worker, "{}");
  expect(() => child.bridge.createWorker("worker.js")).toThrow(RelatedWindowInvalidatedError);
  expect(child.posts.length).toBe(sent);
  expect(Object.keys(child.bridge._workers)).toEqual([]);
  expect(events).toBe(1);
});

test("duplicate invalidation and stale tokens never dispose a fresh transport", async () => {
  const old = realm(), fresh = realm();
  const life = bindRelatedDocumentLifetime(identity, old.bridge);
  const newIdentity = { ...identity, documentToken: "document-2" };
  const replacement = bindRelatedDocumentLifetime(newIdentity, fresh.bridge);
  const pending = old.bridge.invoke("notes.load", {}, { timeout: 0 }).catch((error: unknown) => error);
  life.invalidate(identity, "first cause");
  old.bridge._dispose(new Error("second cause"));
  expect((await pending).reason).toBe("first cause");
  expect(replacement.invalidate(identity, "stale notification")).toBe(false);
  const active = fresh.bridge.invoke("notes.load", {}, { timeout: 0 });
  old.bridge._onInvokeResult(1, true, "99");
  fresh.bridge._onInvokeResult(1, true, "42");
  expect(await active).toBe(42);
});

test("reentrant native completion or disposal does not leave a deadline timer", async () => {
  for (const dispose of [false, true]) {
    const child = realm();
    const life = bindRelatedDocumentLifetime(identity, child.bridge);
    child.onPost(message => {
      if (dispose) life.invalidate(identity, "closed during dispatch");
      else child.bridge._onInvokeResult(message.id, true, "42");
    });
    const result = child.bridge.invoke("notes.load", {}, { timeout: 1000 });
    if (dispose) await expect(result).rejects.toMatchObject({ code: "RELATED_WINDOW_INVALIDATED" });
    else expect(await result).toBe(42);
    expect(child.timers.size).toBe(0);
  }
});

test("a throwing native post or JSON encoding retires the unfinished invoke", async () => {
  const child = realm();
  const failure = new Error("native transport gone");
  child.onPost(() => { throw failure; });
  const failed = child.bridge.invoke("notes.load", {}, { timeout: 1000 });
  await expect(failed).rejects.toBe(failure);
  const beforeCancel = child.posts.length;
  failed.cancel();
  expect(child.posts.length).toBe(beforeCancel);
  const cycle: any = {}; cycle.self = cycle;
  await expect(child.bridge.invoke("notes.load", cycle)).rejects.toBeDefined();
  await expect(child.bridge.syncWait("wait", 1000)).rejects.toBe(failure);
  expect(Object.keys(child.bridge._syncPending)).toEqual([]);
  expect(child.timers.size).toBe(0);
  child.bridge._dispose(new Error("cleanup"));
});

test("retirement inside an event prevents remaining callbacks from using the retired bridge", () => {
  const child = realm();
  let delivered = 0;
  child.bridge.on("event", () => { child.bridge._dispose(new Error("closed")); });
  child.bridge.on("event", () => { delivered++; });
  child.bridge._onEvent("event", "{}");
  expect(delivered).toBe(0);
});
