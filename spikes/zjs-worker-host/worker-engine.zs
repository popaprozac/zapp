import { Mutex } from "std/sync";
import { sleep } from "std/time";

export struct WorkerModule {
  source: cstring;
}

export struct WorkerMessage {
  left: i32;
  right: i32;
}

export enum WorkerCommand {
  message WorkerMessage,
}

export enum WorkerLifecycle {
  stopped i32,
  cancelled i32,
  failed i32,
}

struct WorkerMailboxState {
  pending: Option<WorkerCommand> = Option<WorkerCommand>.none;
  cancellationRequested: boolean = false;
}

export readonly class WorkerMailbox {
  readonly state: Mutex<WorkerMailboxState>;

  function post(command: WorkerCommand): boolean {
    return this.state.withLock((inout state): boolean => {
      const accepted = match (in state.pending) {
        some(_) => false;
        none => true;
      };
      if (!accepted) return false;
      state.pending = Option.some(command);
      return true;
    });
  }

  function requestCancellation(): boolean {
    return this.state.withLock((inout state): boolean => {
      if (state.cancellationRequested) return false;
      state.cancellationRequested = true;
      return true;
    });
  }

  function isCancellationRequested(): boolean {
    return this.state.withLock(
      (in state): boolean => state.cancellationRequested
    );
  }

  function take(): Option<WorkerCommand> {
    return this.state.withLock((inout state): Option<WorkerCommand> => {
      const pending = state.pending;
      state.pending = Option<WorkerCommand>.none;
      return pending;
    });
  }
}

export function createWorkerMailbox(): WorkerMailbox {
  return new WorkerMailbox({ state: Mutex(WorkerMailboxState()) });
}

export trait WorkerEngine {
  function load(inout this, in module: WorkerModule): i32;
  function dispatch(inout this, in command: WorkerCommand): i32;
  function hasPendingWork(): boolean;
  function nextWakeMilliseconds(): i64;
  function pump(inout this): i32;
  function isComplete(): boolean;
  function result(): i32;
}

export function runWorkerEngine<T: WorkerEngine>(
  inout engine: T,
  in module: WorkerModule,
  in mailbox: WorkerMailbox
): WorkerLifecycle {
  const loadStatus = engine.load(in module);
  if (loadStatus != 0) return WorkerLifecycle.failed(loadStatus);

  while (true) {
    if (mailbox.isCancellationRequested()) {
      return WorkerLifecycle.cancelled(engine.result());
    }

    const pending = mailbox.take();
    match (pending) {
      some(command) => {
        const dispatchStatus = engine.dispatch(in command);
        if (dispatchStatus != 0) {
          return WorkerLifecycle.failed(dispatchStatus);
        }
      }
      none => {}
    }

    if (engine.hasPendingWork()) {
      const wait = engine.nextWakeMilliseconds();
      if (wait > 1) sleep(1);
      else if (wait > 0) sleep(u64(wait));

      const pumpStatus = engine.pump();
      if (pumpStatus != 0) return WorkerLifecycle.failed(pumpStatus);
    } else {
      sleep(1);
    }

    if (engine.isComplete()) {
      return WorkerLifecycle.stopped(engine.result());
    }
  }

  return WorkerLifecycle.failed(-1);
}
