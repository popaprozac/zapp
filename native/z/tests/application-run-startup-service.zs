import { ApplicationContext, ServiceLifecycle, ServiceLifecycleError, ServiceLifecyclePhase } from "zapp/service";
import console from "std/console";
import { thread } from "std/thread";

export readonly class StartupProbe implements ServiceLifecycle {
  fail: boolean;
  function ping(): i32 { return 42; }
  function start(in context: ApplicationContext): void throws ServiceLifecycleError on thread.main {
    console.log("service started");
    if (this.fail) throw ServiceLifecycleError({
      service: "probe", phase: ServiceLifecyclePhase.start, message: "intentional startup failure",
    });
  }
  function stop(in context: ApplicationContext): void throws ServiceLifecycleError on thread.main {
    console.log("service stopped");
  }
}
