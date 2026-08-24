import { ApplicationConfig } from "../application-contract.zs";
import {
  ApplicationContext,
  ServiceLifecycleError,
} from "../service-lifecycle-contract.zs";
import { thread } from "std/thread";

struct HeadlessApplicationRuntime {
  exitStatus: i32;
  configuredNameBytes: usize;
}

export function runApplicationPlatform(
  config: ApplicationConfig
): i32 throws ServiceLifecycleError on thread.main {
  const { name, services, lifecycles } = move config;
  const runtime = HeadlessApplicationRuntime({
    exitStatus: 0,
    configuredNameBytes: name.byteLength,
  });
  if (runtime.configuredNameBytes == 0) return 64;
  const context = ApplicationContext({ name: move name });
  try lifecycles.start(in context);
  const status = runtime.exitStatus;
  try lifecycles.stop(in context);
  return status;
}
