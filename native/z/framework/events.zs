import { Map } from "std/collections";
import { thread } from "std/thread";

export struct EventSubscriptionError {
  message: String;
}

export readonly struct ApplicationWorkerStartedEvent {
  workerId: String;
  incarnation: u64;
}

export readonly struct ApplicationWorkerRestartingEvent {
  workerId: String;
  incarnation: u64;
  retry: u64;
  maxRetries: u64;
  withinMilliseconds: u64;
  message: String;
}

export readonly struct ApplicationWorkerFailedEvent {
  workerId: String;
  incarnation: u64;
  retries: u64;
  message: String;
}

export readonly struct ApplicationWorkerStoppedEvent {
  workerId: String;
}

export enum ApplicationWorkerEvent {
  started ApplicationWorkerStartedEvent,
  restarting ApplicationWorkerRestartingEvent,
  failed ApplicationWorkerFailedEvent,
  stopped ApplicationWorkerStoppedEvent,
}

class WindowCloseDecision on thread.main {
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

export readonly struct WindowFocusedEvent {
  windowId: String;
}

export readonly struct WindowBlurredEvent {
  windowId: String;
}

export readonly struct WindowSize {
  width: u32;
  height: u32;
}

export readonly struct WindowResizedEvent {
  windowId: String;
  size: WindowSize;
}

export readonly struct WindowClosedEvent {
  windowId: String;
}

export readonly class WindowCloseRequestedEvent on thread.main {
  readonly windowId: String;
  internal readonly decision: WindowCloseDecision;

  internal constructor(windowId: String) {
    this.windowId = move windowId;
    this.decision = new WindowCloseDecision();
  }

  function cancel(): void {
    let decision = this.decision;
    decision.cancel();
  }

  internal function wasCancelled(): boolean {
    return this.decision.wasCancelled();
  }
}

export enum WindowEvent {
  focused WindowFocusedEvent,
  blurred WindowBlurredEvent,
  resized WindowResizedEvent,
  closeRequested WindowCloseRequestedEvent,
  closed WindowClosedEvent,
}

type EventUnsubscribe = () => void on thread.main;

// Subscription owns one handler registration. Explicit unsubscribe is useful
// for early teardown; deinit makes lexical subscription lifetimes safe by
// default.
export class EventSubscription on thread.main {
  internal readonly unsubscribeOperation: EventUnsubscribe;
  internal active: boolean;

  internal constructor(unsubscribeOperation: EventUnsubscribe) {
    this.unsubscribeOperation = unsubscribeOperation;
    this.active = true;
  }

  function unsubscribe(inout this): void {
    if (this.active) {
      this.active = false;
      this.unsubscribeOperation();
    }
  }

  deinit {
    if (this.active) this.unsubscribeOperation();
  }
}

// Main-executor event source shared by windows, application workers, and
// future managers. Publishing is framework-only; consumers receive scoped,
// independently removable subscriptions.
export class Event<T> on thread.main {
  internal accepting: boolean;
  internal nextId: u64;
  internal handlers: Map<u64, (in value: T) => void on thread.main>;
  internal order: Array<u64>;

  internal constructor() {
    this.accepting = true;
    this.nextId = 1;
    this.handlers = Map<u64, (in value: T) => void on thread.main>();
    this.order = Array<u64>();
  }

  internal function remove(inout this, id: u64): void {
    this.handlers.delete(id);
  }

  internal function handler(
    id: u64
  ): Option<(in value: T) => void on thread.main> {
    const found = this.handlers.get(id);
    return match (in found) {
      some(handler) => Option.some(handler);
      none => Option.none;
    };
  }

  function subscribe(
    inout this,
    handler: (in value: T) => void on thread.main
  ): EventSubscription throws EventSubscriptionError {
    if (!this.accepting) {
      throw EventSubscriptionError({
        message: "cannot subscribe after the event source has closed",
      });
    }

    const id = this.nextId;
    this.nextId = this.nextId + 1;
    this.handlers.set(id, handler);
    this.order.push(id);
    const owner = this;
    return new EventSubscription(
      move (): void => owner.remove(id)
    );
  }

  internal function publish(inout this, in value: T): void {
    const limit = this.order.length;
    let index: usize = 0;
    while (index < limit) {
      const handlerId: u64 = this.order[index];
      const selected: Option<(
        in value: T
      ) => void on thread.main> = this.handler(handlerId);
      match (selected) {
        some(handler) => handler(in value);
        none => {}
      }
      index = index + 1;
    }
  }

  internal function finish(inout this): void {
    if (this.accepting) {
      this.accepting = false;
      this.handlers = Map<u64, (in value: T) => void on thread.main>();
      this.order = Array<u64>();
    }
  }
}
