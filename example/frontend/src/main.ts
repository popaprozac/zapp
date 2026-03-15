import { mount } from 'svelte'
import './app.css'
import AppInstance from './App.svelte'
import { App, Events, Window, Worker, SharedWorker } from '@zapp/runtime'
import { Ping } from "../generated";

setTimeout(async () => {
  const result = await Ping.ping("Hello from frontend");
  console.log("result", result);
}, 1000);

mount(AppInstance, {
  target: document.getElementById('app')!,
});

console.log(App.getConfig())



// const shared = new SharedWorker(new URL('./shared.ts', import.meta.url));
// shared.onerror = (event) => {
//   console.error('shared error', event)
// }
// shared.receive("pong", (data) => {
//   console.log("Shared received pong", data);
// });
// shared.send("ping", { hello: "from-shared-client" });

const worker = new Worker(new URL('./worker.ts', import.meta.url));
worker.onerror = (event) => {
  console.error('worker error', event)
}
worker.addEventListener("error", console.log);
worker.onmessage = (event) => {
  console.log('onmessage', event)
}
worker.addEventListener('message', (event) => {
  console.log('message event listener', event)
})
worker.onclose = (event) => {
  console.log('onclose', event);
}
worker.addEventListener('close', (event) => {
  console.log('close event listener', event);
})
// worker.receive("pong", (data) => {
//   console.log("receive pong", data);
// });
// Events.on("pong", (data) => {
//   console.log("on pong", data);
// });
// worker.postMessage({ hello: 'from-main' })
// worker.send("ping", { test: 123 });

// console.log('app config', App.getConfig());
// console.log('worker parity suite ready on globalThis.__zappWorkerParity.run()')

// export default app
