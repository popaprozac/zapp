import { Once, OnceLifetime } from "std/sync";
import { thread } from "std/thread";
import { WorkerManager } from "./worker-manager.zs";

// The application owns one manager identity. Native engine callbacks carry
// only owned values across their foreign threads, then a platform scheduler
// enters main before consulting this executor-bound manager.
const applicationWorkerManager = Once<WorkerManager>();

internal function installApplicationWorkerManager(
  manager: WorkerManager
): OnceLifetime<WorkerManager> on thread.main {
  return applicationWorkerManager.initialize(move manager);
}

internal function deliverApplicationWorkerMessage(
  workerId: String,
  channel: String,
  payload: String
): void on thread.main {
  let workers = applicationWorkerManager.get();
  workers.publishMessage(in workerId, in channel, in payload);
}

internal function deliverApplicationWorkerLifecycle(
  workerId: String,
  phase: i32,
  incarnation: u64,
  retry: u64,
  maxRetries: u64,
  withinMilliseconds: u64,
  message: String
): void on thread.main {
  let workers = applicationWorkerManager.get();
  workers.publishLifecycle(
    in workerId,
    phase,
    incarnation,
    retry,
    maxRetries,
    withinMilliseconds,
    in message
  );
}
