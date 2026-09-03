import { createNotesService } from "./notes-service.zs";
import { CreateNoteInput, NoteState } from "./notes-core.zs";
import { createHealthService } from "./health-service.zs";
import {
  IndexNotes,
  NoteIndexerCommand,
  NoteIndexerMessage,
  NoteIndexerProtocol,
} from "./note-indexer-protocol.zs";
import { Application } from "zapp";
import {
  WindowClosedEvent,
  WindowOptions,
} from "zapp/window";
import {
  ApplicationWorkerEvent,
  ApplicationWorkerEventSubscription,
  ApplicationWorkerMessage,
  ApplicationWorkerMessageSubscription,
  ApplicationWorkerProtocolError,
  ApplicationWorkerSendError,
  WorkerManager,
} from "zapp/worker";
import console from "std/console";
import { thread } from "std/thread";

function logApplicationWorkerEvent(
  in event: ApplicationWorkerEvent
): void on thread.main {
  match (in event) {
    started(value) => console.log(
      `worker ${value.workerId} started incarnation ${value.incarnation}`
    );
    restarting(value) => console.log(
      `worker ${value.workerId} restarting after incarnation ${value.incarnation} (retry ${value.retry}/${value.maxRetries})`
    );
    failed(value) => console.log(
      `worker ${value.workerId} failed after ${value.retries} retries: ${value.message}`
    );
    stopped(value) => console.log(`worker ${value.workerId} stopped`);
  }
}

function pingApplicationWorker(
  in workers: WorkerManager,
  in workerId: String
): void on thread.main {
  const retained = workers.getRaw(in workerId);
  match (retained) {
    some(activeWorker) => {
      const sent = attempt activeWorker.send(
        "manager-ping",
        "worker-manager-smoke"
      );
      match (sent) {
        success => {
          console.log("worker manager sent ping");
          const typed = workers.get(NoteIndexerProtocol());
          match (typed) {
            some(worker) => {
              const indexed: Result<void, ApplicationWorkerSendError> =
                attempt worker.send(
                NoteIndexerCommand.indexNotes(IndexNotes({
                  requestId: "native-smoke",
                }))
                );
              match (indexed) {
                success => console.log("worker manager requested note index");
                failure(_) => console.log("worker manager typed index failed");
              }
            }
            none => console.log("typed note indexer handle is unavailable");
          }
        }
        failure(error) => console.log(
          `worker manager send failed: ${error.message}`
        );
      }
    }
    none => console.log("worker manager handle expired");
  }
}

function observeApplicationWorker(
  in workers: WorkerManager,
  in workerId: String,
  sendOnStart: boolean
): Option<ApplicationWorkerEventSubscription> on thread.main {
  const selected = workers.getRaw(in workerId);
  const worker = match (selected) {
    some(value) => value;
    none => return Option<ApplicationWorkerEventSubscription>.none;
  };
  const observedWorkers = workers;
  const subscribed = attempt worker.events.all.subscribe(
    move (in event: ApplicationWorkerEvent): void => {
      logApplicationWorkerEvent(in event);
      if (sendOnStart) {
        match (in event) {
          started(value) => pingApplicationWorker(
            in observedWorkers,
            in value.workerId
          );
          _ => {}
        }
      }
    }
  );
  return match (subscribed) {
    success(subscription) => Option.some(subscription);
    failure(error) => {
      console.log(`could not observe worker ${workerId}: ${error.message}`);
      select Option<ApplicationWorkerEventSubscription>.none;
    }
  };
}

function observeApplicationWorkerMessages(
  in workers: WorkerManager,
  in workerId: String
): Option<ApplicationWorkerMessageSubscription> on thread.main {
  const selected = workers.getRaw(in workerId);
  const worker = match (selected) {
    some(value) => value;
    none => return Option<ApplicationWorkerMessageSubscription>.none;
  };
  const subscribed = attempt worker.messages.subscribe(
    move (in message: ApplicationWorkerMessage): void => console.log(
      `worker message ${message.channel}: ${message.payload}`
    )
  );
  return match (subscribed) {
    success(subscription) => Option.some(subscription);
    failure(error) => {
      console.log(
        `could not observe worker ${workerId} messages: ${error.message}`
      );
      select Option<ApplicationWorkerMessageSubscription>.none;
    }
  };
}

