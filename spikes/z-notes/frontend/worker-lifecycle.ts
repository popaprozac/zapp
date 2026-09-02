// @ts-expect-error The monorepo root is not an initialized Zapp application;
// the Zapp Vite plugin resolves this generated public module for the spike.
import { health, NoteState, notes } from "zapp:services";
import { PermissionDeniedError } from "@zappdev/runtime";

declare function __zappWorkerSend(channel: string, payload: string): void;

interface WorkerBenchmarkConfig {
  directIterations: number;
  publicIterations: number;
  samples: number;
}

function nowMilliseconds(): number {
  const performance = (globalThis as any).performance;
  return performance && typeof performance.now === "function"
    ? performance.now()
    : Date.now();
}

function directNanosecondsPerCall(iterations: number): number {
  const invoke = (globalThis as any).__zappWorkerInvokeService as (
    method: string,
    input?: unknown,
  ) => unknown;
  if (typeof invoke !== "function") {
    throw new Error("the direct Z worker service host is unavailable");
  }
  for (let index = 0; index < 200; index += 1) {
    if (invoke("health.status") !== "ready") {
      throw new Error("the direct Z worker service returned an invalid value");
    }
  }
  const started = nowMilliseconds();
  for (let index = 0; index < iterations; index += 1) {
    if (invoke("health.status") !== "ready") {
      throw new Error("the direct Z worker service returned an invalid value");
    }
  }
  return Math.round(
    ((nowMilliseconds() - started) * 1_000_000) / iterations,
  );
}

function measurePublicService(
  iterations: number,
  complete: (nanosecondsPerCall: number) => void,
): void {
  let index = 0;
  const started = nowMilliseconds();
  function advance(): void {
    if (index == iterations) {
      complete(Math.round(
        ((nowMilliseconds() - started) * 1_000_000) / iterations,
      ));
      return;
    }
    health.status().then(
      (status: string) => {
        if (status !== "ready") {
          throw new Error("the generated worker service returned an invalid value");
        }
        index += 1;
        advance();
      },
      (error: unknown) => {
        __zappWorkerSend("benchmark-error", String(error));
      },
    );
  }
  advance();
}

function runWorkerBenchmark(config: WorkerBenchmarkConfig): void {
  let sample = 0;
  function advanceSample(): void {
    if (sample == config.samples) {
      __zappWorkerSend("benchmark-complete", "ok");
      return;
    }
    const direct = directNanosecondsPerCall(config.directIterations);
    measurePublicService(config.publicIterations, (publicApi) => {
      __zappWorkerSend(
        `benchmark-sample-${sample}-direct-${direct}-public-${publicApi}`,
        "ok",
      );
      sample += 1;
      advanceSample();
    });
  }

  // Prime Promise creation, generated decoding, and the engine microtask queue
  // separately from the reported samples.
  measurePublicService(200, advanceSample);
}

__zappWorkerSend("ready", JSON.stringify({ worker: "lifecycle" }));

function verifyDeniedService(payload: string): void {
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
}

export function onMessage(channel: string, payload: string): void {
  if (channel === "benchmark") {
    runWorkerBenchmark(JSON.parse(payload) as WorkerBenchmarkConfig);
    return;
  }
  if (channel !== "ping") return;
  const pending = health.status();
  pending.then((status: string) => {
    __zappWorkerSend("service", JSON.stringify({ status }));
    const suspended = notes.isEmpty();
    suspended.then((empty: boolean) => {
      __zappWorkerSend("async-service", JSON.stringify({ empty }));
      const cancelled = notes.isEmpty();
      cancelled.then(
        () => {
          __zappWorkerSend(
            "async-cancellation-missing",
            "cancelled notes.isEmpty unexpectedly completed",
          );
          verifyDeniedService(payload);
        },
        (error: unknown) => {
          const cancelledChannel = error instanceof Error
            && error.name === "AbortError"
            ? "async-cancelled"
            : "async-cancellation-wrong-error";
          __zappWorkerSend(cancelledChannel, JSON.stringify({
            name: error instanceof Error ? error.name : "unknown",
          }));
          verifyDeniedService(payload);
        },
      );
      cancelled.cancel();
    });
  });
}
