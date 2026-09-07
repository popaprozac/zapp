import { Set } from "std/collections";
import { thread } from "std/thread";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import { ApplicationPermissions } from "../framework/application-permissions.zs";
import { BridgeMessage, BridgeMessageKind } from "../framework/bridge.zs";
import {
  ApplicationEventSubscriptionError,
  ApplicationQuitOperation,
  ApplicationQuitRequestedEvent,
  createApplicationEvents,
} from "../framework/application-events.zs";
import { routeApplicationBridgeMessage } from "../framework/application-bridge.zs";

class Observation on thread.main {
  quits: i32;
  decisions: i32;
  cancelled: boolean;
  outOfOrder: boolean;
  retained: Option<ApplicationQuitRequestedEvent>;
}

function selection(allow: boolean): CapabilitySelection {
  let names = Array<String>();
  let permissions = Set<String>();
  if (allow) permissions.add("application:quit");
  let services = Set<String>();
  let workers = Set<String>();
  return new CapabilitySelection({
    names: names.freeze(), permissions: permissions.freeze(),
    serviceMethods: services.freeze(), workerIds: workers.freeze(),
  });
}

function run(): i32 throws ApplicationEventSubscriptionError on thread.main {
  const events = createApplicationEvents();
  const observed = new Observation({
    quits: 0, decisions: 0, cancelled: false, outOfOrder: false,
    retained: Option.none,
  });
  const quitState = observed;
  events.start(move (): void => { quitState.quits = quitState.quits + 1; });
  const observerState = observed;
  const recursiveEvents = events;
  events.observeQuit(move (cancelled: boolean): void => {
    observerState.decisions = observerState.decisions + 1;
    observerState.cancelled = cancelled;
    if (observerState.quits != 0) observerState.outOfOrder = true;
    // Reporting a decision cannot recursively publish another quit request.
    recursiveEvents.requestQuit();
  });
  const requestEvents = events;
  const request: ApplicationQuitOperation = move (): void => requestEvents.requestQuit();
  const denied = ApplicationPermissions();
  const allowed = ApplicationPermissions({ applicationQuit: true });
  const capable = selection(true);
  const incapable = selection(false);
  const message = BridgeMessage({
    kind: BridgeMessageKind.action, id: 0,
    method: "__zapp:application:quit", arguments: "{\"force\":true}",
  });
  match (routeApplicationBridgeMessage(in message, in denied, capable, request)) {
    response(value) => if (value.ok) return 1;
    _ => return 2;
  }
  match (routeApplicationBridgeMessage(in message, in allowed, incapable, request)) {
    response(value) => if (value.ok) return 3;
    _ => return 4;
  }
  if (observed.decisions != 0 || observed.quits != 0) return 5;

  const requestState = observed;
  const veto = try events.quitRequested.subscribe(
    move (in event: ApplicationQuitRequestedEvent): void => {
      requestState.retained = Option.some(event);
      event.cancel();
    }
  );
  match (routeApplicationBridgeMessage(in message, in allowed, capable, request)) {
    handled => {}
    _ => return 6;
  }
  if (!observed.cancelled || observed.decisions != 1 || observed.quits != 0) return 7;
  veto.unsubscribe();
  const retainedState = observed;
  const retention = try events.quitRequested.subscribe(
    move (in event: ApplicationQuitRequestedEvent): void => {
      retainedState.retained = Option.some(event);
    }
  );
  const emitted = BridgeMessage({
    kind: BridgeMessageKind.emit, id: 0,
    method: "__zapp:application:quit", arguments: "{}",
  });
  match (routeApplicationBridgeMessage(in emitted, in allowed, capable, request)) {
    handled => {}
    _ => return 8;
  }
  if (observed.cancelled || observed.decisions != 2 || observed.quits != 1) return 9;
  if (observed.outOfOrder) return 10;
  match (in observed.retained) {
    some(event) => {
      event.cancel(); // Completed requests cannot be retroactively cancelled.
      if (event.wasCancelled()) return 11;
    }
    none => return 12;
  }
  events.requestQuit();
  if (observed.quits != 1 || observed.decisions != 2) return 13;
  events.finish();
  retention.unsubscribe();
  const wrongKind = BridgeMessage({
    kind: BridgeMessageKind.invoke, id: 42,
    method: "__zapp:application:quit", arguments: "{}",
  });
  match (routeApplicationBridgeMessage(in wrongKind, in allowed, capable, request)) {
    response(value) => if (value.ok || value.id != 42) return 14;
    _ => return 15;
  }
  return 0;
}

function main(): i32 on thread.main {
  return match (attempt run()) {
    success(status) => status;
    failure(_) => 16;
  };
}
