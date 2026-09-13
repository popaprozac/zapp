import { expect, test } from "bun:test";
import { runInNewContext } from "node:vm";
import { RelatedDocumentLifetime } from "./related-window-lifetime";
import { RelatedWindowInvalidatedError } from "./window-errors";

const identity = { windowId: "win-child", documentToken: "document-1" };
const reason = "The owning document was closed.";
const flush = async () => { await Promise.resolve(); await Promise.resolve(); };

test("related lifetime retires routing synchronously and delivers cleanup later", async () => {
  const order: string[] = [];
  let life: RelatedDocumentLifetime;
  life = new RelatedDocumentLifetime(identity, error => {
    expect(error).toBeInstanceOf(RelatedWindowInvalidatedError);
    expect(() => life.assertActive()).toThrow(error);
    order.push("retire");
  });
  life.subscribe(event => {
    expect(event).toEqual({ windowId: identity.windowId, reason });
    expect(Object.isFrozen(event)).toBe(true);
    order.push("cleanup");
  });
  expect(() => life.assertActive()).not.toThrow();
  expect(life.invalidate(identity, reason)).toBe(true);
  expect(order).toEqual(["retire"]);
  await flush();
  expect(order).toEqual(["retire", "cleanup"]);
});

test("late invalidation subscribers receive one queued notification", async () => {
  const life = new RelatedDocumentLifetime(identity, () => {});
  life.invalidate(identity, reason);
  let calls = 0;
  life.subscribe(() => { calls++; });
  expect(calls).toBe(0);
  expect(life.invalidate(identity, "a duplicate reason")).toBe(false);
  await flush();
  expect(calls).toBe(1);
  await flush();
  expect(calls).toBe(1);
});

test("unsubscribe is independent, idempotent, and suppresses queued delivery", async () => {
  let retired = 0;
  const life = new RelatedDocumentLifetime(identity, () => { retired++; });
  let calls = 0;
  const handler = () => { calls++; };
  const before = life.subscribe(handler);
  life.subscribe(handler);
  before.unsubscribe();
  before.unsubscribe();
  const queued = life.subscribe(handler);
  life.invalidate(identity, reason);
  queued.unsubscribe();
  const late = life.subscribe(handler);
  late.unsubscribe();
  await flush();
  expect(calls).toBe(1);
  expect(retired).toBe(1);
});

test("duplicate callback registrations remain separate subscriptions", async () => {
  const life = new RelatedDocumentLifetime(identity, () => {});
  let calls = 0;
  const handler = () => { calls++; };
  life.subscribe(handler);
  life.subscribe(handler);
  life.invalidate(identity, reason);
  await flush();
  expect(calls).toBe(2);
});

test("stale document and mismatched window notifications do not retire a live document", async () => {
  let retired = 0;
  const life = new RelatedDocumentLifetime(identity, () => { retired++; });
  let calls = 0;
  life.subscribe(() => { calls++; });
  expect(life.invalidate({ ...identity, windowId: "win-owner" }, reason)).toBe(false);
  expect(life.invalidate({ ...identity, documentToken: "document-old" }, reason)).toBe(false);
  expect(() => life.assertActive()).not.toThrow();
  await flush();
  expect(retired).toBe(0);
  expect(calls).toBe(0);
  life.invalidate(identity, reason);
  await flush();
  expect(retired).toBe(1);
  expect(calls).toBe(1);
});

test("identity is snapshotted and old notifications cannot retire a replacement", () => {
  const supplied = { ...identity };
  const life = new RelatedDocumentLifetime(supplied, () => {});
  supplied.documentToken = "mutated-by-caller";
  expect(life.invalidate(identity, reason)).toBe(true);
  const replacementIdentity = { ...identity, documentToken: "document-2" };
  const replacement = new RelatedDocumentLifetime(replacementIdentity, () => {});
  expect(replacement.invalidate(identity, reason)).toBe(false);
  expect(() => replacement.assertActive()).not.toThrow();
});

