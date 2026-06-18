// Headless worker for the Workers section. Declared in zapp.config.ts
// (engine "zjs"), it starts at app boot and is addressed as "h-greeter".
//
// Headless JS workers are Zapp's marquee feature: a background thread with
// full host-bridge access — Services.invokeSync calls native at C-call speed
// with no event-loop hop. The SAME source runs on the zc and Nim builds.
//
// Pull in the worker-global TYPE declarations (`receive`/`send`/`__zappBridge`).
// It's a `declare global` + `export {}` module — pure types, so it bundles to a
// no-op; it just makes the ambient worker globals visible to `tsc`.
import "@zappdev/runtime/worker-globals";
import { Events, Services } from "@zappdev/runtime";

console.log("started");

// Point-to-point in: the Workers section sends "ping" via Workers.send.
// Reply by broadcasting "greeter:pong" — the section listens via Events.on.
receive("ping", (data: any) => {
  Events.emit("greeter:pong", { echo: data, at: Date.now() });
});

// Native round-trip from the worker thread: Services.invokeSync calls the host
// `greet` service synchronously, then broadcasts the result back. This is the
// headless-worker differentiator — native access without leaving the thread.
receive("invoke-service", (data: any) => {
  const result = Services.invokeSync("greet", data);
  Events.emit("greeter:service-result", { result });
});

// Async main-thread round-trip: Services.invoke marshals to the main thread so
// the handler receives a real App — enabling window creation and other
// App-touching APIs that are unsafe on the worker thread.
receive("open-window", async (_data: any) => {
  const result = await Services.invoke("openInfoWindow", {});
  Events.emit("greeter:open-window-result", { result });
});
