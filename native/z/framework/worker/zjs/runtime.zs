import native from "zapp_worker_zjs.h";
import Foundation from "Foundation/Foundation.h";
import console from "std/console";
import { thread } from "std/thread";
import {
  ApplicationWorkerControl,
} from "../application-workers.zs";
import { WorkerModule } from "../types.zs";

export function startZjsApplicationWorker(
  in module: WorkerModule
): ApplicationWorkerControl on thread.main {
  const source = Foundation.NSData.borrow(module.source);
  const identity = native.zapp_zjs_worker_start(
    source,
    module.name
  );
  if (identity == 0) {
    console.error("application worker could not start");
  }

  return new ApplicationWorkerControl({
    identity,
  });
}
