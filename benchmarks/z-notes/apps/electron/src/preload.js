const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("zNotes", {
  list: () => ipcRenderer.invoke("notes:list"),
  create: (input) => ipcRenderer.invoke("notes:create", input),
});
