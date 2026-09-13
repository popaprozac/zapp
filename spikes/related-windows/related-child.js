// No UI framework is loaded in this child realm.
const scriptLoadInitMs = performance.now() - window.__scriptStart;
window.addEventListener("load", () => {
  window.opener.__childReady({ scriptLoadInitMs,
    frameworkLoadedHere: false, directOpener: true });
});
