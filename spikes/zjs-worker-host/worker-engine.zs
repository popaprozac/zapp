import {
  ChannelClosed,
  Receiver,
  Sender,
  SyncReceiver,
} from "std/channel";
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

struct WorkerCancellationState {
  cancellationRequested: boolean = false;
}

export readonly class WorkerMailbox {
  readonly sender: Sender<WorkerCommand>;
  readonly cancellation: Mutex<WorkerCancellationState>;

  async function post(
    command: WorkerCommand
  ): void throws ChannelClosed<WorkerCommand> {
    try await this.sender.send(command);
  }

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

export struct WorkerInbox {
  commands: SyncReceiver<WorkerCommand>;
  mailbox: WorkerMailbox;

  function receive(): Option<WorkerCommand> {
    return this.commands.receive();
  }

  function isCancellationRequested(): boolean {
    return this.mailbox.isCancellationRequested();
  }
}

export function createWorkerMailbox(
  sender: Sender<WorkerCommand>
): WorkerMailbox {
  return new WorkerMailbox({
    sender: move sender,
    cancellation: Mutex(WorkerCancellationState()),
  });
}

export function createWorkerInbox(
  receiver: Receiver<WorkerCommand>,
  mailbox: WorkerMailbox
): WorkerInbox {
  return WorkerInbox({
    commands: receiver.sync(),
    mailbox,
  });
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
  in inbox: WorkerInbox
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
    // the next command. A future wait-set can wake on either channel input or
    // the engine's next timer without polling.
    while (engine.hasPendingWork()) {
      const wait = engine.nextWakeMilliseconds();
      if (wait > 1) sleep(1);
      else if (wait > 0) sleep(u64(wait));

      const pumpStatus = engine.pump();
      if (pumpStatus != 0) return WorkerLifecycle.failed(pumpStatus);
      if (engine.isComplete()) {
        return WorkerLifecycle.stopped(engine.result());
      }
    }

    if (engine.isComplete()) {
      return WorkerLifecycle.stopped(engine.result());
    }
  }

  return WorkerLifecycle.failed(-1);
}
