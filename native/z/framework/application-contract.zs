import { ApplicationMetadata } from "./application-metadata.zs";
import { ApplicationPermissions } from "./application-permissions.zs";
import { ApplicationCapabilities } from "./application-capabilities.zs";
import { AsyncServices } from "./async-services.zs";
import { ServiceLifecycles } from "./service-lifecycle.zs";
import { WindowManager } from "./window.zs";
import { WorkerManager } from "./worker/worker-manager.zs";
import { thread } from "std/thread";

// Frozen application state prepared exactly once by Application.run().
// This is deliberately not the authored zapp.config.ts contract.
export readonly class PreparedApplication on thread.main {
  readonly metadata: ApplicationMetadata;
  readonly permissions: ApplicationPermissions;
  readonly capabilities: ApplicationCapabilities;
  readonly windows: WindowManager;
  readonly services: AsyncServices;
  readonly lifecycles: ServiceLifecycles;
  readonly workers: WorkerManager;
}
