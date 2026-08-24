import {
  ApplicationContext,
  ServiceLifecycleAdapter,
  ServiceLifecycleError,
  ServiceLifecyclePhase,
} from "./service-lifecycle-contract.zs";
import { thread } from "std/thread";

export struct ServiceLifecycleBuilder {
  entries: Array<ServiceLifecycleAdapter>;

  // Compiler-produced service metadata calls this after generating a concrete
  // adapter beside the user's lifecycle type. It is framework plumbing rather
  // than a second application-facing lifecycle API.
  function addGenerated(
    inout this,
    lifecycle: ServiceLifecycleAdapter
  ): void on thread.main {
    this.entries.push(move lifecycle);
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
