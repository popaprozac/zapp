import {
  ServiceHandler,
  ServiceInvocation,
  ServiceOutcome,
  ServiceRegistry,
  createServiceRegistry,
} from "./service-contract.zs";
import { Map } from "std/collections";

// A ServiceBinding is the temporary handwritten seam between an ordinary Z
// service and Zapp's runtime router. The compiler already derives the public
// frontend contract; a future synthesis pass can generate this adapter too.
export struct ServiceBinding {
  methods: Array<String>;
  handler: ServiceHandler;
}

export trait Service {
  function bind(move this, name: String): ServiceBinding;
}

export struct ServicesBuilder {
  registry: ServiceRegistry;

  function register<T: Service>(
    inout this,
    name: String,
    service: T
  ): void {
    const binding = service.bind(copy name);
    const { methods, handler } = move binding;
    for (const method of methods) {
      this.registry.add(`${name}.${method}`, handler);
    }
  }

  function freeze(move this): Services {
    return new Services({ handlers: this.registry.handlers.freeze() });
  }
}

export readonly class Services {
  readonly handlers: readonly Map<String, ServiceHandler>;

  function invoke(
    method: String,
    arguments: String
  ): ServiceOutcome {
    const found = this.handlers.get(method);
    match (in found) {
      some(handler) => {
        const selected: ServiceHandler = handler;
        const invocation = ServiceInvocation({
          method: move method,
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
