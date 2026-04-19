// Worker-side bench: measures Services.invokeSync round-trip inside a worker.
// The webview hands us {batches, batchSize, warmup}; we run the batched timing
// and postMessage the results back.
//
// Worker console.log routes to stderr — launch the binary from a Terminal
// (`./release/<app>.app/Contents/MacOS/<exec>`) to see these lines.

import { Services } from "@zappdev/runtime";

console.log("[bench-worker] loaded; waiting for start message");

self.onmessage = (ev: MessageEvent) => {
  const { batches, batchSize, warmup } = ev.data as {
    batches: number;
    batchSize: number;
    warmup: number;
  };
  console.log(
    `[bench-worker] start: batches=${batches} batchSize=${batchSize} warmup=${warmup}`
  );

  // Warmup — let JIT specialize the hot path.
  for (let i = 0; i < warmup; i++) {
    Services.invokeSync("ping");
  }
  console.log("[bench-worker] warmup done");

  const perCallUs = new Array(batches);
  for (let b = 0; b < batches; b++) {
    const t0 = performance.now();
    for (let i = 0; i < batchSize; i++) {
      Services.invokeSync("ping");
    }
    const t1 = performance.now();
    perCallUs[b] = ((t1 - t0) * 1000) / batchSize;
  }
  console.log("[bench-worker] done; posting results");

  (self as any).postMessage({ perCallUs });
};
