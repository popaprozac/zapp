import { thread } from "std/thread";
import {
  Event,
  EventSubscription,
  EventSubscriptionError,
  WindowBlurredEvent,
  WindowCloseRequestedEvent,
  WindowClosedEvent,
  WindowEvent,
  WindowFocusedEvent,
  WindowNavigationRequestedEvent,
  WindowResizedEvent,
  WindowSize,
} from "./events.zs";

export type WindowEventSubscription = EventSubscription;
export type WindowEventSubscriptionError = EventSubscriptionError;

export readonly class WindowEvents on thread.main {
  readonly all: Event<WindowEvent>;
  readonly focused: Event<WindowFocusedEvent>;
  readonly blurred: Event<WindowBlurredEvent>;
  readonly resized: Event<WindowResizedEvent>;
  readonly navigationRequested: Event<WindowNavigationRequestedEvent>;
  readonly closeRequested: Event<WindowCloseRequestedEvent>;
  readonly closed: Event<WindowClosedEvent>;

  internal constructor() {
    this.all = new Event<WindowEvent>();
    this.focused = new Event<WindowFocusedEvent>();
    this.blurred = new Event<WindowBlurredEvent>();
    this.resized = new Event<WindowResizedEvent>();
    this.navigationRequested = new Event<WindowNavigationRequestedEvent>();
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
    let closeRequested = this.closeRequested;
    closeRequested.publish(in event);
    const aggregate = WindowEvent.closeRequested(event);
    let all = this.all;
    all.publish(in aggregate);
    return !event.wasCancelled();
  }

  internal function publishNavigationRequested(
    in windowId: String,
    in url: String,
    mainFrame: boolean,
    allowedByProfile: boolean
  ): boolean {
    const event = new WindowNavigationRequestedEvent(
      copy windowId,
      copy url,
      mainFrame,
      allowedByProfile
    );
    let navigationRequested = this.navigationRequested;
    navigationRequested.publish(in event);
    const aggregate = WindowEvent.navigationRequested(event);
    let all = this.all;
    all.publish(in aggregate);
    return !event.wasCancelled();
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
    let navigationRequested = this.navigationRequested;
    let closeRequested = this.closeRequested;
    let closed = this.closed;
    all.finish();
    focused.finish();
    blurred.finish();
    resized.finish();
    navigationRequested.finish();
    closeRequested.finish();
    closed.finish();
  }
}

internal function createWindowEvents(): WindowEvents on thread.main {
  return new WindowEvents();
}
