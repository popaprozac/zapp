import { ApplicationConfig } from "./application-contract.zs";
import { runMacOSApplication } from "./platform/macos.zs";
import { ServiceLifecycleError } from "./service-lifecycle-contract.zs";
import { thread } from "std/thread";

// This is the single target-selection seam. It is intentionally explicit
// until Z's std/target and conditional-module design is implemented.
export function runApplicationPlatform(
  config: ApplicationConfig
): i32 throws ServiceLifecycleError on thread.main {
  return try runMacOSApplication(move config);
}
