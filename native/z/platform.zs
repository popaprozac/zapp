import { ApplicationConfig } from "./application-contract.zs";
import { runMacOSApplication } from "./platform/macos.zs";
import { thread } from "std/thread";

// This is the single target-selection seam. It is intentionally explicit
// until Z's std/target and conditional-module design is implemented.
export function runApplicationPlatform(
  config: ApplicationConfig
): i32 on thread.main {
  return runMacOSApplication(move config);
}
