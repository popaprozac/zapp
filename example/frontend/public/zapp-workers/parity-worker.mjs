// src/parity-worker.ts
var workerSelf = self;
var zapp = workerSelf.__zapp;
var eventCount = 0;
workerSelf.onmessage = (event) => {
  console.log("parity-worker received message", JSON.stringify(event.data));
  const data = event.data;
  if (data?.type === "echo") {
    workerSelf.postMessage({ type: "echo", payload: data.payload });
    return;
  }
  if (data?.type === "get-event-count") {
    workerSelf.postMessage({ type: "event-count", count: eventCount });
  }
};
workerSelf.receive("suite-ping", (data) => {
  workerSelf.send("suite-pong", { ok: true, payload: data });
});
zapp?.on?.("suite:backend-broadcast", (payload) => {
  eventCount += 1;
  workerSelf.postMessage({ type: "event", count: eventCount, payload });
});
