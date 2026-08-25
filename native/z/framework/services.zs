import {
  ServiceHandler,
  ServiceInvocation,
  ServiceOutcome,
  ServiceRegistry,
  createServiceRegistry,
} from "./service-contract.zs";
import { Map } from "std/collections";

export trait Service {
  function invoke(in invocation: ServiceInvocation): ServiceOutcome;
}

function serviceHandler<T: Service>(service: T): ServiceHandler {
  return move (in invocation: ServiceInvocation): ServiceOutcome =>
    service.invoke(in invocation);
}

export struct ServicesBuilder {
  registry: ServiceRegistry;

  function register<T: Service>(
    inout this,
    name: String,
    service: T
  ): void {
    const handler = serviceHandler(service);
    this.registry.add(move name, handler);
  }

  function freeze(move this): Services {
    const { registry } = move this;
    const { handlers } = move registry;
    return new Services({ handlers: handlers.freeze() });
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
