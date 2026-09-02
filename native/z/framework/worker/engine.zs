import {
  Receiver,
  Sender,
  SyncReceiver,
} from "std/channel";
import { Mutex } from "std/sync";
import { sleep } from "std/time";
import { WorkerLifecycle, WorkerModule } from "./types.zs";

// Private engine-neutral worker runtime. This module is intentionally absent
// from the public zapp package exports while the product-facing Worker API is
// pressure-tested by the first ZJS vertical slice.
struct WorkerCancellationState {
  cancellationRequested: boolean = false;
}

export readonly class WorkerMailbox<Command> {
  readonly sender: Sender<Command>;
  readonly cancellation: Mutex<WorkerCancellationState>;

  function requestCancellation(): boolean {
    const requested = this.cancellation.withLock((inout state): boolean => {
      if (state.cancellationRequested) return false;
      state.cancellationRequested = true;
      return true;
    });
    if (requested) this.sender.close();
    return requested;
  }

  function isCancellationRequested(): boolean {
    return this.cancellation.withLock(
      (in state): boolean => state.cancellationRequested
    );
  }
}

export struct WorkerInbox<Command> {
  commands: SyncReceiver<Command>;
  mailbox: WorkerMailbox<Command>;

  function receive(): Option<Command> {
    return this.commands.receive();
  }

  function isCancellationRequested(): boolean {
    return this.mailbox.isCancellationRequested();
  }
}

export function createWorkerMailbox<Command>(
  sender: Sender<Command>
): WorkerMailbox<Command> {
  return new WorkerMailbox<Command>({
    sender: move sender,
    cancellation: Mutex(WorkerCancellationState()),
  });
}

export function createWorkerInbox<Command>(
  receiver: Receiver<Command>,
  mailbox: WorkerMailbox<Command>
): WorkerInbox<Command> {
  return WorkerInbox<Command>({
    commands: receiver.sync(),
    mailbox,
  });
}

export trait WorkerEngine<Command> {
  function load(inout this, in module: WorkerModule): i32;
  function dispatch(inout this, in command: Command): i32;
  function hasPendingWork(): boolean;
  function nextWakeMilliseconds(): i64;
  function pump(inout this): i32;
  function isComplete(): boolean;
  function result(): i32;
}

export function runWorkerEngine<
  Command,
  Engine: WorkerEngine<Command>
>(
  inout engine: Engine,
  in module: WorkerModule,
  in inbox: WorkerInbox<Command>
): WorkerLifecycle {
  const loadStatus = engine.load(in module);
  if (loadStatus != 0) return WorkerLifecycle.failed(loadStatus);

  while (true) {
    if (inbox.isCancellationRequested()) {
      return WorkerLifecycle.cancelled(engine.result());
    }

    const pending = inbox.receive();
    match (pending) {
      some(command) => {
        const dispatchStatus = engine.dispatch(in command);
        if (dispatchStatus != 0) {
          return WorkerLifecycle.failed(dispatchStatus);
        }
      }
      none => {
        if (inbox.isCancellationRequested()) {
          return WorkerLifecycle.cancelled(engine.result());
        }
        return WorkerLifecycle.stopped(engine.result());
      }
    }

    // The first host tier runs one command to engine quiescence before taking
    // the next command. A future wait set can wake on either channel input or
    // the engine's next timer without polling.
    while (engine.hasPendingWork()) {
      const wait = engine.nextWakeMilliseconds();
      if (wait > 1) sleep(1);
      else if (wait > 0) sleep(u64(wait));

      const pumpStatus = engine.pump();
      if (pumpStatus != 0) return WorkerLifecycle.failed(pumpStatus);
    }
  }

  return WorkerLifecycle.failed(-1);
}
