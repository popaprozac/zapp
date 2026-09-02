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

struct HeadlessApplicationRuntime {
  exitStatus: i32;
  configuredNameBytes: usize;
}

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
  const workers = startConfiguredApplicationWorkers(
    config.workers
  );
  const status = runtime.exitStatus;
  workers.requestCancellation();
  workers.join();
  await updates.close();
  const stopped = attempt config.lifecycles.stop(in context);
  match (stopped) {
    success => {}
    failure(stopError) => throw ApplicationError.lifecycle(stopError);
  }
  return status;
}
