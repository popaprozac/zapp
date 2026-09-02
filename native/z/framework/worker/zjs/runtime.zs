import native from "zapp_worker_zjs.h";
import Foundation from "Foundation/Foundation.h";
import console from "std/console";
import { thread } from "std/thread";
import {
  ApplicationWorkerControl,
  ApplicationWorkerMessageHandler,
} from "../application-workers.zs";
import { WorkerModule } from "../types.zs";

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

export function startZjsApplicationWorker(
  id: String,
  in module: WorkerModule,
  message: ApplicationWorkerMessageHandler
): ApplicationWorkerControl on thread.main {
  const source = Foundation.NSData.borrow(module.source);
  const identity = native.zapp_zjs_worker_start(
    source,
    id,
    module.name,
    move (workerId, channel, payload): void => publishZjsWorkerMessage(
      message,
      workerId,
      channel,
      payload
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
