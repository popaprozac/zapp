import { PreparedApplication } from "../framework/application-contract.zs";
import { ApplicationMetadata } from "../framework/application-metadata.zs";
import { ApplicationPermissions } from "../framework/application-permissions.zs";
import { Map } from "std/collections";
import { ApplicationCapabilities, CapabilityProfile } from "../framework/application-capabilities.zs";
import {
  runApplicationPlatform as runHeadlessApplicationPlatform,
} from "../framework/platform/headless.zs";
import { createAsyncServices } from "../framework/async-services.zs";
import { createServiceLifecycles } from "../framework/service-lifecycle.zs";
import { createWindowManager } from "../framework/window.zs";
import { emptyApplicationWorkerCatalog } from "../framework/worker/configuration.zs";
import { TaskScope } from "std/async";
import { thread } from "std/thread";

async function main(): i32 on thread.main {
  let profiles = Map<String, CapabilityProfile>();
  const config = new PreparedApplication({
    metadata: ApplicationMetadata({
      name: "Headless",
      identifier: "com.zapp.headless",
      version: "0.1.0",
    }),
    permissions: ApplicationPermissions(),
    capabilities: new ApplicationCapabilities({
      profiles: profiles.freeze(),
    }),
    windows: createWindowManager(),
    services: createAsyncServices().freeze(),
    lifecycles: createServiceLifecycles().freeze(),
    workers: emptyApplicationWorkerCatalog(),
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
