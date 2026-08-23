import {
  ServiceHandler,
  ServiceInvocation,
  ServiceOutcome,
  ServiceRegistry,
  createServiceRegistry,
} from "./service-contract.zs";
import { Map } from "std/collections";
import {
  NotesService,
  createNotesHandler,
} from "./notes-service.zs";

export struct ServicesBuilder {
  registry: ServiceRegistry;

  function register(
    inout this,
    name: String,
    service: NotesService
  ): void {
    const handler = createNotesHandler(copy name, move service);
    this.registry.add(`${name}.create`, handler);
    this.registry.add(`${name}.count`, handler);
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
