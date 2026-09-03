import { thread } from "std/thread";
import {
  Event,
  EventSubscription,
  EventSubscriptionError,
} from "./events.zs";

export type ApplicationEventSubscription = EventSubscription;
export type ApplicationEventSubscriptionError = EventSubscriptionError;

internal type ApplicationQuitOperation = () => void on thread.main;

class ApplicationQuitDecision on thread.main {
  cancelled: boolean;

  internal constructor() {
    this.cancelled = false;
  }

  function cancel(inout this): void {
    this.cancelled = true;
  }

  function wasCancelled(): boolean {
    return this.cancelled;
  }
}

export readonly class ApplicationQuitRequestedEvent on thread.main {
  internal readonly decision: ApplicationQuitDecision;

  internal constructor() {
    this.decision = new ApplicationQuitDecision();
  }

  function cancel(): void {
    let decision = this.decision;
    decision.cancel();
  }

  internal function wasCancelled(): boolean {
    return this.decision.wasCancelled();
  }
}

class ApplicationEventsState on thread.main {
  active: boolean;
  requestingQuit: boolean;
  quitOperation: Option<ApplicationQuitOperation>;

  internal constructor() {
    this.active = false;
    this.requestingQuit = false;
    this.quitOperation = Option<ApplicationQuitOperation>.none;
  }
}

export readonly class ApplicationEvents on thread.main {
  readonly quitRequested: Event<ApplicationQuitRequestedEvent>;
  internal readonly state: ApplicationEventsState;

  internal constructor() {
    this.quitRequested = new Event<ApplicationQuitRequestedEvent>();
    this.state = new ApplicationEventsState();
  }

  internal function start(
    quitOperation: ApplicationQuitOperation
  ): void {
    let state = this.state;
    state.quitOperation = Option.some(quitOperation);
    state.active = true;
  }

  internal function requestQuit(): void {
    let state = this.state;
    if (!state.active || !this.approveQuit()) return;
    match (in state.quitOperation) {
      some(operation) => operation();
      none => {}
    }
  }

  // Native lifecycle requests (Cmd-Q, Dock Quit, and system termination)
  // ask the same Z event source for a decision without recursively invoking
  // the programmatic quit operation.
  internal function approveQuit(): boolean {
    let state = this.state;
    if (!state.active) return true;
    if (state.requestingQuit) return false;

    state.requestingQuit = true;
    const event = new ApplicationQuitRequestedEvent();
    let quitRequested = this.quitRequested;
    quitRequested.publish(in event);
    state.requestingQuit = false;

    if (event.wasCancelled()) return false;
    state.active = false;
    return true;
  }

  internal function finish(): void {
    let state = this.state;
    state.active = false;
    state.requestingQuit = false;
    let quitRequested = this.quitRequested;
    quitRequested.finish();
  }
}

internal function createApplicationEvents(): ApplicationEvents on thread.main {
  return new ApplicationEvents();
}
