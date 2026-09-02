import {
  ApplicationWorker as FrameworkApplicationWorker,
  ApplicationWorkerSendError as FrameworkApplicationWorkerSendError,
  ApplicationWorkerSendErrorKind as FrameworkApplicationWorkerSendErrorKind,
  ApplicationWorkerState as FrameworkApplicationWorkerState,
  WorkerManager as FrameworkWorkerManager,
} from "../../framework/worker/worker-manager.zs";
import {
  ApplicationWorkerEvents as FrameworkApplicationWorkerEvents,
} from "../../framework/worker/events.zs";
import {
  ApplicationWorkerEvent as FrameworkApplicationWorkerEvent,
  ApplicationWorkerFailedEvent as FrameworkApplicationWorkerFailedEvent,
  ApplicationWorkerMessage as FrameworkApplicationWorkerMessage,
  ApplicationWorkerRestartingEvent as FrameworkApplicationWorkerRestartingEvent,
  ApplicationWorkerStartedEvent as FrameworkApplicationWorkerStartedEvent,
  ApplicationWorkerStoppedEvent as FrameworkApplicationWorkerStoppedEvent,
  EventSubscription as FrameworkApplicationWorkerEventSubscription,
  EventSubscriptionError as FrameworkApplicationWorkerEventSubscriptionError,
} from "../../framework/events.zs";

// Compile-time marker for one typed application-worker protocol. Commands and
// messages remain ordinary exported Z enums/structs; this type has no runtime
// storage or behavior.
export readonly struct WorkerProtocol<Command, Message> {}

export type ApplicationWorker = FrameworkApplicationWorker;
export type WorkerManager = FrameworkWorkerManager;
export type ApplicationWorkerState = FrameworkApplicationWorkerState;
export type ApplicationWorkerSendError = FrameworkApplicationWorkerSendError;
export type ApplicationWorkerSendErrorKind = FrameworkApplicationWorkerSendErrorKind;
export type ApplicationWorkerEvents = FrameworkApplicationWorkerEvents;
export type ApplicationWorkerEvent = FrameworkApplicationWorkerEvent;
export type ApplicationWorkerEventSubscription =
  FrameworkApplicationWorkerEventSubscription;
export type ApplicationWorkerEventSubscriptionError =
  FrameworkApplicationWorkerEventSubscriptionError;
export type ApplicationWorkerStartedEvent = FrameworkApplicationWorkerStartedEvent;
export type ApplicationWorkerRestartingEvent =
  FrameworkApplicationWorkerRestartingEvent;
export type ApplicationWorkerFailedEvent = FrameworkApplicationWorkerFailedEvent;
export type ApplicationWorkerMessage = FrameworkApplicationWorkerMessage;
export type ApplicationWorkerMessageSubscription =
  FrameworkApplicationWorkerEventSubscription;
export type ApplicationWorkerMessageSubscriptionError =
  FrameworkApplicationWorkerEventSubscriptionError;
export type ApplicationWorkerStoppedEvent = FrameworkApplicationWorkerStoppedEvent;
