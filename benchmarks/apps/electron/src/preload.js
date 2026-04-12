const { contextBridge, ipcRenderer } = require('electron');

// Expose a minimal API surface on window.api for the renderer UI.
contextBridge.exposeInMainWorld('api', {
  ping: () => ipcRenderer.invoke('ping'),
});

// Benchmark hook: bridge-bench.ts pasted into devtools calls this.
contextBridge.exposeInMainWorld('__bench', {
  ping: () => ipcRenderer.invoke('ping'),
});
