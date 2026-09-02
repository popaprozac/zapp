import { Once, OnceLifetime } from "std/sync";
import { thread } from "std/thread";
import { WorkerManager } from "../../worker/worker-manager.zs";

const applicationWorkerManager = Once<WorkerManager>();

internal function installMacOSApplicationWorkerManager(
  manager: WorkerManager
): OnceLifetime<WorkerManager> on thread.main {
  return applicationWorkerManager.initialize(move manager);
}

internal function deliverMacOSApplicationWorkerLifecycle(
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
