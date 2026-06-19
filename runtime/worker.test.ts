import { describe, expect, test, beforeEach } from "bun:test";
import { Workers, type WorkerInfo } from "./worker";

// The runtime reaches native through globalThis[Symbol.for("zapp.bridge")].
// Install a capturing fake so we can assert what Workers.get's handle does.
const BRIDGE_KEY = Symbol.for("zapp.bridge");

interface Captured {
  posts: Array<{ id: string; data: unknown }>;
  terminated: string[];
  listResult: WorkerInfo[];
}

let cap: Captured;

beforeEach(() => {
  cap = { posts: [], terminated: [], listResult: [] };
  (globalThis as any)[BRIDGE_KEY] = {
    _workers: {},
    postToWorker(id: string, data: unknown) { cap.posts.push({ id, data }); },
    terminateWorker(id: string) { cap.terminated.push(id); },
    listWorkers() { return Promise.resolve(cap.listResult); },
  };
});

describe("Workers.get", () => {
  test("returns a handle carrying the id (sync, no round-trip)", () => {
    const h = Workers.get("h-db");
    expect(h.id).toBe("h-db");
  });

  test("postMessage forwards raw to the target id", () => {
    Workers.get("h-db").postMessage({ x: 1 });
    expect(cap.posts).toEqual([{ id: "h-db", data: { x: 1 } }]);
  });

  test("send wraps the channel envelope, same as Workers.send", () => {
    Workers.get("h-db").send("write", { row: 1 });
    expect(cap.posts).toEqual([{ id: "h-db", data: { __zc: "write", d: { row: 1 } } }]);
  });

  test("terminate forwards to the target id", () => {
    Workers.get("h-db").terminate();
    expect(cap.terminated).toEqual(["h-db"]);
  });

  test("info resolves to the matching WorkerInfo snapshot", async () => {
    cap.listResult = [
      { id: "h-db", scriptUrl: "/x", engine: "zjs", shared: false, owners: [] },
      { id: "w-1", scriptUrl: "/y", engine: "zjs", shared: false, owners: [] },
    ];
    const info = await Workers.get("h-db").info();
    expect(info?.id).toBe("h-db");
    expect(info?.engine).toBe("zjs");
  });

  test("info resolves to null for an unknown id", async () => {
    cap.listResult = [{ id: "w-1", scriptUrl: "/y", engine: "zjs", shared: false, owners: [] }];
    expect(await Workers.get("h-missing").info()).toBeNull();
  });
});
