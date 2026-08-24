import { ApplicationConfig } from "./application-contract.zs";
import { runApplicationPlatform } from "./platform.zs";
import { ServiceLifecycleError } from "./service-lifecycle-contract.zs";
import {
  ServiceLifecycleBuilder,
  createServiceLifecycles,
} from "./service-lifecycle.zs";
import { ServicesBuilder, createServices } from "./services.zs";
import { thread } from "std/thread";

export struct Application on thread.main {
  name: String;
  services: ServicesBuilder = createServices();
  lifecycles: ServiceLifecycleBuilder = createServiceLifecycles();

  function run(
    move this
  ): i32 throws ServiceLifecycleError on thread.main {
    const { name, services, lifecycles } = move this;
    const config = ApplicationConfig({
      name: move name,
      services: services.freeze(),
      lifecycles: lifecycles.freeze(),
    });
    return try runApplicationPlatform(move config);
  }
}
