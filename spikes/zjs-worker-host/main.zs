import console from "std/console";
import { Channel } from "std/channel";
import { thread } from "std/thread";
import { delay } from "std/time";
import native from "zapp_worker_zjs.h";
import {
  WorkerCommand,
  WorkerMessage,
} from "./worker-engine.zs";
import {
  WorkerEngine,
  WorkerInbox,
  WorkerLifecycle,
  WorkerModule,
  createWorkerInbox,
  createWorkerMailbox,
  runWorkerEngine,
} from "../../native/z/framework/worker/engine.zs";

const workerModule: cstring = "export function onCommand(left, right) { setTimeout(() => { __zappServiceAdd(left, right); }, 5); }";

// This is the checked Z implementation reached directly from the embedded JS
// engine. The C ABI is an internal adapter seam, not a public application API.
export c function zapp_worker_probe_add(left: i32, right: i32): i32 {
  return left + right;
}

struct ZjsWorkerEngine implements WorkerEngine<WorkerCommand> {
  handle: native.ZappZjsEngine;

  function load(
    inout this,
    in module: WorkerModule
  ): i32 {
    return native.zapp_zjs_engine_evaluate_module(
      this.handle,
      module.source
    );
  }

  function hasPendingWork(): boolean {
    return native.zapp_zjs_engine_has_pending_work(this.handle) != 0;
  }

  function dispatch(inout this, in command: WorkerCommand): i32 {
    return match (in command) {
      message(value) => native.zapp_zjs_engine_dispatch(
        this.handle,
        value.left,
        value.right
      );
    };
  }

  function nextWakeMilliseconds(): i64 {
    return native.zapp_zjs_engine_next_wake_milliseconds(this.handle);
  }

  function pump(inout this): i32 {
    return native.zapp_zjs_engine_pump(this.handle);
  }

  function isComplete(): boolean {
    return native.zapp_zjs_engine_is_complete(this.handle) != 0;
  }

  function result(): i32 {
    return native.zapp_zjs_engine_result(this.handle);
  }
}

function executeWorkerModule(
  in inbox: WorkerInbox<WorkerCommand>
): WorkerLifecycle {
  const engine = native.zapp_zjs_engine_create();
  if (engine == null) return WorkerLifecycle.failed(100);

  let adapter = ZjsWorkerEngine({ handle: move engine });
  const module = WorkerModule({ source: workerModule });
  return runWorkerEngine(inout adapter, in module, in inbox);
}

async function main(): i32 {
  const { sender, receiver } = Channel<WorkerCommand>.bounded(1);
  const mailbox = createWorkerMailbox<WorkerCommand>(move sender);
  const inbox = createWorkerInbox<WorkerCommand>(move receiver, mailbox);
  const worker = thread.spawn(
    move (): WorkerLifecycle => executeWorkerModule(in inbox)
  );
  await delay(1);
  console.log("ZJS worker channel ready");
  const posted = attempt await mailbox.post(WorkerCommand.message(WorkerMessage({
    left: 20,
    right: 22,
  })));
  match (posted) {
    success => {}
    failure(_) => return 1;
  }
  console.log("ZJS worker command accepted");

  const result = await worker;
  const value = match (result) {
    stopped(observed) => observed;
    cancelled(_) => -2;
    failed(code) => -code;
  };
  if (value != 42) return 2;

  const {
    sender: cancellationSender,
    receiver: cancellationReceiver,
  } = Channel<WorkerCommand>.bounded(1);
  const cancellation = createWorkerMailbox<WorkerCommand>(
    move cancellationSender
  );
  const cancellationInbox = createWorkerInbox<WorkerCommand>(
    move cancellationReceiver,
    cancellation
  );
  const cancelledWorker = thread.spawn(
    move (): WorkerLifecycle => executeWorkerModule(in cancellationInbox)
  );
  await delay(1);
  if (!cancellation.requestCancellation()) return 3;
  const cancelledResult = await cancelledWorker;
  const cancelledCleanly = match (cancelledResult) {
    cancelled(_) => true;
    _ => false;
  };
  if (!cancelledCleanly) return 4;

  console.log(`ZJS worker processed a Z command and returned ${value}`);
  console.log("ZJS worker observed cancellation and joined cleanly");
  return 0;
}
