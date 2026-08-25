import { ApplicationConfig } from "./application-contract.zs";
import { AsyncServices } from "./async-services.zs";
import { runApplicationPlatform } from "./platform.zs";
import { ServiceLifecycleError } from "./service-lifecycle-contract.zs";
import {
  ApplicationServicesBuilder,
  createApplicationServices,
} from "./application-services.zs";
import { thread } from "std/thread";
import { TaskScope } from "std/async";

export struct Application on thread.main {
  name: String;
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
): ApplicationConfig on thread.main {
  const { name, services } = move app;
  const { routes, asynchronous, lifecycles } =
    services.freezeConfigured();
  return new ApplicationConfig({
    name: move name,
    services: new AsyncServices({
      synchronous: routes,
      asynchronous,
    }),
    lifecycles,
  });
}
