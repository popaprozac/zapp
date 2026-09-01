import { sleep } from "std/time";

export struct WorkerModule {
  source: cstring;
}

export enum WorkerLifecycle {
  stopped i32,
  failed i32,
}

export trait WorkerEngine {
  function load(inout this, in module: WorkerModule): i32;
  function hasPendingWork(): boolean;
  function nextWakeMilliseconds(): i64;
  function pump(inout this): i32;
  function result(): i32;
}

export function runWorkerEngine<T: WorkerEngine>(
  inout engine: T,
  in module: WorkerModule
): WorkerLifecycle {
  const loadStatus = engine.load(in module);
  if (loadStatus != 0) return WorkerLifecycle.failed(loadStatus);

  while (engine.hasPendingWork()) {
    const wait = engine.nextWakeMilliseconds();
    if (wait > 0) sleep(u64(wait));

    const pumpStatus = engine.pump();
    if (pumpStatus != 0) return WorkerLifecycle.failed(pumpStatus);
  }

  return WorkerLifecycle.stopped(engine.result());
}
