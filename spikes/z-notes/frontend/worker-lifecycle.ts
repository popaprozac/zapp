declare function __zappWorkerSend(channel: string, payload: string): void;

__zappWorkerSend("ready", JSON.stringify({ worker: "lifecycle" }));

export function onMessage(channel: string, payload: string): void {
  if (channel === "ping") {
    __zappWorkerSend("pong", payload);
  }
}