function observeTypedNoteIndexerMessages(
  in workers: WorkerManager
): Option<ApplicationWorkerMessageSubscription> on thread.main {
  const selected = workers.get(NoteIndexerProtocol());
  const worker = match (selected) {
    some(value) => value;
    none => return Option<ApplicationWorkerMessageSubscription>.none;
  };
  const subscribed = attempt worker.messages.subscribe(
    move (
      in received: Result<NoteIndexerMessage, ApplicationWorkerProtocolError>
    ): void => {
      match (in received) {
        success(message) => {
          match (in message) {
            started(value) => console.log(
              `typed worker started index ${value.requestId}`
            );
            progress(value) => console.log(
              `typed worker progress ${value.requestId}: ${value.completed}/${value.total}`
            );
            complete(value) => console.log(
              `typed worker completed ${value.requestId}: ${value.total} notes`
            );
            failed(value) => console.log(
              `typed worker failed ${value.requestId}: ${value.message}`
            );
          }
        }
        failure(error) => console.log(
          `typed worker protocol error ${error.channel}: ${error.message}`
        );
      }
    }
  );
  return match (subscribed) {
    success(subscription) => Option.some(subscription);
    failure(error) => {
      console.log(`could not observe typed worker messages: ${error.message}`);
      select Option<ApplicationWorkerMessageSubscription>.none;
    }
  };
}

async function main(): i32 on thread.main {
  const app = new Application();
  const notesService = createNotesService();
  const seeded = attempt await notesService.create(CreateNoteInput({
    title: "Welcome to Z Notes",
    subtitle: "Indexed in a Zapp application worker",
    state: NoteState.active,
  }));
  match (seeded) {
    success(_) => {}
    failure(error) => {
      console.log(`could not seed notes: ${error.message}`);
      return 74;
    }
  }
  const notesRegistered = attempt app.services.register(
    "notes",
    move notesService
  );
  match (notesRegistered) {
    success => {}
    failure(error) => {
      console.log(`could not register ${error.service}: ${error.message}`);
      return 78;
    }
  }
  const healthRegistered = attempt app.services.register(
    "health",
    createHealthService()
  );
  match (healthRegistered) {
    success => {}
    failure(error) => {
      console.log(`could not register ${error.service}: ${error.message}`);
      return 79;
    }
  }
  const workers = app.workers;
  const noteIndexerSubscription = observeApplicationWorker(
    in workers,
    "noteIndexer",
    true
  );
  const noteIndexerMessageSubscription = observeApplicationWorkerMessages(
    in workers,
    "noteIndexer"
  );
  const typedNoteIndexerMessageSubscription = observeTypedNoteIndexerMessages(
    in workers
  );
  const restartWorkerSubscription = observeApplicationWorker(
    in workers,
    "restartProbe",
    false
  );
  const createdWindow = attempt app.windows.create(WindowOptions({
    title: "Z Notes",
    url: "/notes",
    inject: Array<String>("base"),
    width: 720,
    height: 460,
  }));
  const window = match (createdWindow) {
    success(value) => value;
    failure(error) => {
      console.log(`window ${error.id} failed: ${error.message}`);
      return 71;
    }
  };
  const closedSubscriptionResult = attempt window.events.closed.subscribe(
    move (in event: WindowClosedEvent): void => {
      console.log(`window ${event.windowId} closed`);
    }
  );
  const closedSubscription = match (closedSubscriptionResult) {
    success(subscription) => subscription;
    failure(error) => {
      console.log(`could not observe window close: ${error.message}`);
      return 73;
    }
  };
  const result = attempt await app.run();
  const exitStatus = match (result) {
    success(status) => status;
    failure(error) => {
      const failureStatus = match (error) {
        state(stateError) => {
          console.log(`application state error: ${stateError.message}`);
          select 75;
        }
        lifecycle(lifecycleError) => {
          match (lifecycleError.phase) {
            start => console.log(
              `service ${lifecycleError.service} failed during start: ${lifecycleError.message}`
            );
            stop => console.log(
              `service ${lifecycleError.service} failed during stop: ${lifecycleError.message}`
            );
          }
          select 70;
        }
        window(windowError) => {
          console.log(`window ${windowError.id} failed: ${windowError.message}`);
          select 71;
        }
        platform(platformError) => {
          console.log(
            `platform error ${platformError.code}: ${platformError.message}`
          );
          select 72;
        }
      };
      select failureStatus;
    }
  };
  const stopped = match (app.state()) {
    stopped => true;
    _ => false;
  };
  return stopped ? exitStatus : 76;
}
