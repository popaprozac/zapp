// Private oracle protocol, not a proposed Zapp JavaScript API.
(() => {
  let binding;
  let sequence = 0;
  const pending = new Map();
  let activate;
  const ready = new Promise(resolve => { activate = resolve; });
  const bridge = {
    ready,
    get isReady() { return binding !== undefined; },
    get identity() { return binding?.windowId; },
    get token() { return binding?.token; },
    get pendingCount() { return pending.size; },
    activate(value) { binding = value; activate(); },
    invoke(method, args = {}) {
      if (!binding) return Promise.reject(new Error("document not active"));
      const id = ++sequence;
      const promise = new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
      window.webkit.messageHandlers.directProbe.postMessage({
        id, method, args, token: binding.token,
        // Deliberately forged: native MUST derive identity from message.webView.
        windowId: "forged-owner",
      });
      return promise;
    },
    accept(reply) {
      if (!binding || reply.token !== binding.token || reply.windowId !== binding.windowId) return;
      const request = pending.get(reply.id);
      if (!request) return;
      pending.delete(reply.id);
      request.resolve(reply.value);
    },
  };
  globalThis.__directBridge = bridge;
})();
