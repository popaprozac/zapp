import { ApplicationConfig } from "../framework/application-contract.zs";
import {
  runApplicationPlatform as runHeadlessApplicationPlatform,
} from "../framework/platform/headless.zs";
import { createAsyncServices } from "../framework/async-services.zs";
import { createServiceLifecycles } from "../framework/service-lifecycle.zs";
import { TaskScope } from "std/async";
import { thread } from "std/thread";

async function main(): i32 on thread.main {
  const config = new ApplicationConfig({
    name: "Headless",
    services: createAsyncServices().freeze(),
    lifecycles: createServiceLifecycles().freeze(),
  });
  const updates = new TaskScope();
  const result = attempt await runHeadlessApplicationPlatform(
    config,
    updates
  );
  return match (result) {
    success(status) => status;
    failure(_) => 70;
  };
}
