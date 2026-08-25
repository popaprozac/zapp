import { ApplicationConfig } from "../application-contract.zs";
import {
  ApplicationContext,
  ServiceLifecycleError,
} from "../service-lifecycle-contract.zs";
import { thread } from "std/thread";
import { TaskScope } from "std/async";

struct HeadlessApplicationRuntime {
  exitStatus: i32;
  configuredNameBytes: usize;
}

export async function runApplicationPlatform(
  config: ApplicationConfig,
  updates: TaskScope
): i32 throws ServiceLifecycleError on thread.main {
  const runtime = HeadlessApplicationRuntime({
    exitStatus: 0,
    configuredNameBytes: config.name.byteLength,
  });
  if (runtime.configuredNameBytes == 0) return 64;
  const context = ApplicationContext({ name: copy config.name });
  const started = attempt config.lifecycles.start(in context);
  match (started) {
    success => {}
    failure(startError) => throw startError;
  }
  const status = runtime.exitStatus;
  await updates.close();
  const stopped = attempt config.lifecycles.stop(in context);
  match (stopped) {
    success => {}
    failure(stopError) => throw stopError;
  }
  return status;
}
