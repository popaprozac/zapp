import {
  BridgeResponse,
} from "../../framework/bridge.zs";
import {
  AsyncServices,
  createAsyncServices,
} from "../../framework/async-services.zs";
import { AsyncService } from "../../framework/async-service-contract.zs";
import { Service } from "../../framework/services.zs";
import {
  routeMessageWithServicesAsync,
} from "../../framework/async-bridge.zs";
import {
  PendingRequests,
  createPendingRequests,
} from "../../framework/pending-requests.zs";
import {
  ServiceInvocation,
  ServiceOutcome,
} from "../../framework/service-contract.zs";
import { scheduler, TaskScope } from "std/async";
import console from "std/console";
import { Mutex } from "std/sync";
import { thread } from "std/thread";
import { delay } from "std/time";

struct CancellationState {
  started: boolean;
  cancellationRequested: boolean;
  resumedAfterCancellation: boolean;
  successfulResponse: boolean;
}

readonly class CancellationProbe {
  readonly state: Mutex<CancellationState>;

  function markStarted(): void {
    this.state.withLock((inout state): void => {
      state.started = true;
    });
  }

  function markResumedAfterCancellation(): void {
    this.state.withLock((inout state): void => {
      state.resumedAfterCancellation = true;
    });
  }

  function markCancellationRequested(value: boolean): void {
    this.state.withLock((inout state): void => {
      state.cancellationRequested = value;
    });
  }

  function markSuccessfulResponse(value: boolean): void {
    this.state.withLock((inout state): void => {
      state.successfulResponse = value;
    });
  }

  function snapshot(): CancellationState {
    return this.state.withLock(
      (in state): CancellationState => copy state
    );
  }
}

readonly class CancellableOperation {
  readonly probe: CancellationProbe;

  async function run(): void on thread.main {
    this.probe.markStarted();
    await delay(1000);
    this.probe.markResumedAfterCancellation();
  }
}

readonly class SearchService implements AsyncService {
  readonly prefix: String;

  async function invoke(
    in invocation: ServiceInvocation
  ): ServiceOutcome {
    await scheduler.yield();
    if (this.prefix != "search") {
      return ServiceOutcome.failure("INVALID_SERVICE");
    }
    if (invocation.method != "find") {
      return ServiceOutcome.failure("UNKNOWN_METHOD");
    }
    return ServiceOutcome.success(copy invocation.arguments);
  }
}

readonly class HealthService implements Service {
  function invoke(in invocation: ServiceInvocation): ServiceOutcome {
    if (invocation.method != "status") {
      return ServiceOutcome.failure("UNKNOWN_METHOD");
    }
    return ServiceOutcome.success("healthy");
  }
}

function validate(in response: Option<BridgeResponse>): i32 {
  return match (response) {
    some(value) => {
      if (value.id != 42) return 1;
      if (!value.ok) return 2;
      if (value.payload != '{"query":"Z"}') return 3;
      select 0;
    }
    none => 4;
  };
}

function validateHealth(in response: Option<BridgeResponse>): i32 {
  return match (response) {
    some(value) => {
      if (value.id != 41) return 1;
      if (!value.ok) return 2;
      if (value.payload != "healthy") return 3;
      select 0;
    }
    none => 4;
  };
}

async function validateRoutes(services: AsyncServices): i32 {
  const healthRequest =
    '{"t":1,"id":41,"m":"health.status","a":{}}';
  const healthResponse = await routeMessageWithServicesAsync(
    copy healthRequest,
    services
  );
  const healthStatus = validateHealth(in healthResponse);
  if (healthStatus != 0) return 10 + healthStatus;

  const request =
    '{"t":1,"id":42,"m":"search.find","a":{"query":"Z"}}';
  const response = await routeMessageWithServicesAsync(
    copy request,
    services
  );
  return validate(in response);
}

async function routeSuccessfulRequest(
  services: AsyncServices,
  requests: PendingRequests,
  id: u64,
  generation: u64,
  probe: CancellationProbe
): void on thread.main {
  const response = await routeMessageWithServicesAsync(
    '{"t":1,"id":51,"m":"search.find","a":{"query":"after cancellation"}}',
    services
  );
  requests.finish(id, generation);
  const valid = match (response) {
    some(value) => value.id == 51
      && value.ok
      && value.payload == '{"query":"after cancellation"}';
    none => false;
  };
  probe.markSuccessfulResponse(valid);
}

async function validateCancellation(
  services: AsyncServices,
  probe: CancellationProbe
): i32 on thread.main {
  const updates = new TaskScope();
  const requests = createPendingRequests();
  const operation = new CancellableOperation({ probe });

  const cancelledGeneration = requests.begin(50);
  const cancelledControl = updates.schedule(
    thread.main,
    async move (): void => await operation.run()
  );
  requests.attach(50, cancelledControl);
  if (!cancelledControl.accepted) return 1;
  if (cancelledGeneration == 0) return 10;

  const cancellationControl = updates.schedule(
    thread.main,
    async move (): void =>
      probe.markCancellationRequested(requests.cancel(50))
  );
  if (!cancellationControl.accepted) return 2;

  const successfulGeneration = requests.begin(51);
  const successfulControl = updates.schedule(
    thread.main,
    async move (): void => await routeSuccessfulRequest(
      services,
      requests,
      51,
      successfulGeneration,
      probe
    )
  );
  requests.attach(51, successfulControl);
  if (!successfulControl.accepted) return 3;

  await updates.close();
  const observed = probe.snapshot();
  if (!observed.started) return 4;
  if (!observed.cancellationRequested) return 5;
  if (observed.resumedAfterCancellation) return 6;
  if (!observed.successfulResponse) return 7;
  if (requests.cancel(50)) return 8;
  if (requests.cancel(51)) return 9;
  return 0;
}

async function main(): i32 on thread.main {
  let builder = createAsyncServices();
  builder.register("health", new HealthService({}));
  builder.registerAsync(
    "search",
    new SearchService({ prefix: "search" })
  );
  const cancellationProbe = new CancellationProbe({
    state: Mutex(CancellationState({
      started: false,
      cancellationRequested: false,
      resumedAfterCancellation: false,
      successfulResponse: false,
    })),
  });
  const services = builder.freeze();
  const status = await validateRoutes(services);
  if (status != 0) return status;
  const cancellationStatus = await validateCancellation(
    services,
    cancellationProbe
  );
  if (cancellationStatus != 0) return 20 + cancellationStatus;

  console.log(
    "Zapp async service smoke passed: routes + deterministic cancellation"
  );
  return 0;
}
