import { PreparedApplication } from "./application-contract.zs";
import { ApplicationError } from "./application-error.zs";
import { runMacOSApplication } from "./platform/macos/application.zs";
import { thread } from "std/thread";
import { TaskScope } from "std/async";

// This is the single target-selection seam. It is intentionally explicit
// until Z's std/target and conditional-module design is implemented.
export async function runApplicationPlatform(
  config: PreparedApplication,
  updates: TaskScope
): i32 throws ApplicationError on thread.main {
  return try await runMacOSApplication(move config, updates);
}
