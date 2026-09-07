import { thread } from "std/thread";
import console from "std/console";
import {
  ApplicationOpenURLRequestedEvent,
  ApplicationReopenRequestedEvent,
} from "../framework/application-activation.zs";
import {
  ApplicationEventSubscriptionError,
  ApplicationQuitRequestedEvent,
  createApplicationEvents,
} from "../framework/application-events.zs";

class Trace on thread.main {
  sequence: i32;
  count: i32;
}

function run(): i32 throws ApplicationEventSubscriptionError on thread.main {
  const events = createApplicationEvents();
  events.configureActivation(Array<String>("znotes"));
  const trace = new Trace({ sequence: 0, count: 0 });
  const recursiveEvents = events;
  const urlHandler: (in event: ApplicationOpenURLRequestedEvent) => void on thread.main =
    move (in event: ApplicationOpenURLRequestedEvent): void => {
      trace.sequence = trace.sequence * 10 + (event.url == "ZNOTES://one" ? 1 : 3);
      if (event.url == "ZNOTES://one") recursiveEvents.requestReopen();
    };
  const urls = try events.openURLRequested.subscribe(urlHandler);
  const reopen = try events.reopenRequested.subscribe(
    move (in event: ApplicationReopenRequestedEvent): void => {
      trace.sequence = trace.sequence * 10 + 2;
    }
  );
  if (events.requestOpenURL("https://outside.invalid")) return 1;
  if (events.requestOpenURL("znotes")) return 2;
  if (events.requestOpenURL("znotes://bad\nvalue")) return 3;
  if (events.requestOpenURL("znotes.evil://one")) return 21;
  let oversized = "znotes://one";
  while (oversized.byteLength <= 16384) {
    oversized = `${oversized}${oversized}`;
  }
  if (events.requestOpenURL(move oversized)) return 22;
  if (!events.requestOpenURL("ZNOTES://one")) return 4;
  if (!events.requestReopen()) return 5;
  if (!events.requestOpenURL("znotes://two")) return 6;
  if (trace.sequence != 0) return 7;
  events.startActivation();
  if (trace.sequence != 1232) return 8;
  urls.unsubscribe();
  reopen.unsubscribe();
  const late = try events.reopenRequested.subscribe(
    move (in event: ApplicationReopenRequestedEvent): void => { trace.count = trace.count + 1; }
  );
  if (trace.count != 0) return 9;
  events.requestReopen();
  if (trace.count != 1) return 10;
  events.finish();
  if (events.requestReopen() || events.requestOpenURL("znotes://one")) return 11;
  if (trace.count != 1) return 12;

  const queued = createApplicationEvents();
  const counted = try queued.reopenRequested.subscribe(
    move (in event: ApplicationReopenRequestedEvent): void => { trace.count = trace.count + 1; }
  );
  let index: i32 = 0;
  while (index < 64) {
    if (!queued.requestReopen()) return 13;
    index = index + 1;
  }
  if (queued.requestReopen()) return 14;
  queued.startActivation();
  if (trace.count != 65) return 15;
  queued.requestReopen(); // Capacity is reusable after draining the ring.
  if (trace.count != 66) return 16;
  queued.finish();

  const stop = createApplicationEvents();
  const stopEvents = stop;
  const finishHandler: (in event: ApplicationReopenRequestedEvent) => void on thread.main =
    move (in event: ApplicationReopenRequestedEvent): void => stopEvents.finish();
  const first = try stop.reopenRequested.subscribe(finishHandler);
  const second = try stop.reopenRequested.subscribe(
    move (in event: ApplicationReopenRequestedEvent): void => { trace.count = -100; }
  );
  stop.requestReopen();
  stop.requestReopen();
  stop.startActivation();
  if (trace.count != 66 || stop.requestReopen()) return 17;

  const cancelled = createApplicationEvents();
  cancelled.start(move (): void => {});
  const veto = try cancelled.quitRequested.subscribe(
    (in event: ApplicationQuitRequestedEvent): void => event.cancel()
  );
  cancelled.requestQuit();
  if (!cancelled.requestReopen()) return 18;
  veto.unsubscribe();
  cancelled.requestQuit();
  if (cancelled.requestReopen()) return 19;
  cancelled.finish();

  const abandoned = createApplicationEvents();
  const ignored = try abandoned.reopenRequested.subscribe(
    move (in event: ApplicationReopenRequestedEvent): void => { trace.count = -200; }
  );
  abandoned.requestReopen();
  abandoned.finish();
  abandoned.startActivation();
  if (trace.count != 66) return 20;
  console.log("activation FIFO, bounds, reentrancy, subscription, and shutdown checks passed");
  return 0;
}

function main(): i32 on thread.main {
  return match (attempt run()) {
    success(status) => status;
    failure(_) => 99;
  };
}
