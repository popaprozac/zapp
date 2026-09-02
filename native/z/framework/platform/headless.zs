import { PreparedApplication } from "../application-contract.zs";
import { ApplicationError } from "../application-error.zs";
import { ApplicationMetadata } from "../application-metadata.zs";
import {
  ApplicationContext,
} from "../../api/zapp/service.zs";
import { thread } from "std/thread";
import { TaskScope } from "std/async";
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
import { bridgeFailure } from "../bridge.zs";

struct HeadlessApplicationRuntime {
  exitStatus: i32;
  configuredNameBytes: usize;
}

function discardApplicationWorkerMessage(
  workerId: String,
  channel: String,
  payload: String
): void on thread.any {}

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

function discardHeadlessApplicationWorkerLifecycle(
  workerId: String,
  phase: i32,
  incarnation: u64,
  retry: u64,
  maxRetries: u64,
  withinMilliseconds: u64,
  message: String
): void on thread.any {}

export async function runApplicationPlatform(
  config: PreparedApplication,
  updates: TaskScope
): i32 throws ApplicationError on thread.main {
  const runtime = HeadlessApplicationRuntime({
    exitStatus: 0,
    configuredNameBytes: config.metadata.name.byteLength,
  });
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
  const workerMessages: ApplicationWorkerMessageHandler =
    discardApplicationWorkerMessage;
  const workerServices: ApplicationWorkerAsyncServiceHandler =
    rejectHeadlessApplicationWorkerService;
  const cancelWorkerService: ApplicationWorkerServiceCancelHandler =
    discardHeadlessApplicationWorkerServiceCancellation;
  const workerLifecycle: ApplicationWorkerLifecycleHandler =
    discardHeadlessApplicationWorkerLifecycle;
  let workerManager = config.workers;
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
