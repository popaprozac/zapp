import { RelatedWindowInvalidatedError } from "./window-errors";
import type { RelatedWindowInvalidatedEvent } from "./related-window-contract";
import type { WindowEventSubscription } from "./window-api";

/** @internal Native-validated reply-domain identity, not a permission credential. */
export interface RelatedDocumentIdentity {
  readonly windowId: string;
  readonly documentToken: string;
}

type Listener = {
  callback: ((event: RelatedWindowInvalidatedEvent) => void) | undefined;
};

/** @internal Bind the existing document transport, not a request/response relay. */
export function bindRelatedDocumentLifetime(
  identity: RelatedDocumentIdentity,
  transport: { _dispose(error: Error): void },
  reportError?: (error: unknown) => void,
): RelatedDocumentLifetime {
  return new RelatedDocumentLifetime(identity, error => transport._dispose(error), reportError);
}

/**
 * @internal One document's JS lifetime. Native routing must be invalidated
 * independently, before notification enters JS; no JS acknowledgement is needed.
 * The existing transport supplies its own pending-map disposal operation, avoiding
 * another per-request registry or Promise wrapper on normal calls.
 * Construct this in the observing owner's realm: delivery needs its surviving
 * event loop, not the retired child's. A blocked/destroyed observer cannot be
 * promised timely JS cleanup; native teardown must never depend on it.
 */
export class RelatedDocumentLifetime {
  private readonly identity: RelatedDocumentIdentity;
  private terminal: RelatedWindowInvalidatedEvent | undefined;
  private failure: RelatedWindowInvalidatedError | undefined;
  private invalidating = false;
  private readonly listeners = new Set<Listener>();
  private retireTransport: ((error: RelatedWindowInvalidatedError) => void) | undefined;

  constructor(
    identity: RelatedDocumentIdentity,
    retireTransport: (error: RelatedWindowInvalidatedError) => void,
    private readonly reportError: (error: unknown) => void = error => {
      console.error("[zapp] related-window cleanup failed", error);
    },
  ) {
    if (!identity.windowId || !identity.documentToken) {
      throw new TypeError("related document identity requires a window ID and document token");
    }
    this.identity = Object.freeze({ ...identity });
    this.retireTransport = retireTransport;
  }

  /** Guard JS submissions; native provenance checks remain independently required. */
  assertActive(): void {
    if (this.failure) throw this.failure;
  }

  subscribe(handler: (event: RelatedWindowInvalidatedEvent) => void): WindowEventSubscription {
    const listener: Listener = { callback: handler };
    if (this.terminal && !this.invalidating) this.enqueue(listener, this.terminal);
    else this.listeners.add(listener);
    return {
      unsubscribe: () => {
        listener.callback = undefined;
        this.listeners.delete(listener);
      },
    };
  }

  /** False for duplicate/stale notifications, including reuse of a native window ID. */
  invalidate(identity: RelatedDocumentIdentity, reason: string): boolean {
    if (this.terminal || identity.windowId !== this.identity.windowId
      || identity.documentToken !== this.identity.documentToken) return false;

    const event = Object.freeze({ windowId: this.identity.windowId, reason });
    const failure = new RelatedWindowInvalidatedError(event);
    // Latch first: transport disposal and cleanup can both reenter this object.
    this.terminal = event;
    this.failure = failure;
    this.invalidating = true;
    const retire = this.retireTransport;
    this.retireTransport = undefined;
    try { retire?.(failure); }
    catch (error) { this.report(error); }
    this.invalidating = false;
    // Registrations made reentrantly during retirement follow earlier ones.
    const listeners = [...this.listeners];
    this.listeners.clear();
    for (const listener of listeners) this.enqueue(listener, event);
    return true;
  }

  private enqueue(listener: Listener, event: RelatedWindowInvalidatedEvent): void {
    queueMicrotask(() => {
      const callback = listener.callback;
      listener.callback = undefined;
      if (!callback) return;
      try {
        const result: unknown = callback(event);
        if (result !== null && (typeof result === "object" || typeof result === "function")
          && typeof (result as { then?: unknown }).then === "function") {
          // Observe async cleanup errors without awaiting cleanup or closure.
          void Promise.resolve(result).catch(error => this.report(error));
        }
      }
      catch (error) { this.report(error); }
    });
  }

  private report(error: unknown): void {
    // Reporting must not strand the remaining listeners, either.
    try { this.reportError(error); } catch {}
  }
}
