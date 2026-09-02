import native from "zapp_worker_zjs.h";
import Foundation from "Foundation/Foundation.h";
import console from "std/console";
import { thread } from "std/thread";
import {
  ApplicationWorkerControl,
  ApplicationWorkerMessageHandler,
  invokeApplicationWorkerService,
} from "../application-workers.zs";
import { WorkerModule } from "../types.zs";
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
  in serviceMethods: readonly Array<String>,
  in workerId: String,
  method: cstring,
  arguments: cstring
): void on thread.any {
  const response = invokeApplicationWorkerService(
    in services,
    in serviceMethods,
    in workerId,
    String.from(method),
    String.from(arguments)
  );
  const ok: i32 = response.ok ? 1 : 0;
  native.zapp_zjs_worker_service_respond(ok, response.payload);
}

export function startZjsApplicationWorker(
  id: String,
  in module: WorkerModule,
  serviceMethods: readonly Array<String>,
  services: Services,
  message: ApplicationWorkerMessageHandler
): ApplicationWorkerControl on thread.main {
  const source = Foundation.NSData.borrow(module.source);
  const serviceWorkerId = copy id;
  const identity = native.zapp_zjs_worker_start(
    source,
    id,
    module.name,
    move (workerId, channel, payload): void => publishZjsWorkerMessage(
      message,
      workerId,
      channel,
      payload
    ),
    move (method, arguments): void => publishZjsWorkerServiceResult(
      in services,
      in serviceMethods,
      in serviceWorkerId,
      method,
      arguments
    )
  );
  if (identity == 0) {
    console.error("application worker could not start");
  }

  return new ApplicationWorkerControl({
    id: move id,
    identity,
  });
}
