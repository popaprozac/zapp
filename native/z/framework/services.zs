import {
  ServiceHandler,
  ServiceInvocation,
  ServiceOutcome,
  ServiceRegistry,
  createServiceRegistry,
} from "./service-contract.zs";
import {
  ApplicationContext,
  ServiceLifecycle,
  ServiceLifecycleError,
  ServiceLifecycleHook,
  ServiceLifecyclePhase,
} from "./service-lifecycle-contract.zs";
import {
  ServiceLifecycleBuilder,
  ServiceLifecycles,
  createServiceLifecycles,
} from "./service-lifecycle.zs";
import { Map } from "std/collections";
import { thread } from "std/thread";

export trait Service {
  function handler(): ServiceHandler;
}

function invokeRegisteredServiceLifecycle<T: Service & ServiceLifecycle>(
  in service: T,
  phase: ServiceLifecyclePhase,
  in context: ApplicationContext
): Result<void, ServiceLifecycleError> on thread.main {
  return match (phase) {
    start => attempt service.start(in context);
    stop => attempt service.stop(in context);
  };
}

export struct ConfiguredServices {
  routes: Services;
  lifecycles: ServiceLifecycles;
}

export struct ServicesBuilder {
  registry: ServiceRegistry;

  function register<T: Service>(
    inout this,
    name: String,
    service: T
  ): void {
    const handler = service.handler();
    this.registry.add(move name, handler);
  }

  function freeze(move this): Services {
    const { registry } = move this;
    const { handlers } = move registry;
    return new Services({ handlers: handlers.freeze() });
  }
}

export struct ApplicationServicesBuilder {
  routes: ServicesBuilder;
  lifecycles: ServiceLifecycleBuilder;

  function register<T: Service>(
    inout this,
    name: String,
    service: T
  ): void {
    const handler = service.handler();
    this.routes.registry.add(move name, handler);
  }

  function registerWithLifecycle<T: Service & ServiceLifecycle>(
    inout this,
    name: String,
    service: T
  ): void on thread.main {
    const handler = service.handler();
    const hook: ServiceLifecycleHook = move (
      phase: ServiceLifecyclePhase,
      in context: ApplicationContext
    ): Result<void, ServiceLifecycleError> =>
      invokeRegisteredServiceLifecycle(in service, phase, in context);
    this.routes.registry.add(copy name, handler);
    this.lifecycles.add(move name, hook);
  }

  function freezeConfigured(
    move this
  ): ConfiguredServices on thread.main {
    const { routes, lifecycles } = move this;
    const { registry } = move routes;
    const { handlers } = move registry;
    return ConfiguredServices({
      routes: new Services({ handlers: handlers.freeze() }),
      lifecycles: lifecycles.freeze(),
    });
  }
}

export readonly class Services {
  readonly handlers: readonly Map<String, ServiceHandler>;

  function invoke(
    method: String,
    arguments: String
  ): ServiceOutcome {
    let separator: usize = 0;
    while (
      separator < method.byteLength
      && method.byteAt(separator) != 46
    ) {
      separator = separator + 1;
    }
    if (separator == 0 || separator == method.byteLength) {
      return ServiceOutcome.failure("UNKNOWN_METHOD");
    }
    const serviceName = method.copyBytes(0, separator);
    const serviceMethod = method.copyBytes(separator + 1, method.byteLength);
    const found = this.handlers.get(serviceName);
    match (in found) {
      some(handler) => {
        const selected: ServiceHandler = handler;
        const invocation = ServiceInvocation({
          method: move serviceMethod,
          arguments: move arguments,
        });
        return selected(in invocation);
      }
      none => return ServiceOutcome.failure("UNKNOWN_METHOD");
    }
  }
}

export function createServices(): ServicesBuilder {
  return ServicesBuilder({ registry: createServiceRegistry() });
}

export function createApplicationServices(
): ApplicationServicesBuilder on thread.main {
  return ApplicationServicesBuilder({
    routes: createServices(),
    lifecycles: createServiceLifecycles(),
  });
}
