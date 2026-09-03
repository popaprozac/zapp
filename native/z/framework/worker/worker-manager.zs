import { Map } from "std/collections";
import { thread } from "std/thread";
import {
  ApplicationWorkerDispatch,
} from "./application-workers.zs";
import { ApplicationWorkerCatalog } from "./configuration.zs";
import {
  ApplicationWorkerEvent as FrameworkApplicationWorkerEvent,
  ApplicationWorkerFailedEvent as FrameworkApplicationWorkerFailedEvent,
  ApplicationWorkerMessage as FrameworkApplicationWorkerMessage,
  ApplicationWorkerRestartingEvent as FrameworkApplicationWorkerRestartingEvent,
  ApplicationWorkerStartedEvent as FrameworkApplicationWorkerStartedEvent,
  ApplicationWorkerStoppedEvent as FrameworkApplicationWorkerStoppedEvent,
  Event,
  EventSubscription as FrameworkApplicationWorkerEventSubscription,
  EventSubscriptionError as FrameworkApplicationWorkerEventSubscriptionError,
} from "../events.zs";
import {
  ApplicationWorkerEvents as FrameworkApplicationWorkerEvents,
  createApplicationWorkerEvents,
} from "./events.zs";

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

export enum ApplicationWorkerState {
  configured,
  running,
  restarting,
  stopped,
  failed,
}

export enum ApplicationWorkerSendErrorKind {
  invalidChannel,
  unavailable,
  saturated,
  failed,
}

export readonly struct ApplicationWorkerSendError {
  workerId: String;
  kind: ApplicationWorkerSendErrorKind;
  message: String;
}

// Compile-time marker for one typed application-worker protocol. The build
// adapter replaces WorkerManager.get(marker) with a checked codec-bearing
// protocol without changing the authored call or duplicating wire types.
export readonly struct WorkerProtocol<Command, Message> {}

export readonly struct ApplicationWorkerProtocolError {
  workerId: String;
  channel: String;
  message: String;
}

internal struct EncodedApplicationWorkerCommand {
  channel: String;
  payload: String;
}

internal readonly struct ApplicationWorkerProtocolAdapter<Command, Message> {
  workerId: String;
  marker: WorkerProtocol<Command, Message>;
  encode: (command: Command) => EncodedApplicationWorkerCommand;
  accepts: (in message: ApplicationWorkerMessage) => boolean;
  decode: (
    in message: ApplicationWorkerMessage
  ) => Result<Message, ApplicationWorkerProtocolError>;
}

internal type ApplicationWorkerSendOperation = (
  in workerId: String,
  in channel: String,
  in payload: String
) => ApplicationWorkerDispatch on thread.main;

class ApplicationWorkerStateStorage on thread.main {
  value: ApplicationWorkerState;

  internal constructor() {
    this.value = ApplicationWorkerState.configured;
  }
}

export readonly class RawApplicationWorker on thread.main {
  readonly id: String;
  readonly events: ApplicationWorkerEvents;
  readonly messages: Event<ApplicationWorkerMessage>;
  internal readonly manager: Weak<WorkerManager>;
  internal readonly currentState: ApplicationWorkerStateStorage;

  internal constructor(id: String, manager: Weak<WorkerManager>) {
    this.id = move id;
    this.events = createApplicationWorkerEvents();
    this.messages = new Event<ApplicationWorkerMessage>();
    this.manager = manager;
    this.currentState = new ApplicationWorkerStateStorage();
  }

  function state(): ApplicationWorkerState {
    return this.currentState.value;
  }

  function send(
    channel: String,
    payload: String
  ): void throws ApplicationWorkerSendError {
    const id = copy this.id;
    if (channel.byteLength == 0) {
      throw ApplicationWorkerSendError({
        workerId: copy id,
        kind: ApplicationWorkerSendErrorKind.invalidChannel,
        message: "application worker channel must not be empty",
      });
    }
    const owner = attempt this.manager.upgrade();
    const dispatch = match (owner) {
      success(manager) => manager.dispatch(in id, in channel, in payload);
      failure(_) => ApplicationWorkerDispatch.unavailable;
    };
    match (dispatch) {
      accepted => return;
      unavailable => throw ApplicationWorkerSendError({
        workerId: copy id,
        kind: ApplicationWorkerSendErrorKind.unavailable,
        message: `application worker "${id}" is not running`,
      });
      saturated => throw ApplicationWorkerSendError({
        workerId: copy id,
        kind: ApplicationWorkerSendErrorKind.saturated,
        message: `application worker "${id}" cannot accept more work`,
      });
      failed => throw ApplicationWorkerSendError({
        workerId: copy id,
        kind: ApplicationWorkerSendErrorKind.failed,
        message: `application worker "${id}" could not accept the message`,
      });
    }
  }

  internal function publishStarted(incarnation: u64): void {
    const id = copy this.id;
    let state = this.currentState;
    state.value = ApplicationWorkerState.running;
    let events = this.events;
    events.publishStarted(in id, incarnation);
  }

  internal function publishRestarting(
    incarnation: u64,
    retry: u64,
    maxRetries: u64,
    withinMilliseconds: u64,
    in message: String
  ): void {
    const id = copy this.id;
    let state = this.currentState;
    state.value = ApplicationWorkerState.restarting;
    let events = this.events;
    events.publishRestarting(
      in id,
      incarnation,
      retry,
      maxRetries,
      withinMilliseconds,
      in message
    );
  }

  internal function publishFailed(
    incarnation: u64,
    retries: u64,
    in message: String
  ): void {
    const id = copy this.id;
    let state = this.currentState;
    state.value = ApplicationWorkerState.failed;
    let events = this.events;
    events.publishFailed(in id, incarnation, retries, in message);
  }

  internal function publishMessage(
    in channel: String,
    in payload: String
  ): void {
    const message = ApplicationWorkerMessage({
      workerId: copy this.id,
      channel: copy channel,
      payload: copy payload,
    });
    let messages = this.messages;
    messages.publish(in message);
  }

  internal function publishStopped(): void {
    const id = copy this.id;
    let state = this.currentState;
    state.value = ApplicationWorkerState.stopped;
    let events = this.events;
    events.publishStopped(in id);
    events.finish();
    let messages = this.messages;
    messages.finish();
  }

  internal function finishEvents(): void {
    let events = this.events;
    events.finish();
    let messages = this.messages;
    messages.finish();
  }
}

