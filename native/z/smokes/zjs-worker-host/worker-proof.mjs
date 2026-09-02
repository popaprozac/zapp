const handlers = new Map();

const worker = {
  receive(channel, handler) {
    handlers.set(channel, handler);
  },
  send(channel, payload) {
    __zappWorkerSend(channel, payload);
  },
};

worker.receive("add", (payload) => {
  const request = JSON.parse(payload);
  setTimeout(() => {
    const value = __zappServiceAdd(request.left, request.right);
    worker.send("added", JSON.stringify(value));
  }, 5);
});

export function onMessage(channel, payload) {
  const handler = handlers.get(channel);
  if (!handler) throw new Error(`unhandled worker channel: ${channel}`);
  handler(payload);
}
