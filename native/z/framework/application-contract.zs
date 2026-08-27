import { ApplicationMetadata } from "./application-metadata.zs";
import { AsyncServices } from "./async-services.zs";
import { ServiceLifecycles } from "./service-lifecycle.zs";
import { WindowManager } from "./window.zs";
import { thread } from "std/thread";

// Frozen application state prepared exactly once by Application.run(move this).
// This is deliberately not the authored zapp.config.ts contract.
export readonly class PreparedApplication on thread.main {
  readonly metadata: ApplicationMetadata;
  readonly windows: WindowManager;
  readonly services: AsyncServices;
  readonly lifecycles: ServiceLifecycles;
}