// Typed subscriptions keep malformed or unknown native messages explicit.
// Generated workers are expected to produce valid payloads, but the raw API
// remains available, so protocol violations are values rather than hidden
// drops or process-wide traps.
export readonly class ApplicationWorkerMessages<Message> on thread.main {
  internal readonly source: Event<ApplicationWorkerMessage>;
  internal readonly accepts: (
    in message: ApplicationWorkerMessage
  ) => boolean;
  internal readonly decode: (
    in message: ApplicationWorkerMessage
  ) => Result<Message, ApplicationWorkerProtocolError>;

  internal constructor(
    source: Event<ApplicationWorkerMessage>,
    accepts: (in message: ApplicationWorkerMessage) => boolean,
    decode: (
      in message: ApplicationWorkerMessage
    ) => Result<Message, ApplicationWorkerProtocolError>
  ) {
    this.source = source;
    this.accepts = accepts;
    this.decode = decode;
  }

  function subscribe(
    handler: (
      in message: Result<Message, ApplicationWorkerProtocolError>
    ) => void on thread.main
  ): ApplicationWorkerMessageSubscription throws ApplicationWorkerMessageSubscriptionError {
    const decode = this.decode;
    const accepts = this.accepts;
    let source = this.source;
    return try source.subscribe(
      move (in message: ApplicationWorkerMessage): void => {
        if (!accepts(in message)) return;
        const decoded = decode(in message);
        handler(in decoded);
      }
    );
  }
}

// The safe default handle. A generated adapter owns the channel names and JSON
// codecs, while lifecycle and scheduling remain the same native worker.
export readonly class ApplicationWorker<Command, Message> on thread.main {
  readonly id: String;
  readonly events: ApplicationWorkerEvents;
  readonly messages: ApplicationWorkerMessages<Message>;
  internal readonly raw: RawApplicationWorker;
  internal readonly marker: WorkerProtocol<Command, Message>;
  internal readonly encode: (
    command: Command
  ) => EncodedApplicationWorkerCommand;

  internal constructor(
    raw: RawApplicationWorker,
    marker: WorkerProtocol<Command, Message>,
    encode: (command: Command) => EncodedApplicationWorkerCommand,
    accepts: (in message: ApplicationWorkerMessage) => boolean,
    decode: (
      in message: ApplicationWorkerMessage
    ) => Result<Message, ApplicationWorkerProtocolError>
  ) {
    this.id = copy raw.id;
    this.events = raw.events;
    this.messages = new ApplicationWorkerMessages<Message>(
      raw.messages,
      accepts,
      decode
    );
    this.raw = raw;
    this.marker = marker;
    this.encode = encode;
  }

  function state(): ApplicationWorkerState {
    return this.raw.state();
  }

  function send(command: Command): void throws ApplicationWorkerSendError {
    const encoded = this.encode(move command);
    const { channel, payload } = move encoded;
    try this.raw.send(move channel, move payload);
  }
}

