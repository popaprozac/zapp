import { PreparedApplication } from "../framework/application-contract.zs";
import {
  ApplicationError as FrameworkApplicationError,
} from "../framework/application-error.zs";
import {
  ApplicationMetadata as FrameworkApplicationMetadata,
} from "../framework/application-metadata.zs";
import { ApplicationPermissions } from "../framework/application-permissions.zs";
import { ApplicationCapabilities } from "../framework/application-capabilities.zs";
import { AsyncServices } from "../framework/async-services.zs";
import {
  configuredApplicationMetadata,
  configuredApplicationPermissions,
  configuredApplicationCapabilities,
  configuredApplicationWorkers,
} from "../framework/configured-application.zs";
import { ApplicationWorkerCatalog } from "../framework/worker/configuration.zs";
import { runApplicationPlatform } from "../framework/platform.zs";
import {
  ApplicationServicesBuilder,
  createApplicationServices,
} from "../framework/application-services.zs";
import { thread } from "std/thread";
import { TaskScope } from "std/async";
import {
  WindowManager,
  createWindowManager,
} from "../framework/window.zs";

export type ApplicationError = FrameworkApplicationError;
export type ApplicationMetadata = FrameworkApplicationMetadata;

// Application is configuration under construction. run() consumes it once,
// while its managers and the prepared runtime retain shared ARC identities.
export struct Application on thread.main {
  readonly metadata: ApplicationMetadata = configuredApplicationMetadata();
  readonly permissions: ApplicationPermissions =
    configuredApplicationPermissions();
  readonly capabilities: ApplicationCapabilities =
    configuredApplicationCapabilities();
  readonly windows: WindowManager = createWindowManager();
  internal readonly configuredWorkers: ApplicationWorkerCatalog =
    configuredApplicationWorkers();
  services: ApplicationServicesBuilder = createApplicationServices();

  async function run(
    move this
  ): i32 throws ApplicationError on thread.main {
    const config = prepareApplication(move this);
    const updates = new TaskScope();
    return try await runApplicationPlatform(config, updates);
  }
}

function prepareApplication(
  app: Application
): PreparedApplication on thread.main {
  const {
    metadata,
    permissions,
    capabilities,
    windows,
    configuredWorkers,
    services,
  } = move app;
  const { routes, asynchronous, lifecycles } =
    services.freezeConfigured();
  return new PreparedApplication({
    metadata: move metadata,
    permissions,
    capabilities,
    windows,
    services: new AsyncServices({
      synchronous: routes,
      asynchronous,
    }),
    lifecycles,
    workers: configuredWorkers,
  });
}
