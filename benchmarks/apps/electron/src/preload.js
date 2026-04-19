const { contextBridge, ipcRenderer } = require('electron');

// Expose a minimal API surface on window.api for the renderer UI.
contextBridge.exposeInMainWorld('api', {
  ping: () => ipcRenderer.invoke('ping'),
});

// Benchmark hooks: bridge-bench.js pasted into devtools calls these.
//
// Worker → native note for Electron:
// Web Workers in an Electron renderer can't call ipcRenderer directly —
// contextBridge only exposes APIs to the main window, not to workers.
// The realistic pattern is: worker posts a request to the renderer,
// renderer forwards via ipcRenderer.invoke to main, response flows back
// the same way. That's 2 renderer↔worker postMessage hops plus one
// ipcRenderer round-trip per logical call. workerBench below measures
// exactly that pattern so the table compares apples-to-apples with
// Zapp's worker → native (direct host call, no IPC hops).
contextBridge.exposeInMainWorld('__bench', {
  ping: () => ipcRenderer.invoke('ping'),

  workerBench: ({ batches, batchSize, warmup }) =>
    new Promise((resolve, reject) => {
      // Inline worker via data URL — keeps this self-contained without
      // touching the forge build (Electron bundles renderer assets via
      // Forge's webpack-free "just serve from src/" model).
      const src = `
        let pending = null;
        self.onmessage = (ev) => {
          if (ev.data && ev.data.__reply) {
            // Reply from renderer's ipcRenderer.invoke proxy
            if (pending) { const r = pending; pending = null; r(); }
            return;
          }
          const { batches, batchSize, warmup } = ev.data;
          const invoke = () => new Promise((r) => {
            pending = r;
            self.postMessage({ __invoke: 'ping' });
          });
          (async () => {
            for (let i = 0; i < warmup; i++) await invoke();
            const perCallUs = new Array(batches);
            for (let b = 0; b < batches; b++) {
              const t0 = performance.now();
              for (let i = 0; i < batchSize; i++) await invoke();
              const t1 = performance.now();
              perCallUs[b] = ((t1 - t0) * 1000) / batchSize;
            }
            self.postMessage({ __result: perCallUs });
          })();
        };
      `;
      const url = URL.createObjectURL(new Blob([src], { type: "text/javascript" }));
      const w = new Worker(url);
      w.onmessage = async (ev) => {
        if (ev.data.__invoke === 'ping') {
          await ipcRenderer.invoke('ping');
          w.postMessage({ __reply: true });
        } else if (ev.data.__result) {
          URL.revokeObjectURL(url);
          w.terminate();
          resolve(ev.data.__result);
        }
      };
      w.onerror = (e) => {
        URL.revokeObjectURL(url);
        w.terminate();
        reject(e);
      };
      w.postMessage({ batches, batchSize, warmup });
    }),
});