class WorkerManagerState on thread.main {
  workers: Map<String, RawApplicationWorker>;
  send: Option<ApplicationWorkerSendOperation>;
  active: boolean;

  internal constructor() {
    this.workers = Map<String, RawApplicationWorker>();
    this.send = Option<ApplicationWorkerSendOperation>.none;
    this.active = false;
  }
}

// Configured handles exist before run so callers can subscribe to lifecycle
// events; engine controls are installed after services and the platform runtime
// are ready.
export readonly class WorkerManager on thread.main {
  internal readonly catalog: ApplicationWorkerCatalog;
  internal readonly storage: WorkerManagerState;

  internal constructor(catalog: ApplicationWorkerCatalog) {
    this.catalog = catalog;
    this.storage = new WorkerManagerState();
  }

  internal function configure(inout this): void {
    const owner = weak this;
    let storage = this.storage;
    let index: usize = 0;
    while (index < this.catalog.entries.length) {
      const id: String = this.catalog.entries[index].id.copyBytes(
        0,
        this.catalog.entries[index].id.byteLength
      );
      storage.workers.set(
        copy id,
        new RawApplicationWorker(move id, owner)
      );
      index = index + 1;
    }
  }

  // Checked marker call. Zapp's generated build overlay replaces this with
  // getGenerated and a protocol adapter derived from the same metadata used
  // by the WebView and worker TypeScript surfaces.
  function get<Command, Message>(
    protocol: WorkerProtocol<Command, Message>
  ): Option<ApplicationWorker<Command, Message>> {
    return Option<ApplicationWorker<Command, Message>>.none;
  }

  function getRaw(in id: String): Option<RawApplicationWorker> {
    const found = this.storage.workers.get(id);
    return match (in found) {
      some(worker) => Option.some(worker);
      none => Option.none;
    };
  }

  internal function getGenerated<Command, Message>(
    adapter: ApplicationWorkerProtocolAdapter<Command, Message>
  ): Option<ApplicationWorker<Command, Message>> {
    const {
      workerId,
      marker,
      encode,
      accepts,
      decode,
    } = move adapter;
    const found = this.getRaw(in workerId);
    return match (found) {
      some(worker) => Option.some(new ApplicationWorker<Command, Message>(
        worker,
        marker,
        encode,
        accepts,
        decode
      ));
      none => Option<ApplicationWorker<Command, Message>>.none;
    };
  }

  function all(): Array<RawApplicationWorker> {
    let result = Array<RawApplicationWorker>();
    for (const entry of this.storage.workers) {
      let retained = entry.value;
      result.push(move retained);
    }
    return result;
  }

  internal function install(
    inout this,
    send: ApplicationWorkerSendOperation
  ): void {
    let storage = this.storage;
    storage.send = Option.some(send);
    storage.active = true;
  }

  internal function dispatch(
    in workerId: String,
    in channel: String,
    in payload: String
  ): ApplicationWorkerDispatch {
    if (!this.storage.active) return ApplicationWorkerDispatch.unavailable;
    return match (in this.storage.send) {
      some(send) => send(in workerId, in channel, in payload);
      none => ApplicationWorkerDispatch.unavailable;
    };
  }

  internal function publishLifecycle(
    inout this,
    in workerId: String,
    phase: i32,
    incarnation: u64,
    retry: u64,
    maxRetries: u64,
    withinMilliseconds: u64,
    in message: String
  ): void {
    const found = this.getRaw(in workerId);
    match (found) {
      some(worker) => {
        if (phase == 1) {
          worker.publishStarted(incarnation);
          return;
        }
        if (phase == 2) {
          worker.publishRestarting(
            incarnation,
            retry,
            maxRetries,
            withinMilliseconds,
            in message
          );
          return;
        }
        if (phase == 3) {
          worker.publishFailed(incarnation, retry, in message);
        }
      }
      none => {}
    }
  }

  internal function publishMessage(
    in workerId: String,
    in channel: String,
    in payload: String
  ): void {
    const found = this.getRaw(in workerId);
    match (found) {
      some(worker) => worker.publishMessage(in channel, in payload);
      none => {}
    }
  }

  internal function finish(inout this): void {
    if (!this.storage.active) return;
    let storage = this.storage;
    storage.active = false;
    storage.send = Option<ApplicationWorkerSendOperation>.none;
    for (const entry of this.storage.workers) {
      const worker = entry.value;
      match (worker.state()) {
        failed => worker.finishEvents();
        stopped => worker.finishEvents();
        _ => worker.publishStopped();
      }
    }
  }
}

export function createWorkerManager(
  catalog: ApplicationWorkerCatalog
): WorkerManager on thread.main {
  const manager = new WorkerManager(catalog);
  let configured = manager;
  configured.configure();
  return manager;
}