test("one transport or cleanup failure cannot prevent other cleanup", async () => {
  const errors: unknown[] = [];
  const transportError = new Error("transport cleanup failed");
  const cleanupError = new Error("cleanup failed");
  const life = new RelatedDocumentLifetime(identity, () => { throw transportError; }, error => {
    errors.push(error);
    throw new Error("reporting itself failed");
  });
  let completed = false;
  life.subscribe(() => { throw cleanupError; });
  life.subscribe(() => { completed = true; });
  expect(life.invalidate(identity, reason)).toBe(true);
  await flush();
  expect(completed).toBe(true);
  expect(errors).toEqual([transportError, cleanupError]);
});

test("async cleanup is observed but never awaited", async () => {
  const errors: unknown[] = [];
  const failure = new Error("async cleanup failed");
  let rejectCleanup!: (error: Error) => void;
  const cleanup = new Promise<void>((_, reject) => { rejectCleanup = reject; });
  const life = new RelatedDocumentLifetime(identity, () => {}, error => errors.push(error));
  let completed = false;
  life.subscribe(() => cleanup);
  life.subscribe(() => { completed = true; });
  expect(life.invalidate(identity, reason)).toBe(true);
  await flush();
  expect(completed).toBe(true);
  rejectCleanup(failure);
  await flush();
  expect(errors).toEqual([failure]);
});

test("reentrant retirement latches state and preserves subscriber order", async () => {
  const observed: string[] = [];
  let life: RelatedDocumentLifetime;
  life = new RelatedDocumentLifetime(identity, () => {
    expect(life.invalidate(identity, "reentrant")).toBe(false);
    life.subscribe(() => observed.push("during-retirement"));
  });
  life.subscribe(() => {
    observed.push("first");
    life.subscribe(() => observed.push("during-cleanup"));
  });
  life.subscribe(() => observed.push("second"));
  life.invalidate(identity, reason);
  await flush();
  expect(observed).toEqual(["first", "second", "during-retirement", "during-cleanup"]);
});

test("cleanup may unsubscribe another queued callback without preventing the rest", async () => {
  const life = new RelatedDocumentLifetime(identity, () => {});
  const calls: string[] = [];
  life.subscribe(() => { calls.push("first"); second.unsubscribe(); });
  const second = life.subscribe(() => calls.push("second"));
  life.subscribe(() => calls.push("third"));
  life.invalidate(identity, reason);
  await flush();
  expect(calls).toEqual(["first", "third"]);
});

test("retained cross-realm promises reject without touching sibling work", async () => {
  const child = runInNewContext("Promise.withResolvers()", {}, { timeout: 1000 });
  const observe = runInNewContext("promise => promise.catch(error => error)", {}, { timeout: 1000 });
  const ownerObserved = child.promise.catch((error: unknown) => error);
  const siblingObserved = observe(child.promise);
  const sibling = new RelatedDocumentLifetime(
    { windowId: "win-sibling", documentToken: "sibling-document" }, () => {},
  );
  const life = new RelatedDocumentLifetime(identity, error => child.reject(error));
  life.invalidate(identity, reason);
  const error = await ownerObserved;
  expect(error).toBeInstanceOf(RelatedWindowInvalidatedError);
  expect(await siblingObserved).toBe(error);
  expect(error).toMatchObject({ code: "RELATED_WINDOW_INVALIDATED", windowId: identity.windowId, reason });
  expect(() => sibling.assertActive()).not.toThrow();
  expect(() => life.assertActive()).toThrow(error);
});

test("first terminal reason wins and retired transports are never called again", async () => {
  let calls = 0;
  const life = new RelatedDocumentLifetime(identity, () => { calls++; });
  life.invalidate(identity, reason);
  let delivered: string | undefined;
  life.subscribe(event => { delivered = event.reason; });
  expect(life.invalidate(identity, "later cause")).toBe(false);
  await flush();
  expect(delivered).toBe(reason);
  expect(calls).toBe(1);
});

test("related lifetime requires a nonempty native document identity", () => {
  expect(() => new RelatedDocumentLifetime({ windowId: "", documentToken: "token" }, () => {})).toThrow(TypeError);
  expect(() => new RelatedDocumentLifetime({ windowId: "id", documentToken: "" }, () => {})).toThrow(TypeError);
});
