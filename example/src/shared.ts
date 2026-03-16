type SharedReply = (channel: string, data: unknown) => void
type SharedGlobal = typeof globalThis & {
  receive: (channel: string, handler: (data: unknown, reply: SharedReply) => void) => void
  onconnect: ((event: { ports: MessagePort[] }) => void) | null
}

const sharedSelf = self as unknown as SharedGlobal

sharedSelf.receive("ping", (data, reply) => {
  console.log("Shared worker received ping", data);
  reply("pong", { hello: "from-shared-worker" });
});

sharedSelf.onconnect = (e) => {
  console.log("Standard onconnect fired", e.ports);
};
