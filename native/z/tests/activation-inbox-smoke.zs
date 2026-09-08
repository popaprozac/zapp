import console from "std/console";
import { thread } from "std/thread";
import {
  ActivationInbox,
} from "../framework/activation-inbox.zs";
import {
  ApplicationEventSubscriptionError,
  ApplicationQuitRequestedEvent,
  createApplicationEvents,
} from "../framework/application-events.zs";
import { ApplicationSecondInstanceLaunchedEvent } from "../framework/application-launch.zs";

class Trace on thread.main {
  delivered: i32;
  sequence: String;
}

function submit(in inbox: ActivationInbox, in source: String, count: i32): i32 {
  let accepted = 0;
  let index = 0;
  while (index < count) {
    if (inbox.admitPayload(in source)) accepted = accepted + 1;
    index = index + 1;
  }
  return accepted;
}

async function exercise(): i32 throws ApplicationEventSubscriptionError on thread.main {
  const events = createApplicationEvents();
  const inbox = events.activationInbox();
  const trace = new Trace({ delivered: 0, sequence: "" });
  const nestedInbox = inbox;
  const listener = try events.secondInstanceLaunched.subscribe(
    move (in event: ApplicationSecondInstanceLaunchedEvent): void => {
      trace.delivered = trace.delivered + 1;
      if (event.arguments.length > 0) {
        trace.sequence = `${trace.sequence}${event.arguments[0]}`;
        // Listener reentry must not run under the inbox lock.
        if (event.arguments[0] == "a") {
          nestedInbox.admitPayload(
            '{"version":1,"launch":{"arguments":["c"],"workingDirectory":null}}');
        }
      }
    }
  );
  const payload = '{"version":1,"launch":{"arguments":[],"workingDirectory":null}}';
  if (inbox.admitPayload("malformed")) return 1;
  const firstPayload = copy payload;
  const secondPayload = copy payload;
  const thirdPayload = copy payload;
  const first = thread.spawn(move (): i32 => submit(in inbox, in firstPayload, 100));
  const second = thread.spawn(move (): i32 => submit(in inbox, in secondPayload, 100));
  const third = thread.spawn(move (): i32 => submit(in inbox, in thirdPayload, 100));
  const a = await first;
  const b = await second;
  const c = await third;
  if (a + b + c != 64) return 2;
  if (trace.delivered != 0) return 3; // Admission is not event execution.
  if (events.requestReopen()) return 4; // One budget, not a second native queue.
  events.startActivation();
  if (trace.delivered != 64) return 5;

  if (!inbox.admitPayload(
    '{"version":1,"launch":{"arguments":["a"],"workingDirectory":null}}')) return 6;
  if (!inbox.admitPayload(
    '{"version":1,"launch":{"arguments":["b"],"workingDirectory":null}}')) return 7;
  if (trace.delivered != 64) return 8;
  events.drainActivation();
  if (trace.sequence != "abc" || trace.delivered != 67) return 9;

  events.start(move (): void => {});
  const veto = try events.quitRequested.subscribe(
    (in event: ApplicationQuitRequestedEvent): void => event.cancel()
  );
  events.requestQuit();
  if (!inbox.admitPayload(in payload)) return 10;
  events.drainActivation();
  if (trace.delivered != 68) return 11;
  veto.unsubscribe();
  events.requestQuit();
  // A producer may still retain its handle, but it cannot reopen a closed inbox.
  const afterClose = thread.spawn(move (): i32 => submit(in inbox, in payload, 100));
  if (await afterClose != 0) return 12;
  events.drainActivation();
  if (trace.delivered != 68) return 13;
  events.finish();
  return 0;
}

async function main(): i32 on thread.main {
  const result = attempt await exercise();
  return match (result) {
    success(status) => {
      if (status == 0) console.log("threaded activation admission, shared capacity, FIFO, and shutdown passed");
      select status;
    }
    failure(_) => 99;
  };
}
