import { thread } from "std/thread";
import {
  ApplicationWorkerEvent,
  ApplicationWorkerFailedEvent,
  ApplicationWorkerRestartingEvent,
  ApplicationWorkerStartedEvent,
  ApplicationWorkerStoppedEvent,
  Event,
  EventSubscription,
  EventSubscriptionError,
} from "../events.zs";

export type ApplicationWorkerEventSubscription = EventSubscription;
export type ApplicationWorkerEventSubscriptionError = EventSubscriptionError;

export readonly class ApplicationWorkerEvents on thread.main {
  readonly all: Event<ApplicationWorkerEvent>;
  readonly started: Event<ApplicationWorkerStartedEvent>;
  readonly restarting: Event<ApplicationWorkerRestartingEvent>;
  readonly failed: Event<ApplicationWorkerFailedEvent>;
  readonly stopped: Event<ApplicationWorkerStoppedEvent>;

  internal constructor() {
    this.all = new Event<ApplicationWorkerEvent>();
    this.started = new Event<ApplicationWorkerStartedEvent>();
    this.restarting = new Event<ApplicationWorkerRestartingEvent>();
    this.failed = new Event<ApplicationWorkerFailedEvent>();
    this.stopped = new Event<ApplicationWorkerStoppedEvent>();
  }

  internal function publishStarted(
    in workerId: String,
    incarnation: u64
  ): void {
    const event = ApplicationWorkerStartedEvent({
      workerId: copy workerId,
      incarnation,
    });
    let focused = this.started;
    focused.publish(in event);
    const aggregate = ApplicationWorkerEvent.started(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function publishRestarting(
    in workerId: String,
    incarnation: u64,
    retry: u64,
    maxRetries: u64,
    withinMilliseconds: u64,
    in message: String
  ): void {
    const event = ApplicationWorkerRestartingEvent({
      workerId: copy workerId,
      incarnation,
      retry,
      maxRetries,
      withinMilliseconds,
      message: copy message,
    });
    let focused = this.restarting;
    focused.publish(in event);
    const aggregate = ApplicationWorkerEvent.restarting(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function publishFailed(
    in workerId: String,
    incarnation: u64,
    retries: u64,
    in message: String
  ): void {
    const event = ApplicationWorkerFailedEvent({
      workerId: copy workerId,
      incarnation,
      retries,
      message: copy message,
    });
    let focused = this.failed;
    focused.publish(in event);
    const aggregate = ApplicationWorkerEvent.failed(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function publishStopped(in workerId: String): void {
    const event = ApplicationWorkerStoppedEvent({ workerId: copy workerId });
    let focused = this.stopped;
    focused.publish(in event);
    const aggregate = ApplicationWorkerEvent.stopped(copy event);
    let all = this.all;
    all.publish(in aggregate);
  }

  internal function finish(inout this): void {
    let all = this.all;
    all.finish();
    let started = this.started;
    started.finish();
    let restarting = this.restarting;
    restarting.finish();
    let failed = this.failed;
    failed.finish();
    let stopped = this.stopped;
    stopped.finish();
  }
}

internal function createApplicationWorkerEvents(
): ApplicationWorkerEvents on thread.main {
  return new ApplicationWorkerEvents();
}
