import native from "zapp_worker_runtime.h";
import console from "std/console";
import { thread } from "std/thread";

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
