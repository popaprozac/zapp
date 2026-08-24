import { thread } from "std/thread";

export struct ApplicationContext {
  name: String;
}

export enum ServiceLifecyclePhase {
  start,
  stop,
}

export struct ServiceLifecycleError {
  service: String;
  phase: ServiceLifecyclePhase;
  message: String;
}

export type ServiceStart =
  (in context: ApplicationContext) => void
    throws ServiceLifecycleError on thread.main;

export type ServiceStop =
  (in context: ApplicationContext) => void
    throws ServiceLifecycleError on thread.main;

// Compiler-generated service adapters will construct this value for a service
// that explicitly implements the future ServiceLifecycle trait. It remains a
// runtime representation detail rather than a second user-facing lifecycle.
export readonly class ServiceLifecycleAdapter {
  name: String;
  startHook: ServiceStart;
  stopHook: ServiceStop;

  function start(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    try this.startHook(in context);
  }

  function stop(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    try this.stopHook(in context);
  }
}

export function serviceLifecycleError(
  service: String,
  phase: ServiceLifecyclePhase,
  message: String
): ServiceLifecycleError {
  return ServiceLifecycleError({
    service: move service,
    phase,
    message: move message,
  });
}
