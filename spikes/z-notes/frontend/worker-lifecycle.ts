// @ts-expect-error The monorepo root is not an initialized Zapp application;
// the Zapp Vite plugin resolves this generated public module for the spike.
import { health, NoteState, notes } from "zapp:services";
import { PermissionDeniedError } from "@zappdev/runtime";

declare function __zappWorkerSend(channel: string, payload: string): void;

__zappWorkerSend("ready", JSON.stringify({ worker: "lifecycle" }));

export function onMessage(channel: string, payload: string): void {
  if (channel !== "ping") return;
  const pending = health.status();
  pending.then((status: string) => {
    __zappWorkerSend("service", JSON.stringify({ status }));
    const denied = notes.create({
      title: "worker capability probe",
      state: NoteState.active,
    });
    denied.then(
      () => {
        __zappWorkerSend("denial-missing", "notes.create unexpectedly ran");
        __zappWorkerSend("pong", payload);
      },
      (error: unknown) => {
        const channel = error instanceof PermissionDeniedError
          ? "denied"
          : "denial-wrong-error";
        __zappWorkerSend(channel, JSON.stringify({
          name: error instanceof Error ? error.name : "unknown",
          permission: error instanceof PermissionDeniedError
            ? error.permission
            : "",
        }));
        __zappWorkerSend("pong", payload);
      },
    );
  });
}
