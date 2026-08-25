import {
  AsyncService,
  AsyncServiceHandler,
  AsyncServiceRegistry,
  createAsyncServiceRegistry,
} from "./async-service-contract.zs";
import {
  ServiceHandler,
  ServiceInvocation,
  ServiceOutcome,
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
import {
  Service,
  Services,
  ServicesBuilder,
  createServices,
} from "./services.zs";
import { Map } from "std/collections";
import { thread } from "std/thread";

function serviceHandler<T: Service>(service: T): ServiceHandler {
  return move (in invocation: ServiceInvocation): ServiceOutcome =>
    service.invoke(in invocation);
}

function asyncServiceHandler<T: AsyncService>(
  service: T
): AsyncServiceHandler {
  return async move (
    in invocation: ServiceInvocation
  ): ServiceOutcome => await service.invoke(in invocation);
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

function invokeRegisteredAsyncServiceLifecycle<
  T: AsyncService & ServiceLifecycle
>(
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
  asynchronous: readonly Map<String, AsyncServiceHandler>;
  lifecycles: ServiceLifecycles;
}

export struct ApplicationServicesBuilder {
  routes: ServicesBuilder;
  asynchronous: AsyncServiceRegistry;
  lifecycles: ServiceLifecycleBuilder;

  function register<T: Service>(
    inout this,
    name: String,
    service: T
  ): void {
    const handler = serviceHandler(service);
    this.routes.registry.add(move name, handler);
  }

  function registerAsync<T: AsyncService>(
    inout this,
    name: String,
    service: T
  ): void {
    const handler = asyncServiceHandler(service);
    this.asynchronous.add(move name, handler);
  }

  function registerWithLifecycle<T: Service & ServiceLifecycle>(
    inout this,
    name: String,
    service: T
  ): void on thread.main {
    const handler = serviceHandler(service);
    const hook: ServiceLifecycleHook = move (
      phase: ServiceLifecyclePhase,
      in context: ApplicationContext
    ): Result<void, ServiceLifecycleError> =>
      invokeRegisteredServiceLifecycle(in service, phase, in context);
    this.routes.registry.add(copy name, handler);
    this.lifecycles.add(move name, hook);
  }

  function registerAsyncWithLifecycle<
    T: AsyncService & ServiceLifecycle
  >(
    inout this,
    name: String,
    service: T
  ): void on thread.main {
    const handler = asyncServiceHandler(service);
    const hook: ServiceLifecycleHook = move (
      phase: ServiceLifecyclePhase,
      in context: ApplicationContext
    ): Result<void, ServiceLifecycleError> =>
      invokeRegisteredAsyncServiceLifecycle(
        in service,
        phase,
        in context
      );
    this.asynchronous.add(copy name, handler);
    this.lifecycles.add(move name, hook);
  }

  function freezeConfigured(
    move this
  ): ConfiguredServices on thread.main {
    const { routes, asynchronous, lifecycles } = move this;
    return ConfiguredServices({
      routes: routes.freeze(),
      asynchronous: asynchronous.freeze(),
      lifecycles: lifecycles.freeze(),
    });
  }
}

export function createApplicationServices(
): ApplicationServicesBuilder on thread.main {
  return ApplicationServicesBuilder({
    routes: createServices(),
    asynchronous: createAsyncServiceRegistry(),
    lifecycles: createServiceLifecycles(),
  });
}
