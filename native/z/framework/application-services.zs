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
import { replace } from "std/memory";
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

internal struct ConfiguredServices {
  routes: Services;
  asynchronous: readonly Map<String, AsyncServiceHandler>;
  lifecycles: ServiceLifecycles;
}

internal struct ApplicationServicesBuilder {
  internal routes: ServicesBuilder;
  internal asynchronous: AsyncServiceRegistry;
  internal lifecycles: ServiceLifecycleBuilder;

  internal function registerGenerated<T: Service>(
    inout this,
    name: String,
    service: T
  ): void {
    this.routes.register(move name, service);
  }

  internal function registerGeneratedAsync<T: AsyncService>(
    inout this,
    name: String,
    service: T
  ): void {
    const handler = asyncServiceHandler(service);
    this.asynchronous.add(move name, handler);
  }

  internal function registerGeneratedWithLifecycle<
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

  internal function registerGeneratedAsyncWithLifecycle<
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

  internal function prepareConfigured(
    inout this
  ): ConfiguredServices on thread.main {
    const routesReplacement: ServicesBuilder = createServices();
    const routes: ServicesBuilder = replace(
      inout this.routes,
      move routesReplacement
    );
    const asynchronousReplacement: AsyncServiceRegistry =
      createAsyncServiceRegistry();
    const asynchronous: AsyncServiceRegistry = replace(
      inout this.asynchronous,
      move asynchronousReplacement
    );
    const lifecyclesReplacement: ServiceLifecycleBuilder =
      createServiceLifecycles();
    const lifecycles: ServiceLifecycleBuilder = replace(
      inout this.lifecycles,
      move lifecyclesReplacement
    );
    return ConfiguredServices({
      routes: routes.freeze(),
      asynchronous: asynchronous.freeze(),
      lifecycles: lifecycles.freeze(),
    });
  }
}

internal function createApplicationServicesBuilder(
): ApplicationServicesBuilder on thread.main {
  return ApplicationServicesBuilder({
    routes: createServices(),
    asynchronous: createAsyncServiceRegistry(),
    lifecycles: createServiceLifecycles(),
  });
}

export readonly struct ServiceRegistrationError {
  service: String;
  message: String;
}

class ApplicationServicesState on thread.main {
  builder: ApplicationServicesBuilder;
  prepared: boolean;

  function ensureConfiguring(
    in service: String
  ): void throws ServiceRegistrationError {
    if (this.prepared) {
      throw ServiceRegistrationError({
        service: copy service,
        message: "services cannot be registered after Application.run() begins",
      });
    }
  }

  function registerGenerated<T: Service>(
    inout this,
    name: String,
    service: T
  ): void throws ServiceRegistrationError {
    try this.ensureConfiguring(in name);
    this.builder.registerGenerated(move name, service);
  }

  function registerGeneratedAsync<T: AsyncService>(
    inout this,
    name: String,
    service: T
  ): void throws ServiceRegistrationError {
    try this.ensureConfiguring(in name);
    this.builder.registerGeneratedAsync(move name, service);
  }

  function registerGeneratedWithLifecycle<
    T: Service & ServiceLifecycle
  >(
    inout this,
    name: String,
    service: T
  ): void throws ServiceRegistrationError {
    try this.ensureConfiguring(in name);
    this.builder.registerGeneratedWithLifecycle(move name, service);
  }

  function registerGeneratedAsyncWithLifecycle<
    T: AsyncService & ServiceLifecycle
  >(
    inout this,
    name: String,
    service: T
  ): void throws ServiceRegistrationError {
    try this.ensureConfiguring(in name);
    this.builder.registerGeneratedAsyncWithLifecycle(move name, service);
  }

  function prepare(inout this): ConfiguredServices {
    this.prepared = true;
    return this.builder.prepareConfigured();
  }
}

function createApplicationServicesState(
): ApplicationServicesState on thread.main {
  return new ApplicationServicesState({
    builder: createApplicationServicesBuilder(),
    prepared: false,
  });
}

export readonly class ApplicationServices on thread.main {
  internal readonly state: ApplicationServicesState;

  internal constructor() {
    this.state = createApplicationServicesState();
  }

  // Compiler/build marker for one application-owned service. The generated
  // build overlay selects the matching checked adapter without rewriting
  // application source.
  function register<T>(
    inout this,
    name: String,
    service: T
  ): void throws ServiceRegistrationError {}

  internal function registerGenerated<T: Service>(
    inout this,
    name: String,
    service: T
  ): void throws ServiceRegistrationError {
    try this.state.registerGenerated(move name, service);
  }

  internal function registerGeneratedAsync<T: AsyncService>(
    inout this,
    name: String,
    service: T
  ): void throws ServiceRegistrationError {
    try this.state.registerGeneratedAsync(move name, service);
  }

  internal function registerGeneratedWithLifecycle<
    T: Service & ServiceLifecycle
  >(
    inout this,
    name: String,
    service: T
  ): void throws ServiceRegistrationError {
    try this.state.registerGeneratedWithLifecycle(move name, service);
  }

  internal function registerGeneratedAsyncWithLifecycle<
    T: AsyncService & ServiceLifecycle
  >(
    inout this,
    name: String,
    service: T
  ): void throws ServiceRegistrationError {
    try this.state.registerGeneratedAsyncWithLifecycle(move name, service);
  }

  internal function prepare(inout this): ConfiguredServices {
    return this.state.prepare();
  }
}

internal function createApplicationServices(
): ApplicationServices on thread.main {
  return new ApplicationServices();
}
