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
  ServiceLifecyclePhase,
} from "../api/zapp/service.zs";
import {
  ServiceLifecycleBuilder,
  ServiceLifecycleHook,
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

  // Compiler/build marker for one ordinary application-owned service. Zapp's
  // generated build overlay adapts this checked call to the matching runtime
  // method and adapter without rewriting application source.
  function register<T>(
    inout this,
    name: String,
    service: T
  ): void {}

  function __registerGenerated<T: Service>(
    inout this,
    name: String,
    service: T
  ): void {
    this.routes.register(move name, service);
  }

  function __registerGeneratedAsync<T: AsyncService>(
    inout this,
    name: String,
    service: T
  ): void {
    const handler = asyncServiceHandler(service);
    this.asynchronous.add(move name, handler);
  }

  function __registerGeneratedWithLifecycle<
    T: Service & ServiceLifecycle
  >(
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

  function __registerGeneratedAsyncWithLifecycle<
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
