// Private oracle protocol, not a proposed Zapp JavaScript API.
(() => {
  let binding;
  let sequence = 0;
  let disposed = false;
  let disposal;
  const pending = new Map();
  const listeners = new Set();
  const children = new Map();
  const heldInvalidations = [];
  let holdInvalidations = false;
  let cleanupErrors = 0;
  let suppressPagehide = false;
  const key = value => `${value.windowId}:${value.token}`;
  const invalidated = () => Object.assign(new Error("probe document invalidated"), {
    code: "PROBE_DOCUMENT_INVALIDATED", reason: disposal,
  });
  function forgetFromOwner() {
    try {
      window.opener?.__directBridge?.forgetChild(binding);
    } catch { /* The owner may have navigated or disappeared. */ }
  }
  let activate;
  const ready = new Promise(resolve => { activate = resolve; });
  const bridge = {
    ready,
    get isReady() { return binding !== undefined && !disposed; },
    get identity() { return binding?.windowId; },
    get token() { return binding?.token; },
    get pendingCount() { return pending.size; },
    get disposed() { return disposed; },
    get trackedChildren() { return children.size; },
    get heldInvalidations() { return heldInvalidations.length; },
    get cleanupErrors() { return cleanupErrors; },
    observeForTest(promise) {
      const state = { settled: false, count: 0, error: undefined };
      promise.then(
        () => { state.settled = true; state.count++; },
        error => { state.settled = true; state.count++; state.error = error; },
      );
      return state;
    },
    suppressPagehideForTest(value) { suppressPagehide = value; },
    activate(value) {
      if (disposed) return;
      binding = value;
      try { window.opener?.__directBridge?.trackChild(bridge); } catch {}
      activate();
    },
    // Private family lifecycle bookkeeping. This does not forward request or
    // response data; each child keeps its own transport and pending map.
    trackChild(child) { children.set(key({ windowId: child.identity, token: child.token }), child); },
    forgetChild(value) { if (value) children.delete(key(value)); },
    invalidateChild(event) {
      if (holdInvalidations) { heldInvalidations.push(event); return; }
      const child = children.get(key(event));
      if (!child) return;
      children.delete(key(event)); // Remove first: cleanup can reenter.
      child.dispose(event.reason);
    },
    holdInvalidationsForTest(value) {
      holdInvalidations = value;
      if (!value) for (const event of heldInvalidations.splice(0)) bridge.invalidateChild(event);
    },
    onDispose(callback) {
      if (disposed) { callback(disposal); return () => {}; }
      listeners.add(callback);
      return () => listeners.delete(callback);
    },
    dispose(reason) {
      if (disposed) return;
      disposed = true;
      disposal = reason;
      for (const request of pending.values()) request.reject(invalidated());
      pending.clear();
      const callbacks = [...listeners];
      listeners.clear();
      forgetFromOwner();
      for (const callback of callbacks) {
        try { callback(reason); } catch { cleanupErrors++; }
      }
      for (const child of [...children.values()]) child.dispose("owner-invalidated");
      children.clear();
      heldInvalidations.length = 0;
    },
    invoke(method, args = {}) {
      if (disposed) return Promise.reject(invalidated());
      if (!binding) return Promise.reject(new Error("document not active"));
      const id = ++sequence;
      const promise = new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
      try {
        window.webkit.messageHandlers.directProbe.postMessage({
          id, method, args, token: binding.token,
          // Deliberately forged: native MUST derive identity from message.webView.
          windowId: "forged-owner",
        });
      } catch (error) {
        const request = pending.get(id);
        pending.delete(id);
        request.reject(error);
      }
      return promise;
    },
    accept(reply) {
      if (disposed || !binding || reply.token !== binding.token || reply.windowId !== binding.windowId) return;
      const request = pending.get(reply.id);
      if (!request) return;
      pending.delete(reply.id);
      request.resolve(reply.value);
    },
  };
  globalThis.__directBridge = bridge;
  // This is helpful for document replacement, but native window closure does
  // not guarantee pagehide. The owner's native invalidation notification is
  // the fallback for promises held outside the child document.
  window.addEventListener("pagehide", () => {
    if (!suppressPagehide) bridge.dispose("pagehide");
  }, { once: true });
})();
