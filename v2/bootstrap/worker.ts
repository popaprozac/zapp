/**
 * Worker bootstrap — injected into JSC worker contexts after host objects are set up.
 *
 * Host objects already available on __zappBridge:
 *   - invokeService(method, args) → JSValue (sync, direct C call)
 *   - postToWebview(data) → void
 *   - syncWait(key, timeoutMs) → void (fires async, result via dispatchSyncResult)
 *   - syncNotify(key, count) → void
 *
 * This bootstrap adds JS-side convenience APIs:
 *   - self.send(channel, data) / self.receive(channel, handler) — named channels
 *   - Channel routing in _messageHandlers (called by ObjC post_message dispatch)
 *   - self.postMessage wrapper
 */

(function () {
  const bridge = (self as any).__zappBridge;
  if (!bridge) return;

  // Channel handler registry
  const channelHandlers: Record<string, Array<(data: unknown) => void>> = {};

  // self.send — post message on a named channel
  (self as any).send = function (channel: string, data: unknown) {
    (self as any).postMessage({ __zc: channel, d: data });
  };

  // self.receive — listen for messages on a named channel
  (self as any).receive = function (
    channel: string,
    handler: (data: unknown) => void
  ): () => void {
    if (!channelHandlers[channel]) channelHandlers[channel] = [];
    channelHandlers[channel].push(handler);
    return () => {
      channelHandlers[channel] = (channelHandlers[channel] || []).filter(
        (h) => h !== handler
      );
    };
  };

  // Channel routing handler — pushed into _messageHandlers so ObjC dispatch calls it
  const messageHandlers: Array<(event: { data: unknown }) => void> =
    (self as any)._messageHandlers || [];
  (self as any)._messageHandlers = messageHandlers;

  messageHandlers.push(function (ev: { data: unknown }) {
    const msg = ev.data as Record<string, unknown>;
    if (msg && msg.__zc && channelHandlers[msg.__zc as string]) {
      const hs = channelHandlers[msg.__zc as string];
      for (let i = 0; i < hs.length; i++) {
        try {
          hs[i](msg.d);
        } catch (e) {
          console.error(e);
        }
      }
    }
  });

  // dispatchSyncResult — called by native sync.m via jsc_worker_eval_js
  bridge.dispatchSyncResult = function (payloadStr: string) {
    // Sync results for workers are dispatched via eval_js from native.
    // The bridge on the worker side doesn't track pending sync requests
    // (host objects handle the wait/notify directly).
    // This hook exists for future extensions.
  };
})();
