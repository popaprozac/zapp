import { AsyncServices } from "./async-services.zs";
import { ServiceLifecycles } from "./service-lifecycle.zs";
import { thread } from "std/thread";

export readonly class ApplicationConfig on thread.main {
  readonly name: String;
  readonly services: AsyncServices;
  readonly lifecycles: ServiceLifecycles;
}
