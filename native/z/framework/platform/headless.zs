import { PreparedApplication } from "../application-contract.zs";
import { ApplicationError } from "../application-error.zs";
import { ApplicationMetadata } from "../application-metadata.zs";
import {
  ApplicationContext,
} from "../../api/zapp/service.zs";
import { thread } from "std/thread";
import { TaskScope } from "std/async";
import { Once, OnceLifetime } from "std/sync";
import {
  startConfiguredApplicationWorkers,
} from "../configured-application.zs";
import {
  ApplicationWorkerAsyncServiceHandler,
  ApplicationWorkerDispatch,
  ApplicationWorkerMessageHandler,
  ApplicationWorkerServiceCancelHandler,
  completeApplicationWorkerService,
} from "../worker/application-workers.zs";
import { ApplicationWorkerLifecycleHandler } from "../worker/lifecycle.zs";
import { ApplicationWorkerSendOperation } from "../worker/worker-manager.zs";
import {
  deliverApplicationWorkerLifecycle,
  deliverApplicationWorkerMessage,
  installApplicationWorkerManager,
} from "../worker/manager-runtime.zs";
import { bridgeFailure } from "../bridge.zs";

class HeadlessApplicationRuntime {
  readonly updates: TaskScope;
  readonly configuredNameBytes: usize;
  exitStatus: i32 on thread.main;
}

const headlessApplicationRuntime = Once<HeadlessApplicationRuntime>();

function installHeadlessApplicationRuntime(
  runtime: HeadlessApplicationRuntime
): OnceLifetime<HeadlessApplicationRuntime> on thread.main {
  return headlessApplicationRuntime.initialize(move runtime);
}

function publishHeadlessApplicationWorkerMessage(
  workerId: String,
  channel: String,
  payload: String
): void on thread.any {
  const current = headlessApplicationRuntime.get();
  const updates = current.updates;
  const scheduled = updates.schedule(
    thread.main,
    async move (): void => deliverApplicationWorkerMessage(
      move workerId,
      move channel,
      move payload
    )
  );
  if (!scheduled.accepted) return;
}

function rejectHeadlessApplicationWorkerService(
  workerIdentity: usize,
  workerId: String,
  requestId: u64,
  method: String,
  arguments: String
): void on thread.any {
  const unavailable = bridgeFailure(
    0,
    "SERVICE_UNAVAILABLE",
    `headless worker ${workerId} cannot suspend service ${method}`
  );
  completeApplicationWorkerService(
    workerIdentity,
    requestId,
    in unavailable
  );
}

function discardHeadlessApplicationWorkerServiceCancellation(
  requestId: u64
): void on thread.any {}

function publishHeadlessApplicationWorkerLifecycle(
  workerId: String,
  phase: i32,
  incarnation: u64,
  retry: u64,
  maxRetries: u64,
  withinMilliseconds: u64,
  message: String
): void on thread.any {
  const current = headlessApplicationRuntime.get();
  const updates = current.updates;
  const scheduled = updates.schedule(
    thread.main,
    async move (): void => deliverApplicationWorkerLifecycle(
      move workerId,
      phase,
      incarnation,
      retry,
      maxRetries,
      withinMilliseconds,
      move message
    )
  );
  if (!scheduled.accepted) return;
}

export async function runApplicationPlatform(
  config: PreparedApplication,
  updates: TaskScope
): i32 throws ApplicationError on thread.main {
  const runtime = new HeadlessApplicationRuntime({
    updates,
    exitStatus: 0,
    configuredNameBytes: config.metadata.name.byteLength,
  });
  const runtimeLifetime = installHeadlessApplicationRuntime(runtime);
  if (runtime.configuredNameBytes == 0) return 64;
  const context = ApplicationContext({
    metadata: ApplicationMetadata({
      name: copy config.metadata.name,
      identifier: copy config.metadata.identifier,
      version: copy config.metadata.version,
    }),
  });
  const started = attempt config.lifecycles.start(in context);
  match (started) {
    success => {}
    failure(startError) => throw ApplicationError.lifecycle(startError);
  }
  let workerManager = config.workers;
  const workerManagerLifetime = installApplicationWorkerManager(
    workerManager
  );
  const workerMessages: ApplicationWorkerMessageHandler =
    publishHeadlessApplicationWorkerMessage;
  const workerServices: ApplicationWorkerAsyncServiceHandler =
    rejectHeadlessApplicationWorkerService;
  const cancelWorkerService: ApplicationWorkerServiceCancelHandler =
    discardHeadlessApplicationWorkerServiceCancellation;
  const workerLifecycle: ApplicationWorkerLifecycleHandler =
    publishHeadlessApplicationWorkerLifecycle;
  const workers = startConfiguredApplicationWorkers(
    workerManager.catalog,
    config.services.synchronous,
    workerServices,
    cancelWorkerService,
    workerMessages,
    workerLifecycle
  );
  const dispatchWorkers = workers;
  const sendWorker: ApplicationWorkerSendOperation = move (
    in workerId: String,
    in channel: String,
    in payload: String
  ): ApplicationWorkerDispatch => dispatchWorkers.dispatch(
    in workerId,
    in channel,
    in payload
  );
  workerManager.install(sendWorker);
  const status = runtime.exitStatus;
  workers.requestCancellation();
  workers.join();
  workerManager.finish();
  await updates.close();
  const stopped = attempt config.lifecycles.stop(in context);
  match (stopped) {
    success => {}
    failure(stopError) => throw ApplicationError.lifecycle(stopError);
  }
  return status;
}
