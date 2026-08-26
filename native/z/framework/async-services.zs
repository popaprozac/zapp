import {
  AsyncService,
  AsyncServiceHandler,
  AsyncServiceRegistry,
  createAsyncServiceRegistry,
} from "./async-service-contract.zs";
import {
  Service,
  Services,
  ServicesBuilder,
  createServices,
} from "./services.zs";
import {
  ServiceInvocation,
  ServiceOutcome,
} from "./service-contract.zs";
import { Map } from "std/collections";

function asyncServiceHandler<T: AsyncService>(
  service: T
): AsyncServiceHandler {
  return async move (
    in invocation: ServiceInvocation
  ): ServiceOutcome => await service.invoke(in invocation);
}

export struct AsyncServicesBuilder {
  synchronous: ServicesBuilder;
  asynchronous: AsyncServiceRegistry;

  function register<T: Service>(
    inout this,
    name: String,
    service: T
  ): void {
    this.synchronous.register(move name, service);
  }

  function registerAsync<T: AsyncService>(
    inout this,
    name: String,
    service: T
  ): void {
    const handler = asyncServiceHandler(service);
    this.asynchronous.add(move name, handler);
  }

  function freeze(move this): AsyncServices {
    const { synchronous, asynchronous } = move this;
    const routes = synchronous.freeze();
    const { handlers } = move asynchronous;
    return new AsyncServices({
      synchronous: routes,
      asynchronous: handlers.freeze(),
    });
  }
}

export readonly class AsyncServices {
  readonly synchronous: Services;
  readonly asynchronous: readonly Map<String, AsyncServiceHandler>;

  async function invoke(
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
    if (this.synchronous.handlers.has(serviceName)) {
      return this.synchronous.invoke(move method, move arguments);
    }

    const serviceMethod = method.copyBytes(
      separator + 1,
      method.byteLength
    );
    const found = this.asynchronous.get(serviceName);
    const selected = match (in found) {
      some(storedHandler) => Option.some(storedHandler);
      none => Option<AsyncServiceHandler>.none;
    };
    const invocation = ServiceInvocation({
      method: move serviceMethod,
      arguments: move arguments,
    });
    match (selected) {
      some(handler) => return await handler(in invocation);
      none => return ServiceOutcome.failure("UNKNOWN_METHOD");
    }
  }
}

export function createAsyncServices(): AsyncServicesBuilder {
  return AsyncServicesBuilder({
    synchronous: createServices(),
    asynchronous: createAsyncServiceRegistry(),
  });
}
