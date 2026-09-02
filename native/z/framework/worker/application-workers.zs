import native from "zapp_worker_runtime.h";
import console from "std/console";

export readonly class ApplicationWorkerControl {
  readonly identity: usize;

  function requestCancellation(): void {
    native.zapp_worker_runtime_cancel(this.identity);
  }

  // Private engine-neutral transport proof. The product-facing manager and
  // authorization surface deliberately remain outside this first slice.
  internal function dispatch(
    in channel: String,
    in payload: String
  ): boolean {
    return native.zapp_worker_runtime_dispatch(
      this.identity,
      channel,
      payload
    ) == 0;
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
