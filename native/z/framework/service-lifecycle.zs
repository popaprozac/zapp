import {
  ApplicationContext,
  ServiceLifecycle,
  ServiceLifecycleError,
  ServiceLifecyclePhase,
} from "../api/zapp/service.zs";
import { thread } from "std/thread";

export type ServiceLifecycleHook = (
  phase: ServiceLifecyclePhase,
  in context: ApplicationContext
) => Result<void, ServiceLifecycleError> on thread.main;

readonly class ServiceLifecycleAdapter {
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

function invokeServiceLifecycle<T: ServiceLifecycle>(
  in service: T,
  phase: ServiceLifecyclePhase,
  in context: ApplicationContext
): Result<void, ServiceLifecycleError> on thread.main {
  return match (phase) {
    start => attempt service.start(in context);
    stop => attempt service.stop(in context);
  };
}

export struct ServiceLifecycleBuilder {
  entries: Array<ServiceLifecycleAdapter>;

  function add(
    inout this,
    name: String,
    hook: ServiceLifecycleHook
  ): void on thread.main {
    this.entries.push(new ServiceLifecycleAdapter({
      name: move name,
      hook,
    }));
  }

  function register<T: ServiceLifecycle>(
    inout this,
    name: String,
    service: T
  ): void on thread.main {
    const hook: ServiceLifecycleHook = move (
      phase: ServiceLifecyclePhase,
      in context: ApplicationContext
    ): Result<void, ServiceLifecycleError> =>
      invokeServiceLifecycle(in service, phase, in context);
    this.add(move name, hook);
  }

  function freeze(move this): ServiceLifecycles on thread.main {
    return new ServiceLifecycles({ entries: this.entries.freeze() });
  }
}

export readonly class ServiceLifecycles {
  readonly entries: readonly Array<ServiceLifecycleAdapter>;

  function start(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    let started: usize = 0;
    while (started < this.entries.length) {
      const entry: ServiceLifecycleAdapter = this.entries[started];
      const observed: Result<void, ServiceLifecycleError> =
        attempt entry.start(in context);
      match (observed) {
        success => started = started + 1;
        failure(error) => {
          let rollback = started;
          while (rollback > 0) {
            rollback = rollback - 1;
            const previous: ServiceLifecycleAdapter = this.entries[rollback];
            const stopped: Result<void, ServiceLifecycleError> =
              attempt previous.stop(in context);
            match (stopped) {
              success => {}
              failure(_) => {}
            }
          }
          throw error;
        }
      }
    }
  }

  function stop(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    let failed: boolean = false;
    let firstService: String = "";
    let firstPhase = ServiceLifecyclePhase.stop;
    let firstMessage: String = "";
    let remaining: usize = this.entries.length;
    while (remaining > 0) {
      remaining = remaining - 1;
      const entry: ServiceLifecycleAdapter = this.entries[remaining];
      const observed: Result<void, ServiceLifecycleError> =
        attempt entry.stop(in context);
      match (observed) {
        success => {}
        failure(error) => {
          if (!failed) {
            firstService = copy error.service;
            firstPhase = error.phase;
            firstMessage = copy error.message;
            failed = true;
          }
        }
      }
    }
    if (failed) {
      throw ServiceLifecycleError({
        service: move firstService,
        phase: firstPhase,
        message: move firstMessage,
      });
    }
  }
}

export function createServiceLifecycles(
): ServiceLifecycleBuilder on thread.main {
  return ServiceLifecycleBuilder({
    entries: Array<ServiceLifecycleAdapter>(),
  });
}
