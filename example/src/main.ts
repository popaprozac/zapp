import { mount } from 'svelte'
import './app.css'
import AppInstance from './App.svelte'
import { App, Events, Window, Worker, SharedWorker,WindowEvent,Dialog } from '@zapp/runtime'
import { Ping } from "./generated";
import './worker-parity';
import './multiwindow-parity';

setTimeout(async () => {
  const result = await Ping.ping("Hello from frontend");
  console.log("result", result);
}, 1000);

mount(AppInstance, {
  target: document.getElementById('app')!,
});

console.log(App.getConfig())

Events.on("pong", (payload) => {
  console.log("pong", payload);
});

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

Window.current().on(WindowEvent.FOCUS, (payload) => {
  console.log("window focused", payload);
});

Window.current().on(WindowEvent.BLUR, (payload) => {
  console.log("window blurred", payload);
});

Window.current().on(WindowEvent.READY, () => {
  console.log("window ready");
  Window.current().show();
})

Window.current().on(WindowEvent.RESIZE, (payload) => {
  console.log("window resized", payload);
});

Window.current().on(WindowEvent.MOVE, (payload) => {
  console.log("window moved", payload);
});

Window.current().on(WindowEvent.MINIMIZE, (payload) => {
  console.log("window minimized", payload);
});

Window.current().on(WindowEvent.MAXIMIZE, (payload) => {
  console.log("window maximized", payload);
});

const result = await Dialog.message({
  message: "Hello from dialog",
  title: "Dialog Title",
  kind: "info",
  buttons: ["OK", "Cancel"],
});
console.log("dialog result", result.button);