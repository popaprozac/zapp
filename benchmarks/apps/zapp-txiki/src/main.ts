import { Services, Window, WindowEvent, Worker } from "@zappdev/runtime";

const win = Window.current();
win.on(WindowEvent.READY, () => win.show());

const button = document.getElementById("ping") as HTMLButtonElement;
const out = document.getElementById("out") as HTMLDivElement;

button.addEventListener("click", async () => {
  const r = (await Services.invoke<{ pong: number }>("ping")) as { pong: number };
  out.textContent = `pong: ${r.pong}`;
});

// Benchmark hooks: bridge-bench.js pasted into devtools calls these.
(globalThis as any).__bench = {
  // Webview → native (IPC path via WKWebView userContentController)
  ping: () => Services.invoke<{ pong: number }>("ping"),

  // Worker → native: spawns a worker that calls Services.invokeSync in a tight
  // batched loop and posts the per-batch µs array back. Returns the raw array
  // so bridge-bench.js can compute the same min/median/mean/max/stdev it does
  // for the webview scenario.
  workerBench: ({ batches, batchSize, warmup }: { batches: number; batchSize: number; warmup: number }) =>
    new Promise<number[]>((resolve, reject) => {
      console.log("[bench] spawning worker");
      const w = new Worker("./bench-worker.ts");
      console.log("[bench] worker created, id =", (w as any).id);
      w.onmessage = (ev) => {
        console.log("[bench] worker onmessage fired");
        const { perCallUs } = (ev as any).data as { perCallUs: number[] };
        w.terminate();
        resolve(perCallUs);
      };
      w.onerror = (e) => {
        console.error("[bench] worker onerror:", e);
        w.terminate();
        reject(e);
      };
      setTimeout(() => {
        console.log("[bench] posting start to worker");
        w.postMessage({ batches, batchSize, warmup });
      }, 100);
    }),
};
