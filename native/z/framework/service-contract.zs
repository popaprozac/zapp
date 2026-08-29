import { Map } from "std/collections";
import { thread } from "std/thread";

export struct ServiceInvocation {
  method: String;
  arguments: String;
}

export struct ServiceTypedFailure {
  service: String;
  method: String;
  errorType: String;
  message: String;
  details: String;
}

export enum ServiceOutcome {
  success String,
  failure String,
  typedFailure ServiceTypedFailure,
}

export type ServiceHandler =
  (in invocation: ServiceInvocation) => ServiceOutcome on thread.any;

export struct ServiceRegistry {
  handlers: Map<String, ServiceHandler>;

  function add(
    inout this,
    name: String,
    handler: ServiceHandler
  ): void {
    this.handlers.set(move name, handler);
  }

}

export function createServiceRegistry(): ServiceRegistry {
  return ServiceRegistry({ handlers: Map<String, ServiceHandler>() });
}
