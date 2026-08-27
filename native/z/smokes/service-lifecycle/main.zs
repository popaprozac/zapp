import {
  ApplicationContext,
  ServiceLifecycle,
  ServiceLifecycleError,
  ServiceLifecyclePhase,
  serviceLifecycleError,
} from "../../framework/service-lifecycle-contract.zs";
import {
  createServiceLifecycles,
} from "../../framework/service-lifecycle.zs";
import {
  ServiceInvocation,
  ServiceOutcome,
} from "../../framework/service-contract.zs";
import {
  createApplicationServices,
} from "../../framework/application-services.zs";
import { Service } from "../../framework/services.zs";
import { thread } from "std/thread";
import { Mutex, Once } from "std/sync";

struct LifecycleTraceState {
  events: Array<i32>;
}

readonly class LifecycleTrace on thread.main {
  readonly state: Mutex<LifecycleTraceState>;

  function record(event: i32): void {
    this.state.withLock((inout state): void => state.events.push(event));
  }

  function length(): usize {
    return this.state.withLock((in state): usize => state.events.length);
  }

  function event(index: usize): i32 {
    return this.state.withLock(
      (in state): i32 => state.events[index]
    );
  }
}

const lifecycleTrace = Once<LifecycleTrace>();

function record(event: i32): void on thread.main {
  const trace = lifecycleTrace.get();
  trace.record(event);
}

function contextReady(in context: ApplicationContext): boolean {
  return context.name.byteLength > 0;
}

readonly class RecordingLifecycle on thread.main implements ServiceLifecycle {
  name: String;
  startEvent: i32;
  stopEvent: i32;
  failStart: boolean;
  failStop: boolean;

  function start(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    record(this.startEvent);
    if (this.failStart && contextReady(in context)) {
      throw serviceLifecycleError(
        copy this.name,
        ServiceLifecyclePhase.start,
        "start failed"
      );
    }
  }

  function stop(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    record(this.stopEvent);
    if (this.failStop && contextReady(in context)) {
      throw serviceLifecycleError(
        copy this.name,
        ServiceLifecyclePhase.stop,
        "stop failed"
      );
    }
  }
}

struct RegisteredServiceState {
  starts: i32;
  invocations: i32;
  stops: i32;
}

readonly class RegisteredService implements Service, ServiceLifecycle {
  readonly state: Mutex<RegisteredServiceState>;

  function invoke(in invocation: ServiceInvocation): ServiceOutcome {
    this.state.withLock(
      (inout state): void => {
        state.invocations = state.invocations + 1;
      }
    );
    return ServiceOutcome.success(copy invocation.arguments);
  }

  function start(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    if (!contextReady(in context)) return;
    this.state.withLock(
      (inout state): void => {
        state.starts = state.starts + 1;
      }
    );
  }

  function stop(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    if (!contextReady(in context)) return;
    this.state.withLock(
      (inout state): void => {
        state.stops = state.stops + 1;
      }
    );
  }

  function countsMatch(
    starts: i32,
    invocations: i32,
    stops: i32
  ): boolean {
    return this.state.withLock(
      (in state): boolean =>
        state.starts == starts
        && state.invocations == invocations
        && state.stops == stops
    );
  }
}

function createLifecycle(
  name: String,
  startEvent: i32,
  stopEvent: i32,
  failStart: boolean,
  failStop: boolean
): RecordingLifecycle on thread.main {
  return new RecordingLifecycle({
    name: move name,
    startEvent,
    stopEvent,
    failStart,
    failStop,
  });
}

function createTrace(): LifecycleTrace on thread.main {
  return new LifecycleTrace({
    state: Mutex(LifecycleTraceState({ events: Array<i32>() })),
  });
}

function eventsEqual(
  in trace: LifecycleTrace,
  expected: Slice<i32>
): boolean on thread.main {
  if (trace.length() != expected.length) return false;
  let index: usize = 0;
  while (index < expected.length) {
    if (trace.event(index) != expected[index]) return false;
    index = index + 1;
  }
  return true;
}

function normalLifecycle(in context: ApplicationContext): boolean on thread.main {
  let builder = createServiceLifecycles();
  builder.register(
    "first",
    createLifecycle("first", 1, -1, false, false)
  );
  builder.register(
    "second",
    createLifecycle("second", 2, -2, false, false)
  );
  const lifecycles = builder.freeze();
  const started = attempt lifecycles.start(in context);
  match (started) {
    success => {}
    failure(_) => return false;
  }
  const stopped = attempt lifecycles.stop(in context);
  match (stopped) {
    success => {}
    failure(_) => return false;
  }
  const trace = lifecycleTrace.get();
  const expected = [1, 2, -2, -1];
  return eventsEqual(in trace, expected);
}

function rollbackLifecycle(in context: ApplicationContext): boolean on thread.main {
  let builder = createServiceLifecycles();
  builder.register(
    "first",
    createLifecycle("first", 1, -1, false, false)
  );
  builder.register(
    "second",
    createLifecycle("second", 2, -2, true, false)
  );
  const lifecycles = builder.freeze();
  const started = attempt lifecycles.start(in context);
  match (started) {
    success => return false;
    failure(error) => {
      if (
        error.service != "second"
        || error.phase != ServiceLifecyclePhase.start
      ) return false;
    }
  }
  const trace = lifecycleTrace.get();
  const expected = [1, 2, -2, -1, 1, 2, -1];
  return eventsEqual(in trace, expected);
}

function failingStopLifecycle(
  in context: ApplicationContext
): boolean on thread.main {
  let builder = createServiceLifecycles();
  builder.register(
    "first",
    createLifecycle("first", 1, -1, false, true)
  );
  builder.register(
    "second",
    createLifecycle("second", 2, -2, false, true)
  );
  const lifecycles = builder.freeze();
  const started = attempt lifecycles.start(in context);
  match (started) {
    success => {}
    failure(_) => return false;
  }
  const stopped = attempt lifecycles.stop(in context);
  match (stopped) {
    success => return false;
    failure(error) => {
      if (
        error.service != "second"
        || error.phase != ServiceLifecyclePhase.stop
      ) return false;
    }
  }
  const trace = lifecycleTrace.get();
  const expected = [1, 2, -2, -1, 1, 2, -1, 1, 2, -2, -1];
  return eventsEqual(in trace, expected);
}

function registeredServiceLifecycle(
  in context: ApplicationContext
): boolean on thread.main {
  const service = new RegisteredService({
    state: Mutex(RegisteredServiceState({
      starts: 0,
      invocations: 0,
      stops: 0,
    })),
  });
  let builder = createApplicationServices();
  builder.__registerGeneratedWithLifecycle("registered", service);
  const { routes, lifecycles } = builder.freezeConfigured();

  const started = attempt lifecycles.start(in context);
  match (started) {
    success => {}
    failure(_) => return false;
  }
  const outcome = routes.invoke("registered.echo", "same identity");
  match (outcome) {
    success(payload) => {
      if (payload != "same identity") return false;
    }
    failure(_) => return false;
  }
  const stopped = attempt lifecycles.stop(in context);
  match (stopped) {
    success => {}
    failure(_) => return false;
  }
  return service.countsMatch(1, 1, 1);
}

function main(): i32 {
  const lifetime = lifecycleTrace.initialize(createTrace());
  const context = ApplicationContext({ name: "Lifecycle smoke" });
  if (!normalLifecycle(in context)) return 1;
  if (!rollbackLifecycle(in context)) return 2;
  if (!failingStopLifecycle(in context)) return 3;
  if (!registeredServiceLifecycle(in context)) return 4;
  return 0;
}
