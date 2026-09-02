import { Map } from "std/collections";
import { thread } from "std/thread";
import {
  ApplicationWorkerDispatch,
} from "./application-workers.zs";
import { ApplicationWorkerCatalog } from "./configuration.zs";
import {
  ApplicationWorkerEvents,
  createApplicationWorkerEvents,
} from "./events.zs";

export enum ApplicationWorkerState {
  configured,
  running,
  restarting,
  stopped,
  failed,
}

export enum ApplicationWorkerSendErrorKind {
  invalidChannel,
  unavailable,
  saturated,
  failed,
}

export readonly struct ApplicationWorkerSendError {
  workerId: String;
  kind: ApplicationWorkerSendErrorKind;
  message: String;
}

internal type ApplicationWorkerSendOperation = (
  in workerId: String,
  in channel: String,
  in payload: String
) => ApplicationWorkerDispatch on thread.main;

class ApplicationWorkerStateStorage on thread.main {
  value: ApplicationWorkerState;

  internal constructor() {
    this.value = ApplicationWorkerState.configured;
  }
}

export readonly class ApplicationWorker on thread.main {
  readonly id: String;
  readonly events: ApplicationWorkerEvents;
  internal readonly manager: Weak<WorkerManager>;
  internal readonly currentState: ApplicationWorkerStateStorage;

  internal constructor(id: String, manager: Weak<WorkerManager>) {
    this.id = move id;
    this.events = createApplicationWorkerEvents();
    this.manager = manager;
    this.currentState = new ApplicationWorkerStateStorage();
  }

  function state(): ApplicationWorkerState {
    return this.currentState.value;
  }

  function send(
    channel: String,
    payload: String
  ): void throws ApplicationWorkerSendError {
    const id = copy this.id;
    if (channel.byteLength == 0) {
      throw ApplicationWorkerSendError({
        workerId: copy id,
        kind: ApplicationWorkerSendErrorKind.invalidChannel,
        message: "application worker channel must not be empty",
      });
    }
    const owner = attempt this.manager.upgrade();
    const dispatch = match (owner) {
      success(manager) => manager.dispatch(in id, in channel, in payload);
      failure(_) => ApplicationWorkerDispatch.unavailable;
    };
    match (dispatch) {
      accepted => return;
      unavailable => throw ApplicationWorkerSendError({
        workerId: copy id,
        kind: ApplicationWorkerSendErrorKind.unavailable,
        message: `application worker "${id}" is not running`,
      });
      saturated => throw ApplicationWorkerSendError({
        workerId: copy id,
        kind: ApplicationWorkerSendErrorKind.saturated,
        message: `application worker "${id}" cannot accept more work`,
      });
      failed => throw ApplicationWorkerSendError({
        workerId: copy id,
        kind: ApplicationWorkerSendErrorKind.failed,
        message: `application worker "${id}" could not accept the message`,
      });
    }
  }

  internal function publishStarted(incarnation: u64): void {
    const id = copy this.id;
    let state = this.currentState;
    state.value = ApplicationWorkerState.running;
    let events = this.events;
    events.publishStarted(in id, incarnation);
  }

  internal function publishRestarting(
    incarnation: u64,
    retry: u64,
    maxRetries: u64,
    withinMilliseconds: u64,
    in message: String
  ): void {
    const id = copy this.id;
    let state = this.currentState;
    state.value = ApplicationWorkerState.restarting;
    let events = this.events;
    events.publishRestarting(
      in id,
      incarnation,
      retry,
      maxRetries,
      withinMilliseconds,
      in message
    );
  }

  internal function publishFailed(
    incarnation: u64,
    retries: u64,
    in message: String
  ): void {
    const id = copy this.id;
    let state = this.currentState;
    state.value = ApplicationWorkerState.failed;
    let events = this.events;
    events.publishFailed(in id, incarnation, retries, in message);
  }

  internal function publishStopped(): void {
    const id = copy this.id;
    let state = this.currentState;
    state.value = ApplicationWorkerState.stopped;
    let events = this.events;
    events.publishStopped(in id);
    events.finish();
  }

  internal function finishEvents(): void {
    let events = this.events;
    events.finish();
  }
}

class WorkerManagerState on thread.main {
  workers: Map<String, ApplicationWorker>;
  send: Option<ApplicationWorkerSendOperation>;
  active: boolean;

  internal constructor() {
    this.workers = Map<String, ApplicationWorker>();
    this.send = Option<ApplicationWorkerSendOperation>.none;
    this.active = false;
  }
}

// Configured handles exist before run so callers can subscribe to lifecycle
// events; engine controls are installed after services and the platform runtime
// are ready.
export readonly class WorkerManager on thread.main {
  internal readonly catalog: ApplicationWorkerCatalog;
  internal readonly storage: WorkerManagerState;

  internal constructor(catalog: ApplicationWorkerCatalog) {
    this.catalog = catalog;
    this.storage = new WorkerManagerState();
  }

  internal function configure(inout this): void {
    const owner = weak this;
    let storage = this.storage;
    let index: usize = 0;
    while (index < this.catalog.entries.length) {
      const id: String = this.catalog.entries[index].id.copyBytes(
        0,
        this.catalog.entries[index].id.byteLength
      );
      storage.workers.set(
        copy id,
        new ApplicationWorker(move id, owner)
      );
      index = index + 1;
    }
  }

  function get(in id: String): Option<ApplicationWorker> {
    const found = this.storage.workers.get(id);
    return match (in found) {
      some(worker) => Option.some(worker);
      none => Option.none;
    };
  }

  function all(): Array<ApplicationWorker> {
    let result = Array<ApplicationWorker>();
    for (const entry of this.storage.workers) {
      let retained = entry.value;
      result.push(move retained);
    }
    return result;
  }

  internal function install(
    inout this,
    send: ApplicationWorkerSendOperation
  ): void {
    let storage = this.storage;
    storage.send = Option.some(send);
    storage.active = true;
  }

  internal function dispatch(
    in workerId: String,
    in channel: String,
    in payload: String
  ): ApplicationWorkerDispatch {
    if (!this.storage.active) return ApplicationWorkerDispatch.unavailable;
    return match (in this.storage.send) {
      some(send) => send(in workerId, in channel, in payload);
      none => ApplicationWorkerDispatch.unavailable;
    };
  }

  internal function publishLifecycle(
    inout this,
    in workerId: String,
    phase: i32,
    incarnation: u64,
    retry: u64,
    maxRetries: u64,
    withinMilliseconds: u64,
    in message: String
  ): void {
    const found = this.get(in workerId);
    match (found) {
      some(worker) => {
        if (phase == 1) {
          worker.publishStarted(incarnation);
          return;
        }
        if (phase == 2) {
          worker.publishRestarting(
            incarnation,
            retry,
            maxRetries,
            withinMilliseconds,
            in message
          );
          return;
        }
        if (phase == 3) {
          worker.publishFailed(incarnation, retry, in message);
        }
      }
      none => {}
    }
  }

  internal function finish(inout this): void {
    if (!this.storage.active) return;
    let storage = this.storage;
    storage.active = false;
    storage.send = Option<ApplicationWorkerSendOperation>.none;
    for (const entry of this.storage.workers) {
      const worker = entry.value;
      match (worker.state()) {
        failed => worker.finishEvents();
        stopped => worker.finishEvents();
        _ => worker.publishStopped();
      }
    }
  }
}

export function createWorkerManager(
  catalog: ApplicationWorkerCatalog
): WorkerManager on thread.main {
  const manager = new WorkerManager(catalog);
  let configured = manager;
  configured.configure();
  return manager;
}
