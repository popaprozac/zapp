import { Map } from "std/collections";
import { thread } from "std/thread";

export struct WindowEventSubscriptionError {
  message: String;
}

internal class WindowCloseDecision on thread.main {
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

type WindowEventUnsubscribe = () => void on thread.main;

export class WindowEventSubscription on thread.main {
  internal readonly unsubscribeOperation: WindowEventUnsubscribe;
  internal active: boolean;

  internal constructor(unsubscribeOperation: WindowEventUnsubscribe) {
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
  ): WindowEventSubscription throws WindowEventSubscriptionError {
    if (!this.accepting) {
      throw WindowEventSubscriptionError({
        message: "cannot subscribe after the window event source has closed",
      });
    }

    const id = this.nextId;
    this.nextId = this.nextId + 1;
    this.handlers.set(id, handler);
    this.order.push(id);
    const owner = this;
    return new WindowEventSubscription(
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

export readonly class WindowEvents on thread.main {
  readonly all: Event<WindowEvent>;
  readonly focused: Event<WindowFocusedEvent>;
  readonly blurred: Event<WindowBlurredEvent>;
  readonly resized: Event<WindowResizedEvent>;
  readonly closeRequested: Event<WindowCloseRequestedEvent>;
  readonly closed: Event<WindowClosedEvent>;

  internal constructor() {
    this.all = new Event<WindowEvent>();
    this.focused = new Event<WindowFocusedEvent>();
    this.blurred = new Event<WindowBlurredEvent>();
    this.resized = new Event<WindowResizedEvent>();
    this.closeRequested = new Event<WindowCloseRequestedEvent>();
    this.closed = new Event<WindowClosedEvent>();
  }

  internal function publishFocused(in windowId: String): void {
    const event = WindowFocusedEvent({ windowId: copy windowId });
    let focused = this.focused;
    focused.publish(in event);
    const aggregate = WindowEvent.focused(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function publishBlurred(in windowId: String): void {
    const event = WindowBlurredEvent({ windowId: copy windowId });
    let blurred = this.blurred;
    blurred.publish(in event);
    const aggregate = WindowEvent.blurred(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function publishResized(
    in windowId: String,
    width: u32,
    height: u32
  ): void {
    const event = WindowResizedEvent({
      windowId: copy windowId,
      size: WindowSize({ width, height }),
    });
    let resized = this.resized;
    resized.publish(in event);
    const aggregate = WindowEvent.resized(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function publishCloseRequested(
    in windowId: String
  ): boolean {
    const event = new WindowCloseRequestedEvent(copy windowId);
    const decision = event.decision;
    let closeRequested = this.closeRequested;
    closeRequested.publish(in event);
    const aggregate = WindowEvent.closeRequested(event);
    let all = this.all;
    all.publish(in aggregate);
    return !decision.wasCancelled();
  }

  internal function publishClosed(in windowId: String): void {
    const event = WindowClosedEvent({ windowId: copy windowId });
    let closed = this.closed;
    closed.publish(in event);
    const aggregate = WindowEvent.closed(copy event);
    let all = this.all;
    all.publish(in aggregate);
    this.finish();
  }

  internal function finish(): void {
    let all = this.all;
    let focused = this.focused;
    let blurred = this.blurred;
    let resized = this.resized;
    let closeRequested = this.closeRequested;
    let closed = this.closed;
    all.finish();
    focused.finish();
    blurred.finish();
    resized.finish();
    closeRequested.finish();
    closed.finish();
  }
}

internal function createWindowEvents(): WindowEvents on thread.main {
  return new WindowEvents();
}
