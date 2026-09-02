import { expect, test } from "bun:test";
import * as workerAPI from "./application-worker-api";
import {
  ApplicationWorkerError,
  applicationWorkers,
} from "./application-worker-api";

const BRIDGE_KEY = Symbol.for("zapp.bridge");

test("focused worker package exports one manager and its feature error", () => {
  expect(Object.keys(workerAPI).sort()).toEqual([
    "ApplicationWorkerError",
    "applicationWorkers",
  ]);
});

test("application worker send awaits checked native queue acceptance", async () => {
  const invokes: Array<{ method: string; args: unknown }> = [];
  const previous = (globalThis as any)[BRIDGE_KEY];
  (globalThis as any)[BRIDGE_KEY] = {
    on() { return () => {}; },
    invoke(method: string, args: unknown) {
      invokes.push({ method, args });
      const promise = Promise.resolve(null) as Promise<unknown> & { cancel(): void };
      promise.cancel = () => {};
      return promise;
    },
    emit() {},
  };
  try {
    const worker = applicationWorkers.get("indexer");
    await worker.send("search", { query: "z" });
    expect(invokes).toEqual([{
      method: "__zapp:application-worker-send",
      args: {
        workerId: "indexer",
        channel: "search",
        payload: '{"query":"z"}',
      },
    }]);
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previous;
  }
});

test("application worker subscriptions are scoped and explicitly idempotent", () => {
  const listeners: Record<string, Array<(value: unknown) => void>> = {};
  const previous = (globalThis as any)[BRIDGE_KEY];
  (globalThis as any)[BRIDGE_KEY] = {
    on(name: string, handler: (value: unknown) => void) {
      (listeners[name] ??= []).push(handler);
      return () => {
        listeners[name] = (listeners[name] ?? []).filter(
          (candidate) => candidate !== handler,
        );
      };
    },
    invoke() { return Promise.resolve(undefined); },
    emit() {},
  };
  try {
    let observed: unknown;
    const subscription = applicationWorkers.get("indexer").subscribe(
      "results",
      (data) => { observed = data; },
    );
    const name = "__zapp:application-worker:indexer:results";
    for (const handler of listeners[name] ?? []) handler({ count: 2 });
    expect(observed).toEqual({ count: 2 });
    subscription.unsubscribe();
    subscription.unsubscribe();
    expect(listeners[name]).toEqual([]);
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previous;
  }
});

test("application worker handles reject empty names and unsupported JSON", () => {
  expect(() => applicationWorkers.get("  ")).toThrow(ApplicationWorkerError);
  const previous = (globalThis as any)[BRIDGE_KEY];
  (globalThis as any)[BRIDGE_KEY] = {
    on() { return () => {}; },
    invoke() { throw new Error("must not invoke"); },
    emit() {},
  };
  try {
    expect(() => applicationWorkers.get("indexer").send("work", undefined))
      .toThrow(ApplicationWorkerError);
  } finally {
    (globalThis as any)[BRIDGE_KEY] = previous;
  }
});

test("package export resolves the focused worker facade", async () => {
  const manifest = await Bun.file(
    new URL("./package.json", import.meta.url),
  ).json() as { exports: Record<string, string> };
  expect(manifest.exports["./worker"]).toBe("./application-worker-api.ts");
});
