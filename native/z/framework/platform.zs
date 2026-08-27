import { PreparedApplication } from "./application-contract.zs";
import { runMacOSApplication } from "./platform/macos.zs";
import { ServiceLifecycleError } from "./service-lifecycle-contract.zs";
import { thread } from "std/thread";
import { TaskScope } from "std/async";

// This is the single target-selection seam. It is intentionally explicit
// until Z's std/target and conditional-module design is implemented.
export async function runApplicationPlatform(
  config: PreparedApplication,
  updates: TaskScope
): i32 throws ServiceLifecycleError on thread.main {
  return try await runMacOSApplication(move config, updates);
}
