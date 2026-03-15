// ../../packages/runtime/sync.ts
var getBridge = () => globalThis[Symbol.for("zapp.bridge")] ?? null;
var Sync = {
  async wait(key, timeoutOrOptions = 3e4) {
    const bridge = getBridge();
    if (!bridge?.syncWait) {
      throw new Error("Sync bridge is unavailable.");
    }
    if (typeof key !== "string" || key.trim().length === 0) {
      throw new Error("Sync key must be a non-empty string.");
    }
    const options = typeof timeoutOrOptions === "number" || timeoutOrOptions == null ? { timeoutMs: timeoutOrOptions } : timeoutOrOptions;
    return await bridge.syncWait({
      key: key.trim(),
      timeoutMs: options.timeoutMs ?? null,
      signal: options.signal
    });
  },
  notify(key, count = 1) {
    const bridge = getBridge();
    if (!bridge?.syncNotify) return false;
    if (typeof key !== "string" || key.trim().length === 0) return false;
    return bridge.syncNotify({ key: key.trim(), count });
  }
};

// src/worker.ts
console.log("Worker is starting up!");
var id = Math.random();
var workerSelf = self;
var zapp = workerSelf.__zapp;
(async () => {
  console.log("[Worker] Starting Sync.wait demo...");
  const controller = new AbortController();
  setTimeout(() => {
    console.log("[Worker] Aborting Sync.wait demo...");
    controller.abort("worker-timeout");
  }, 4e3);
  try {
    const result = await Sync.wait("worker-demo-sync", {
      timeoutMs: null,
      signal: controller.signal
    });
    console.log("[Worker] Sync.wait completed:", result);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("[Worker] Sync.wait failed:", message);
  }
})();
self.onmessage = async (event) => {
  console.log("echoing message", event.data);
  self.postMessage({
    type: "echo",
    payload: event.data
  });
};
workerSelf.receive("ping", (data) => {
  console.log("Worker received ping on channel", data);
  workerSelf.send("pong", { ok: true, orig: data });
});
zapp?.on?.("test", console.log);
try {
  const res = await fetch("https://jsonplaceholder.typicode.com/todos/1");
  const json = await res.json();
  self.postMessage({
    type: "echo_with_fetch",
    payload: "hello",
    fetchResult: json,
    id
  });
} catch (e) {
  console.error("Fetch failed:", e instanceof Error ? e.message : String(e));
}
setInterval(() => {
  console.log("emitting pong");
  zapp?.emit?.("pong", { hello: "from-worker", id });
}, 1e3);
