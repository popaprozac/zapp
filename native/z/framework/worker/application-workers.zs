import native from "zapp_worker_runtime.h";
import console from "std/console";
import { thread } from "std/thread";
import {
  BridgeResponse,
  bridgeFailure,
  bridgeSuccess,
  bridgeTypedServiceFailure,
  bridgeWorkerCapabilityFailure,
} from "../bridge.zs";
import { ServiceOutcome } from "../service-contract.zs";
import { Services } from "../services.zs";
import { TaskControl } from "std/async";
import { Map } from "std/collections";
import { Mutex } from "std/sync";

export enum ApplicationWorkerDispatch {
  accepted,
  unavailable,
  saturated,
  failed,
}

// Engine adapters retain this callable through a checked `thread any`
// callback contract. Engine-specific boundaries copy borrowed native bytes
// before publishing these ordinary owned Z strings.
export type ApplicationWorkerMessageHandler = (
  workerId: String,
  channel: String,
  payload: String
) => void on thread.any;

export type ApplicationWorkerAsyncServiceHandler = (
  workerIdentity: usize,
  workerId: String,
  requestId: u64,
  method: String,
  arguments: String
) => void on thread.any;

export type ApplicationWorkerServiceCancelHandler = (
  requestId: u64
) => void on thread.any;

internal readonly class ApplicationWorkerServiceRequest {
  readonly generation: u64;
  readonly control: Option<TaskControl>;

  function requestCancel(): boolean {
    return match (in this.control) {
      some(value) => value.requestCancel();
      none => false;
    };
  }
}

internal struct ApplicationWorkerServiceRequestState {
  requests: Map<u64, ApplicationWorkerServiceRequest>;
  nextGeneration: u64;
}

// Request admission happens on the engine thread, while execution and
// completion happen on the application executor. The intrinsic Mutex handle
// is captured directly by each operation so native analysis can prove the
// shared state is safe on arbitrary threads without a second ARC wrapper.
internal function createApplicationWorkerServiceRequests(
): Mutex<ApplicationWorkerServiceRequestState> {
  return Mutex(ApplicationWorkerServiceRequestState({
    requests: Map<u64, ApplicationWorkerServiceRequest>(),
    nextGeneration: 1,
  }));
}

internal function beginApplicationWorkerServiceRequest(
  in requests: Mutex<ApplicationWorkerServiceRequestState>,
  requestId: u64
): u64 {
  return requests.withLock(
    (inout state): u64 => {
      const generation = state.nextGeneration;
      state.nextGeneration = state.nextGeneration + 1;
      // Service request IDs are process-wide and never reused. Delete is a
      // defensive replacement guard without introducing a second owner.
      state.requests.delete(requestId);
      state.requests.set(
        requestId,
        new ApplicationWorkerServiceRequest({
          generation,
          control: Option<TaskControl>.none,
        })
      );
      return generation;
    }
  );
}

internal function attachApplicationWorkerServiceRequest(
  in requests: Mutex<ApplicationWorkerServiceRequestState>,
  requestId: u64,
  control: TaskControl
): void {
  const attached = requests.withLock(
    (inout state): boolean => {
      const found = state.requests.get(requestId);
      const generation = match (in found) {
        some(request) => Option<u64>.some(request.generation);
        none => Option<u64>.none;
      };
      return match (generation) {
        some(value) => {
          state.requests.set(
            requestId,
            new ApplicationWorkerServiceRequest({
              generation: value,
              control: Option.some(control),
            })
          );
          select true;
        }
        none => false;
      };
    }
  );
  if (!attached) control.requestCancel();
}

internal function finishApplicationWorkerServiceRequest(
  in requests: Mutex<ApplicationWorkerServiceRequestState>,
  requestId: u64,
  generation: u64
): void {
  requests.withLock(
    (inout state): void => {
      const found = state.requests.get(requestId);
      const matches = match (in found) {
        some(request) => request.generation == generation;
        none => false;
      };
      if (matches) state.requests.delete(requestId);
    }
  );
}

internal function cancelApplicationWorkerServiceRequest(
  in requests: Mutex<ApplicationWorkerServiceRequestState>,
  requestId: u64
): boolean {
  return requests.withLock(
    (inout state): boolean => {
      const found = state.requests.get(requestId);
      const requested: boolean = match (in found) {
        some(request) => request.requestCancel();
        none => false;
      };
      state.requests.delete(requestId);
      return requested;
    }
  );
}

