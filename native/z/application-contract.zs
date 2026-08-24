import { Services } from "./services.zs";
import { ServiceLifecycles } from "./service-lifecycle.zs";

export struct ApplicationConfig {
  name: String;
  services: Services;
  lifecycles: ServiceLifecycles;
}
