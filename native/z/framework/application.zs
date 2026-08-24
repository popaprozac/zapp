import { ApplicationConfig } from "./application-contract.zs";
import { runApplicationPlatform } from "./platform.zs";
import { ServiceLifecycleError } from "./service-lifecycle-contract.zs";
import {
  ApplicationServicesBuilder,
  createApplicationServices,
} from "./services.zs";
import { thread } from "std/thread";

export struct Application on thread.main {
  name: String;
  services: ApplicationServicesBuilder = createApplicationServices();

  function run(
    move this
  ): i32 throws ServiceLifecycleError on thread.main {
    const { name, services } = move this;
    const { routes, lifecycles } = services.freezeConfigured();
    const config = ApplicationConfig({
      name: move name,
      services: routes,
      lifecycles,
    });
    return try runApplicationPlatform(move config);
  }
}
