import { PreparedApplication } from "./application-contract.zs";
import { ApplicationError } from "./application-error.zs";
import { ApplicationMetadata } from "./application-metadata.zs";
import { AsyncServices } from "./async-services.zs";
import {
  configuredApplicationMetadata,
} from "./configured-application.zs";
import { runApplicationPlatform } from "./platform.zs";
import {
  ApplicationServicesBuilder,
  createApplicationServices,
} from "./application-services.zs";
import { thread } from "std/thread";
import { TaskScope } from "std/async";
import { WindowManager, createWindowManager } from "./window.zs";

export struct Application on thread.main {
  readonly metadata: ApplicationMetadata = configuredApplicationMetadata();
  readonly windows: WindowManager = createWindowManager();
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
  const { metadata, windows, services } = move app;
  const { routes, asynchronous, lifecycles } =
    services.freezeConfigured();
  return new PreparedApplication({
    metadata: move metadata,
    windows,
    services: new AsyncServices({
      synchronous: routes,
      asynchronous,
    }),
    lifecycles,
  });
}
