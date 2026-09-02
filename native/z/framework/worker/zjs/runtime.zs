import native from "zapp_worker_zjs.h";
import Foundation from "Foundation/Foundation.h";
import console from "std/console";
import { thread } from "std/thread";
import {
  ApplicationWorkerAsyncServiceHandler,
  ApplicationWorkerControl,
  ApplicationWorkerMessageHandler,
  ApplicationWorkerServiceCancelHandler,
  allowsApplicationWorkerService,
  invokeApplicationWorkerService,
} from "../application-workers.zs";
import { ApplicationWorkerLifecycleHandler } from "../lifecycle.zs";
import { WorkerModule } from "../types.zs";
import { ApplicationWorkerRestartPolicy } from "../configuration.zs";
import { Services } from "../../services.zs";

function publishZjsWorkerMessage(
  message: ApplicationWorkerMessageHandler,
  workerId: cstring,
  channel: cstring,
  payload: cstring
): void on thread.any {
  message(
    String.from(workerId),
    String.from(channel),
    String.from(payload)
  );
}

function publishZjsWorkerServiceResult(
  in services: Services,
  asyncService: ApplicationWorkerAsyncServiceHandler,
  in serviceMethods: readonly Array<String>,
  in workerId: String,
  workerIdentity: usize,
  requestId: u64,
  method: cstring,
  arguments: cstring
): void on thread.any {
  const ownedMethod = String.from(method);
  const ownedArguments = String.from(arguments);
  if (!allowsApplicationWorkerService(in serviceMethods, in ownedMethod)) {
    const denied = invokeApplicationWorkerService(
      in services,
      in serviceMethods,
      in workerId,
      move ownedMethod,
      move ownedArguments
    );
    native.zapp_zjs_worker_service_respond(
      denied.ok ? 1 : 0,
      denied.payload
    );
    return;
  }
  if (services.hasServiceForMethod(in ownedMethod)) {
    const response = invokeApplicationWorkerService(
      in services,
      in serviceMethods,
      in workerId,
      move ownedMethod,
      move ownedArguments
    );
    native.zapp_zjs_worker_service_respond(
      response.ok ? 1 : 0,
      response.payload
    );
    return;
  }

  native.zapp_zjs_worker_service_defer();
  asyncService(
    workerIdentity,
    copy workerId,
    requestId,
    move ownedMethod,
    move ownedArguments
  );
}

function cancelZjsWorkerService(
  cancelService: ApplicationWorkerServiceCancelHandler,
  requestId: u64
): void on thread.any {
  cancelService(requestId);
}

export function startZjsApplicationWorker(
  id: String,
  in module: WorkerModule,
  serviceMethods: readonly Array<String>,
  restart: ApplicationWorkerRestartPolicy,
  services: Services,
  asyncService: ApplicationWorkerAsyncServiceHandler,
  cancelService: ApplicationWorkerServiceCancelHandler,
  message: ApplicationWorkerMessageHandler,
  lifecycle: ApplicationWorkerLifecycleHandler
): ApplicationWorkerControl on thread.main {
  const source = Foundation.NSData.borrow(module.source);
  const serviceWorkerId = copy id;
  const identity = native.zapp_zjs_worker_start(
    source,
    id,
    module.name,
    restart.enabled ? 1 : 0,
    u64(restart.maxRetries),
    restart.withinMilliseconds,
    move (workerId, channel, payload): void => publishZjsWorkerMessage(
      message,
      workerId,
      channel,
      payload
    ),
    move (workerIdentity, requestId, method, arguments): void => publishZjsWorkerServiceResult(
      in services,
      asyncService,
      in serviceMethods,
      in serviceWorkerId,
      workerIdentity,
      requestId,
      method,
      arguments
    ),
    move (requestId): void => cancelZjsWorkerService(
      cancelService,
      requestId
    ),
    move (
      workerId,
      phase,
      incarnation,
      retry,
      maxRetries,
      withinMilliseconds,
      lifecycleMessage
    ): void => lifecycle(
      String.from(workerId),
      phase,
      incarnation,
      retry,
      maxRetries,
      withinMilliseconds,
      String.from(lifecycleMessage)
    )
  );
  if (identity == 0) {
    console.error("application worker could not start");
    lifecycle(
      copy id,
      3,
      0,
      0,
      u64(restart.maxRetries),
      restart.withinMilliseconds,
      "application worker could not start"
    );
  }

  return new ApplicationWorkerControl({
    id: move id,
    identity,
  });
}
