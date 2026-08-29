const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("zNotes", {
  list: () => ipcRenderer.invoke("notes:list"),
  create: (input) => ipcRenderer.invoke("notes:create", input),
  benchmarkMode: () => ipcRenderer.invoke("benchmark:mode"),
  reportBenchmark: (report) => ipcRenderer.invoke("benchmark:report", report),
});
