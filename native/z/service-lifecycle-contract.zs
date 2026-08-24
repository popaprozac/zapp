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

export trait ServiceLifecycle {
  function start(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main;

  function stop(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main;
}

export type ServiceLifecycleHook = (
  phase: ServiceLifecyclePhase,
  in context: ApplicationContext
) => Result<void, ServiceLifecycleError> on thread.main;

// Compiler-generated service adapters will construct this value beside a
// concrete service that implements ServiceLifecycle. It remains a runtime
// representation detail rather than a second user-facing lifecycle.
export readonly class ServiceLifecycleAdapter {
  name: String;
  hook: ServiceLifecycleHook;

  function start(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    const observed = this.hook(ServiceLifecyclePhase.start, in context);
    match (observed) {
      success => return;
      failure(error) => throw error;
    }
  }

  function stop(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    const observed = this.hook(ServiceLifecyclePhase.stop, in context);
    match (observed) {
      success => return;
      failure(error) => throw error;
    }
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
