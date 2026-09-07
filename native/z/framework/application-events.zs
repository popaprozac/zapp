import { thread } from "std/thread";
import {
  Event,
  EventSubscription,
  EventSubscriptionError,
} from "./events.zs";

export type ApplicationEventSubscription = EventSubscription;
export type ApplicationEventSubscriptionError = EventSubscriptionError;

internal type ApplicationQuitOperation = () => void on thread.main;
internal type ApplicationQuitObserver = (cancelled: boolean) => void on thread.main;

class ApplicationQuitDecision on thread.main {
  cancelled: boolean;
  active: boolean;

  internal constructor() {
    this.cancelled = false;
    this.active = true;
  }

  function cancel(inout this): void {
    if (this.active) this.cancelled = true;
  }

  function finish(inout this): boolean {
    this.active = false;
    return this.cancelled;
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

  internal function finish(): boolean {
    let decision = this.decision;
    return decision.finish();
  }
}

class ApplicationEventsState on thread.main {
  active: boolean;
  requestingQuit: boolean;
  quitOperation: Option<ApplicationQuitOperation>;
  quitObserver: Option<ApplicationQuitObserver>;

  internal constructor() {
    this.active = false;
    this.requestingQuit = false;
    this.quitOperation = Option<ApplicationQuitOperation>.none;
    this.quitObserver = Option<ApplicationQuitObserver>.none;
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

  // Platform-only observation after all trusted synchronous listeners finish.
  internal function observeQuit(observer: ApplicationQuitObserver): void {
    let state = this.state;
    state.quitObserver = Option.some(observer);
  }

  // One native decision for programmatic and OS requests alike.
  internal function approveQuit(): boolean {
    let state = this.state;
    if (!state.active) return true;
    if (state.requestingQuit) return false;

    state.requestingQuit = true;
    const event = new ApplicationQuitRequestedEvent();
    let quitRequested = this.quitRequested;
    quitRequested.publish(in event);
    const cancelled = event.finish() || !state.active;
    if (!cancelled) state.active = false;
    // Keep the reentrancy guard held while reporting the final decision.
    match (in state.quitObserver) {
      some(observer) => observer(cancelled);
      none => {}
    }
    state.requestingQuit = false;
    return !cancelled;
  }

  internal function finish(): void {
    let state = this.state;
    state.active = false;
    state.requestingQuit = false;
    state.quitOperation = Option.none;
    state.quitObserver = Option.none;
    let quitRequested = this.quitRequested;
    quitRequested.finish();
  }
}

internal function createApplicationEvents(): ApplicationEvents on thread.main {
  return new ApplicationEvents();
}
