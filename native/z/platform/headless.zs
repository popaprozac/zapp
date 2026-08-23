import { ApplicationConfig } from "../application-contract.zs";
import { thread } from "std/thread";

struct HeadlessApplicationRuntime {
  exitStatus: i32;
  configuredNameBytes: usize;
}

export function runApplicationPlatform(
  config: ApplicationConfig
): i32 on thread.main {
  const runtime = HeadlessApplicationRuntime({
    exitStatus: 0,
    configuredNameBytes: config.name.byteLength,
  });
  if (runtime.configuredNameBytes == 0) return 64;
  return runtime.exitStatus;
}
