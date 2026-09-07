import { expect, test } from "bun:test";
import { Application, type ApplicationQuitRequestedEvent } from "./application-api";

const bridgeKey = Symbol.for("zapp.bridge");
const configKey = Symbol.for("zapp.bootstrapConfig");

test("application quit is a permission-checked one-way request with no force flag", () => {
  const previousBridge = (globalThis as any)[bridgeKey];
  const previousConfig = (globalThis as any)[configKey];
  const messages: unknown[] = [];
  const emitted: unknown[] = [];
  const bridge = {
    post: ((message: string) => messages.push(JSON.parse(message))) as
      ((message: string) => void) | undefined,
    emit: (name: string, payload: unknown) => emitted.push({ name, payload }),
  };
  (globalThis as any)[bridgeKey] = bridge;
  (globalThis as any)[configKey] = {
    permissions: { active: true, allow: ["application:quit"] },
  };
  try {
    expect(Application.current()).toBe(Application.current());
    expect(Application.current().quit()).toBeUndefined();
    expect(messages).toEqual([{ t: 4, m: "__zapp:application:quit", a: {} }]);
    bridge.post = undefined;
    Application.current().quit();
    expect(emitted).toEqual([{ name: "__zapp:application:quit", payload: {} }]);
    (globalThis as any)[configKey].permissions.allow = [];
    expect(() => Application.current().quit()).toThrow("application:quit");
    expect(emitted).toHaveLength(1);
    expect(messages).toHaveLength(1);
  } finally {
    (globalThis as any)[bridgeKey] = previousBridge;
    (globalThis as any)[configKey] = previousConfig;
  }
});

test("application events validate immutable decisions and independently unsubscribe", () => {
  const previousBridge = (globalThis as any)[bridgeKey];
  const handlers = new Set<(value: unknown) => void>();
  let cleanups = 0;
  (globalThis as any)[bridgeKey] = {
    on(name: string, handler: (value: unknown) => void) {
      expect(name).toBe("application:quit-requested");
      handlers.add(handler);
      return () => { cleanups++; handlers.delete(handler); };
    },
  };
  try {
    const first: ApplicationQuitRequestedEvent[] = [];
    const second: ApplicationQuitRequestedEvent[] = [];
    const a = Application.current().events.quitRequested.subscribe(e => first.push(e));
    const b = Application.current().events.quitRequested.subscribe(e => second.push(e));
    const deliver = (value: unknown) => { for (const handler of handlers) handler(value); };
    for (const invalid of [null, false, {}, { cancelled: "false" }]) deliver(invalid);
    expect(first).toEqual([]);
    deliver({ cancelled: true, cancel() {}, force: true });
    expect(first).toEqual([{ cancelled: true }]);
    expect(Object.isFrozen(first[0])).toBe(true);
    expect("cancel" in first[0]).toBe(false);
    a.unsubscribe();
    a.unsubscribe();
    deliver({ cancelled: false });
    expect(first).toHaveLength(1);
    expect(second).toEqual([{ cancelled: true }, { cancelled: false }]);
    b.unsubscribe();
    expect(cleanups).toBe(2);
    expect(handlers.size).toBe(0);
  } finally {
    (globalThis as any)[bridgeKey] = previousBridge;
  }
});

test("frontend lifecycle types do not expose cancellation or a shutdown promise", () => {
  const compile = (event: ApplicationQuitRequestedEvent) => {
    // @ts-expect-error Frontend observation cannot veto a native decision.
    event.cancel();
    // @ts-expect-error Native decision snapshots are read-only.
    event.cancelled = true;
    // @ts-expect-error There is no force escape hatch.
    Application.current().quit({ force: true });
    const requested: void = Application.current().quit();
    return requested;
  };
  expect(typeof compile).toBe("function");
});
