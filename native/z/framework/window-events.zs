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
  WindowMinimizedEvent,
  WindowUnminimizedEvent,
  WindowMaximizedEvent,
  WindowUnmaximizedEvent,
  WindowFullscreenEnteredEvent,
  WindowFullscreenExitedEvent,
  WindowNavigationRequestedEvent,
  WindowResizedEvent,
  WindowSize,
  WindowDropPosition,
  WindowFileDropRequestedEvent,
  WindowFilesDroppedEvent,
  WindowFileDragEnteredEvent,
  WindowFileDragMovedEvent,
  WindowFileDragEndedEvent,
} from "./events.zs";

export type WindowEventSubscription = EventSubscription;
export type WindowEventSubscriptionError = EventSubscriptionError;

export readonly class WindowEvents on thread.main {
  readonly all: Event<WindowEvent>;
  readonly focused: Event<WindowFocusedEvent>;
  readonly blurred: Event<WindowBlurredEvent>;
  readonly minimized: Event<WindowMinimizedEvent>;
  readonly unminimized: Event<WindowUnminimizedEvent>;
  readonly maximized: Event<WindowMaximizedEvent>;
  readonly unmaximized: Event<WindowUnmaximizedEvent>;
  readonly fullscreenEntered: Event<WindowFullscreenEnteredEvent>;
  readonly fullscreenExited: Event<WindowFullscreenExitedEvent>;
  readonly resized: Event<WindowResizedEvent>;
  readonly navigationRequested: Event<WindowNavigationRequestedEvent>;
  readonly closeRequested: Event<WindowCloseRequestedEvent>;
  readonly closed: Event<WindowClosedEvent>;
  readonly fileDropRequested: Event<WindowFileDropRequestedEvent>;
  readonly filesDropped: Event<WindowFilesDroppedEvent>;
  readonly fileDragEntered: Event<WindowFileDragEnteredEvent>;
  readonly fileDragMoved: Event<WindowFileDragMovedEvent>;
  readonly fileDragEnded: Event<WindowFileDragEndedEvent>;

  internal constructor() {
    this.all = new Event<WindowEvent>();
    this.focused = new Event<WindowFocusedEvent>();
    this.blurred = new Event<WindowBlurredEvent>();
    this.minimized = new Event<WindowMinimizedEvent>();
    this.unminimized = new Event<WindowUnminimizedEvent>();
    this.maximized = new Event<WindowMaximizedEvent>();
    this.unmaximized = new Event<WindowUnmaximizedEvent>();
    this.fullscreenEntered = new Event<WindowFullscreenEnteredEvent>();
    this.fullscreenExited = new Event<WindowFullscreenExitedEvent>();
    this.resized = new Event<WindowResizedEvent>();
    this.navigationRequested = new Event<WindowNavigationRequestedEvent>();
    this.closeRequested = new Event<WindowCloseRequestedEvent>();
    this.closed = new Event<WindowClosedEvent>();
    this.fileDropRequested = new Event<WindowFileDropRequestedEvent>();
    this.filesDropped = new Event<WindowFilesDroppedEvent>();
    this.fileDragEntered = new Event<WindowFileDragEnteredEvent>();
    this.fileDragMoved = new Event<WindowFileDragMovedEvent>();
    this.fileDragEnded = new Event<WindowFileDragEndedEvent>();
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

  internal function publishMinimized(in windowId: String): void {
    const event = WindowMinimizedEvent({ windowId: copy windowId });
    let minimized = this.minimized;
    minimized.publish(in event);
    const aggregate = WindowEvent.minimized(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function publishUnminimized(in windowId: String): void {
    const event = WindowUnminimizedEvent({ windowId: copy windowId });
    let unminimized = this.unminimized;
    unminimized.publish(in event);
    const aggregate = WindowEvent.unminimized(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function publishMaximized(in windowId: String): void {
    const event = WindowMaximizedEvent({ windowId: copy windowId });
    let source = this.maximized;
    source.publish(in event);
    const aggregate = WindowEvent.maximized(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function publishUnmaximized(in windowId: String): void {
    const event = WindowUnmaximizedEvent({ windowId: copy windowId });
    let source = this.unmaximized;
    source.publish(in event);
    const aggregate = WindowEvent.unmaximized(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function publishFullscreenEntered(in windowId: String): void {
    const event = WindowFullscreenEnteredEvent({ windowId: copy windowId });
    let source = this.fullscreenEntered;
    source.publish(in event);
    const aggregate = WindowEvent.fullscreenEntered(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function publishFullscreenExited(in windowId: String): void {
    const event = WindowFullscreenExitedEvent({ windowId: copy windowId });
    let source = this.fullscreenExited;
    source.publish(in event);
    const aggregate = WindowEvent.fullscreenExited(copy event);
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
    // The borrowed publication has finished; transfer our payload to the
    // aggregate stream. Subscribers retain snapshots with their own `copy`.
    const aggregate = WindowEvent.resized(move event);
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

  internal function publishFileDropRequested(in windowId: String, in paths: Array<String>,
    position: WindowDropPosition): boolean {
    const event = new WindowFileDropRequestedEvent(copy windowId, copy paths, position);
    let requested = this.fileDropRequested;
    requested.publish(in event);
    const aggregate = WindowEvent.fileDropRequested(event);
    let all = this.all;
    all.publish(in aggregate);
    return !event.wasCancelled();
  }

  internal function publishFilesDropped(in event: WindowFilesDroppedEvent): void {
    let dropped = this.filesDropped;
    dropped.publish(in event);
    const aggregate = WindowEvent.filesDropped(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function publishFileDragEntered(in event: WindowFileDragEnteredEvent): void {
    let source = this.fileDragEntered;
    source.publish(in event);
    const aggregate = WindowEvent.fileDragEntered(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function publishFileDragMoved(in event: WindowFileDragMovedEvent): void {
    let source = this.fileDragMoved;
    source.publish(in event);
    const aggregate = WindowEvent.fileDragMoved(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function publishFileDragEnded(in event: WindowFileDragEndedEvent): void {
    let source = this.fileDragEnded;
    source.publish(in event);
    const aggregate = WindowEvent.fileDragEnded(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function finish(): void {
    let entered = this.fileDragEntered;
    let moved = this.fileDragMoved;
    let ended = this.fileDragEnded;
    entered.finish();
    moved.finish();
    ended.finish();
    let requested = this.fileDropRequested;
    let dropped = this.filesDropped;
    requested.finish();
    dropped.finish();
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
    let minimized = this.minimized;
    let unminimized = this.unminimized;
    minimized.finish();
    unminimized.finish();
    let maximized = this.maximized;
    maximized.finish();
    let unmaximized = this.unmaximized;
    unmaximized.finish();
    let fullscreenEntered = this.fullscreenEntered;
    fullscreenEntered.finish();
    let fullscreenExited = this.fullscreenExited;
    fullscreenExited.finish();
    resized.finish();
    navigationRequested.finish();
    closeRequested.finish();
    closed.finish();
  }
}

internal function createWindowEvents(): WindowEvents on thread.main {
  return new WindowEvents();
}
