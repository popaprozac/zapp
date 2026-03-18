console.log('Worker is starting up!');
let id = Math.random();
type ZappWorkerGlobal = typeof globalThis & {
  receive: (channel: string, handler: (data: unknown) => void) => void
  send: (channel: string, data: unknown) => void
  __zapp?: {
    emit?: (name: string, payload: unknown) => boolean
    on?: (name: string, handler: (payload: unknown) => void) => () => void
  }
}

import { Sync } from '@zapp/runtime'

const workerSelf = self as unknown as ZappWorkerGlobal
const zapp = workerSelf.__zapp

;(async () => {
  console.log('[Worker] Starting Sync.wait demo...');
  const controller = new AbortController();
  
  setTimeout(() => {
    console.log('[Worker] Aborting Sync.wait demo...');
    controller.abort("worker-timeout");
  }, 4000);

  try {
    const result = await Sync.wait("worker-demo-sync", { 
      timeoutMs: null, 
      signal: controller.signal 
    });
    console.log('[Worker] Sync.wait completed:', result);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error('[Worker] Sync.wait failed:', message);
  }
})();

self.onmessage = async (event) => {
  console.log('echoing message', event.data)
  self.postMessage({
    type: 'echo',
    payload: event.data
  });
}

workerSelf.receive("ping", (data) => {
  console.log("Worker received ping on channel", data);
  workerSelf.send("pong", { ok: true, orig: data });
});

zapp?.on?.("test", console.log);

try {
  const res = await fetch("https://jsonplaceholder.typicode.com/todos/1");
  const json = await res.json();
  self.postMessage({
    type: 'echo_with_fetch',
    payload: 'hello',
    fetchResult: json,
    id,
  });
} catch(e) {
  console.error("Fetch failed:", e instanceof Error ? e.message : String(e));
}

setInterval(() => {
  console.log('emitting pong')
  zapp?.emit?.('pong', { hello: 'from-worker', id })
}, 1000);