internal function cancelAllApplicationWorkerServiceRequests(
  in requests: Mutex<ApplicationWorkerServiceRequestState>
): void {
  requests.withLock(
    (inout state): void => {
      for (const entry of state.requests) {
        const request: ApplicationWorkerServiceRequest = entry.value;
        request.requestCancel();
      }
      state.requests.clear();
    }
  );
}

internal function allowsApplicationWorkerService(
  in serviceMethods: readonly Array<String>,
  in method: String
): boolean {
  let index: usize = 0;
  while (index < serviceMethods.length) {
    if (serviceMethods[index] == method) return true;
    index = index + 1;
  }
  return false;
}

internal function applicationWorkerServiceResponse(
  invoked: ServiceOutcome
): BridgeResponse on thread.any {
  return match (invoked) {
    success(payload) => bridgeSuccess(0, move payload);
    failure(error) => bridgeFailure(0, "SERVICE_ERROR", move error);
    typedFailure(error) => bridgeTypedServiceFailure(0, move error);
  };
}

internal function completeApplicationWorkerService(
  workerIdentity: usize,
  requestId: u64,
  in response: BridgeResponse
): boolean on thread.any {
  const status = native.zapp_worker_runtime_complete_service(
    workerIdentity,
    requestId,
    response.ok ? 1 : 0,
    response.payload
  );
  return status == 0;
}

// Engine-neutral direct service route. Worker configuration supplies an
// immutable allowlist, and Services contains only synchronous handlers already
// proven callable on thread.any. Engine adapters are responsible only for
// converting their JS values to and from the shared JSON service wire shape.
export function invokeApplicationWorkerService(
  in services: Services,
  in serviceMethods: readonly Array<String>,
  in workerId: String,
  method: String,
  arguments: String
): BridgeResponse on thread.any {
  if (!allowsApplicationWorkerService(in serviceMethods, in method)) {
    return bridgeWorkerCapabilityFailure(0, copy workerId, move method);
  }
  const invoked = services.invoke(move method, move arguments);
  return applicationWorkerServiceResponse(move invoked);
}

export readonly class ApplicationWorkerControl {
  readonly id: String;
  readonly identity: usize;

  function requestCancellation(): void {
    native.zapp_worker_runtime_cancel(this.identity);
  }

  // Private engine-neutral transport proof. The product-facing manager and
  // authorization surface deliberately remain outside this first slice.
  internal function dispatch(
    in channel: String,
    in payload: String
  ): ApplicationWorkerDispatch {
    const status = native.zapp_worker_runtime_dispatch(
      this.identity,
      channel,
      payload
    );
    if (status == 0) return ApplicationWorkerDispatch.accepted;
    if (status == 3) return ApplicationWorkerDispatch.unavailable;
    if (status == 4) return ApplicationWorkerDispatch.saturated;
    return ApplicationWorkerDispatch.failed;
  }

  function join(): void {
    const status = native.zapp_worker_runtime_join(this.identity);
    if (status != 0) {
      console.error("application worker failed");
    } else {
      console.log("application worker joined after cancellation");
    }
  }

  deinit {
    native.zapp_worker_runtime_destroy(this.identity);
  }
}

// Runtime ownership for application-lifetime workers. Each engine-specific
// control retains one native lifetime and exposes engine-erased cancellation
// and join phases to the application thread.
export readonly class ApplicationWorkers {
  readonly controls: readonly Array<ApplicationWorkerControl>;

  function requestCancellation(): void {
    let index: usize = 0;
    while (index < this.controls.length) {
      const control: ApplicationWorkerControl = this.controls[index];
      control.requestCancellation();
      index = index + 1;
    }
  }

  internal function dispatch(
    in workerId: String,
    in channel: String,
    in payload: String
  ): ApplicationWorkerDispatch {
    let index: usize = 0;
    while (index < this.controls.length) {
      const control: ApplicationWorkerControl = this.controls[index];
      if (control.id == workerId) {
        return control.dispatch(in channel, in payload);
      }
      index = index + 1;
    }
    return ApplicationWorkerDispatch.unavailable;
  }

  function join(): void {
    let index: usize = 0;
    while (index < this.controls.length) {
      const control: ApplicationWorkerControl = this.controls[index];
      control.join();
      index = index + 1;
    }
  }
}

export function emptyApplicationWorkers(): ApplicationWorkers {
  let controls = Array<ApplicationWorkerControl>();
  return new ApplicationWorkers({ controls: controls.freeze() });
}

// The generated configured-application module consumes this fallback in
// editor checks and applications without configured workers.
export function startEmptyApplicationWorkers(): ApplicationWorkers {
  return emptyApplicationWorkers();
}
