/** Focused frontend API for configured application-lifetime workers. */

import { getBridge } from "./bridge";
import {
  ApplicationWorkerError,
} from "./application-worker-errors";
import type {
  CancellablePromise,
  InvokeOptions,
} from "./services";

export {
  ApplicationWorkerError,
  type ApplicationWorkerErrorPayload,
  type ApplicationWorkerOperation,
} from "./application-worker-errors";

export interface ApplicationWorkerSubscription {
  /** Stop delivery. Repeated calls are harmless. */
  unsubscribe(): void;
}

export interface ApplicationWorkerHandle {
  readonly id: string;

  /** Resolve after native policy accepts this message into the worker queue. */
  send(
    channel: string,
    data: unknown,
    options?: InvokeOptions,
  ): CancellablePromise<void>;

  /** Observe every message this worker sends on one named channel. */
  subscribe(
    channel: string,
    handler: (data: unknown) => void,
  ): ApplicationWorkerSubscription;
}

function requireName(value: string, label: string): string {
  const normalized = value.trim();
  if (normalized.length > 0) return normalized;
  throw new ApplicationWorkerError({
    code: "INVALID_ARGUMENTS",
    message: `${label} must not be empty`,
  });
}

function serialize(data: unknown, workerId: string): string {
  const payload = JSON.stringify(data);
  if (payload !== undefined) return payload;
  throw new ApplicationWorkerError({
    code: "INVALID_ARGUMENTS",
    message: `message for application worker "${workerId}" is not JSON-serializable`,
    operation: "send",
    workerId,
  });
}

function eventName(workerId: string, channel: string): string {
  return `__zapp:application-worker:${encodeURIComponent(workerId)}:${encodeURIComponent(channel)}`;
}

function subscription(cleanup: () => void): ApplicationWorkerSubscription {
  let active = true;
  return {
    unsubscribe(): void {
      if (!active) return;
      active = false;
      cleanup();
    },
  };
}

class FocusedApplicationWorkerHandle implements ApplicationWorkerHandle {
  constructor(readonly id: string) {}

  send(
    channel: string,
    data: unknown,
    options?: InvokeOptions,
  ): CancellablePromise<void> {
    const normalizedChannel = requireName(channel, "application worker channel");
    const pending = getBridge().invoke(
      "__zapp:application-worker-send",
      {
        workerId: this.id,
        channel: normalizedChannel,
        payload: serialize(data, this.id),
      },
      options,
    );
    const accepted = pending.then(() => undefined) as CancellablePromise<void>;
    accepted.cancel = () => pending.cancel();
    return accepted;
  }

  subscribe(
    channel: string,
    handler: (data: unknown) => void,
  ): ApplicationWorkerSubscription {
    const normalizedChannel = requireName(channel, "application worker channel");
    return subscription(getBridge().on(
      eventName(this.id, normalizedChannel),
      handler,
    ));
  }
}

export const applicationWorkers = {
  /** Address a configured worker; availability is checked by each operation. */
  get(id: string): ApplicationWorkerHandle {
    return new FocusedApplicationWorkerHandle(
      requireName(id, "application worker ID"),
    );
  },
};
