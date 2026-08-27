import { PreparedApplication } from "./application-contract.zs";
import { ApplicationMetadata } from "./application-metadata.zs";
import { AsyncServices } from "./async-services.zs";
import {
  configuredApplicationMetadata,
} from "./configured-application.zs";
import { runApplicationPlatform } from "./platform.zs";
import { ServiceLifecycleError } from "./service-lifecycle-contract.zs";
import {
  ApplicationServicesBuilder,
  createApplicationServices,
} from "./application-services.zs";
import { thread } from "std/thread";
import { TaskScope } from "std/async";

export struct Application on thread.main {
  readonly metadata: ApplicationMetadata = configuredApplicationMetadata();
  services: ApplicationServicesBuilder = createApplicationServices();

  async function run(
    move this
  ): i32 throws ServiceLifecycleError on thread.main {
    const config = prepareApplication(move this);
    const updates = new TaskScope();
    return try await runApplicationPlatform(config, updates);
  }
}

function prepareApplication(
  app: Application
): PreparedApplication on thread.main {
  const { metadata, services } = move app;
  const { routes, asynchronous, lifecycles } =
    services.freezeConfigured();
  return new PreparedApplication({
    metadata: move metadata,
    services: new AsyncServices({
      synchronous: routes,
      asynchronous,
    }),
    lifecycles,
  });
}
