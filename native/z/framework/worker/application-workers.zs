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
import { Services } from "../services.zs";

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

function allowsApplicationWorkerService(
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
  return match (invoked) {
    success(payload) => bridgeSuccess(0, move payload);
    failure(error) => bridgeFailure(0, "SERVICE_ERROR", move error);
    typedFailure(error) => bridgeTypedServiceFailure(0, move error);
  };
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
