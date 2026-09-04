import { ApplicationMetadata } from "./application-metadata.zs";
import { ApplicationPermissions } from "./application-permissions.zs";
import { ApplicationCapabilities } from "./application-capabilities.zs";
import { ApplicationEvents } from "./application-events.zs";
import { AsyncServices } from "./async-services.zs";
import { ServiceLifecycles } from "./service-lifecycle.zs";
import { WindowManager } from "./window.zs";
import { DialogManager } from "./dialog.zs";
import { ClipboardManager } from "./clipboard.zs";
import { ApplicationMenu } from "./application-menu.zs";
import { WorkerManager } from "./worker/worker-manager.zs";
import { thread } from "std/thread";
import {
  ApplicationContext,
  ApplicationPaths,
} from "../api/zapp/service.zs";

// Frozen application state prepared exactly once by Application.run().
// This is deliberately not the authored zapp.config.ts contract.
export readonly class PreparedApplication on thread.main {
  readonly metadata: ApplicationMetadata;
  readonly context: ApplicationContext;
  readonly permissions: ApplicationPermissions;
  readonly capabilities: ApplicationCapabilities;
  readonly events: ApplicationEvents;
  readonly windows: WindowManager;
  readonly dialogs: DialogManager;
  readonly clipboard: ClipboardManager;
  readonly menu: ApplicationMenu;
  readonly services: AsyncServices;
  readonly lifecycles: ServiceLifecycles;
  readonly workers: WorkerManager;

  internal function contextSnapshot(): ApplicationContext {
    let arguments = Array<String>();
    let argumentIndex: usize = 0;
    while (argumentIndex < this.context.arguments.length) {
      const argumentLength: usize =
        this.context.arguments[argumentIndex].byteLength;
      arguments.push(
        this.context.arguments[argumentIndex].copyBytes(0, argumentLength)
      );
      argumentIndex = argumentIndex + 1;
    }
    return ApplicationContext({
      metadata: ApplicationMetadata({
        name: copy this.context.metadata.name,
        identifier: copy this.context.metadata.identifier,
        version: copy this.context.metadata.version,
      }),
      arguments: arguments.freeze(),
      paths: ApplicationPaths({
        executable: copy this.context.paths.executable,
        resources: copy this.context.paths.resources,
        data: copy this.context.paths.data,
        config: copy this.context.paths.config,
        cache: copy this.context.paths.cache,
      }),
    });
  }
}
